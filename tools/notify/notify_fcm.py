#!/usr/bin/env python3
"""notify_fcm: the FCM HTTP v1 transport for the notify tools (PR-5).

Official sources verified 2026-11-01 (page updates 2026-10-28), per
AGENTS.md §0.3 vendor-fact rule — the claims below are the vendor's.
The Android priority/channel pages were re-verified 2026-11-11
(message-priority guide updated 2026-11-10; REST v1 reference):

- Send: POST https://fcm.googleapis.com/v1/projects/<project>/messages:send
  with `Authorization: Bearer <OAuth2 access token>`. The message is a
  notification+data message (the official path): {"message": {"token":
  <registration token>, "notification": {"title", "body"}, "data":
  {str: str}}}. Success answers HTTP 200 with {"name": "projects/..." }.
  (firebase.google.com/docs/cloud-messaging/send-message,
  /docs/cloud-messaging/auth-server)
- Access token: a short-lived OAuth 2.0 token derived from the service
  account: RS256-signed JWT (iss=client_email,
  scope=https://www.googleapis.com/auth/firebase.messaging,
  aud=https://oauth2.googleapis.com/token) exchanged at
  https://oauth2.googleapis.com/token,
  grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer.
  (firebase.google.com/docs/cloud-messaging/auth-server;
  developers.google.com/identity/protocols/oauth2/service-account)
- Error codes (firebase.google.com/docs/cloud-messaging/admin/errors):
  UNREGISTERED (HTTP 404) — remove the token from the app server and
  stop sending to it. That table's UNREGISTERED is the semantic name;
  the REST wire's error object carries google.rpc codes, whose
  canonical name for 404 is NOT_FOUND, so the two names denote the
  same retired-token state. Measured wire (2026-11-03 delivery
  ledger, evidence in docs/GATES.md): an invalid token answered HTTP
  404 with error.status "NOT_FOUND" — the string "UNREGISTERED" never
  appeared on the wire, so classify_send retires on 404 + either name
  (NOT_FOUND paired with any other HTTP status is NOT this state and
  stays verbatim-permanent); SENDER_ID_MISMATCH (HTTP 403) — the
  authenticated
  sender is not a registered sender of this token: a configuration
  error; QUOTA_EXCEEDED (HTTP 429) — exponential backoff, minimum
  initial delay of 1 minute; UNAVAILABLE (HTTP 503) — retry the same
  request, honoring Retry-After; INTERNAL (HTTP 500) — may retry.
  Any other response is NONE of the above: fail-closed, never mapped
  onto success and never guessed retryable (delivery.schema.json
  error_code: the set is open and kept verbatim).
- Payload limit: 4096 bytes for most messages, keys and values included.
- Android priority and channel: every message carries android.priority
  explicitly. The events the dispatcher forwards are the TOP10 rank
  transitions (notify_dispatcher.NOTIFIABLE_EVENT_TYPES); they are
  always "high" with android.notification.channel_id
  "market_rank_changes" — the REST v1 reference: "The app must create
  a channel with this channel ID before any notification with this
  channel ID is received" (the app owns creating that channel; without
  it FCM falls back to the channel id in the app manifest). The
  defensive generic assembly keeps the severity mapping ("high" for
  HIGH/CRITICAL, "normal" for INFO). The vendor's own pages disagree
  on the unset default: the REST v1 reference documents HIGH as
  "Default priority for notification messages" while the guide says
  "Normal priority. This is the default priority for data and
  notification messages" (both consulted 2026-11-11). The effective
  unset priority is therefore not provable from official prose;
  README §6 records the conflict and claims neither default.
- High priority is a delivery attempt, not a display promise (guide,
  2026-11-10): "If FCM detects a pattern in which messages don't
  result in user-facing notifications, your messages may be
  deprioritized to normal priority or delegated for handling by
  Google Play services" — decided from 7 days of message behavior per
  app instance. The TOP10 notifications are user-facing notification
  messages, which is exactly the use the vendor asks of high
  priority.

accepted != delivered: an HTTP 200 only proves FCM accepted the message
for delivery. Arrival time, ordering, display and user reads are outside
every guarantee (docs/REPLAY_CONTRACT.md §13.5) and are never recorded
as such. Token values (registration token, OAuth token) never appear in
any log, record or stdout — sha256 prefixes only.

Pure standard library: the RS256 signer implements RSASSA-PKCS1-v1_5
over SHA-256 (RFC 8017 §8.2 / §9.2); the unit suite pins it to the
official RFC 7515 A.2 test vector, and DER parsing of the service
account's PKCS#8/PKCS#1 key to a key reconstructed from that same RFC's
published JWK. No crypto dependency is added (collector dependency
discipline: README §11).
"""

import base64
import binascii
import hashlib
import json
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
FCM_SEND_URL = "https://fcm.googleapis.com/v1/projects/%s/messages:send"
FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
PAYLOAD_LIMIT_BYTES = 4096
GRANT_TYPE = "urn:ietf:params:oauth:grant-type:jwt-bearer"

# The event types that get the market TOP10 message assembly (README
# §6). notify_dispatcher.NOTIFIABLE_EVENT_TYPES — the delivery policy's
# allowlist — is this same set: the policy and the translation share
# one truth, so a fourth notifiable type changes both together.
TOP10_EVENT_TYPES = frozenset(
    ("TOP10_ENTERED", "TOP10_EXITED", "RANK_CHANGED"))
TOP10_TITLE = "홍스캐너 TOP10 변화"
TOP10_CHANNEL_ID = "market_rank_changes"
DIRECTION_WORDS = {"UP": "상승", "DOWN": "하락"}

# The SHA-256 DigestInfo prefix of EMSA-PKCS1-v1_5 (RFC 8017 §9.2 note 1):
# SEQUENCE { SEQUENCE { OID 2.16.840.1.101.3.4.2.1, NULL }, OCTET STRING }.
SHA256_DIGEST_INFO_PREFIX = bytes.fromhex(
    "3031300d060960864801650304020105000420")

# The RSA private-key component names in PKCS#1 order (RFC 8017 A.1.2).
RSA_COMPONENTS = ("n", "e", "d", "p", "q", "dp", "dq", "qi")


class FcmError(Exception):
    """A transport-layer contract violation or credential failure.
    Details name failure classes, never credential values."""


class SendOutcome:
    """The classified result of one send attempt. `kind` is one of:
    accepted / retry / unregistered / sender_mismatch / permanent."""

    def __init__(self, kind, http_status, error_code=None,
                 provider_message_id=None, retry_after_seconds=None):
        self.kind = kind
        self.http_status = http_status
        self.error_code = error_code
        self.provider_message_id = provider_message_id
        self.retry_after_seconds = retry_after_seconds


# ------------------------------------------------------- DER parsing

def _read_der(data, offset):
    """One DER TLV at `offset` -> (tag, value_bytes, next_offset).
    Strict: definite lengths only (a service-account key is DER, not
    BER); anything else is fail-closed."""
    if offset + 2 > len(data):
        raise FcmError("DER: truncated header")
    tag = data[offset]
    length = data[offset + 1]
    offset += 2
    if length > 0x80:
        count = length & 0x7F
        if count == 0 or count > 4 or offset + count > len(data):
            raise FcmError("DER: unsupported or truncated length")
        length = int.from_bytes(data[offset:offset + count], "big")
        offset += count
    if offset + length > len(data):
        raise FcmError("DER: truncated value")
    return tag, data[offset:offset + length], offset + length


def _read_der_int(data, offset):
    tag, value, offset = _read_der(data, offset)
    if tag != 0x02:
        raise FcmError("DER: expected INTEGER")
    return int.from_bytes(value, "big"), offset


def _read_der_seq(data, offset):
    tag, value, offset = _read_der(data, offset)
    if tag != 0x30:
        raise FcmError("DER: expected SEQUENCE")
    return value, offset


def parse_rsa_private_key(pem_text):
    """Parse a PEM service-account key (PKCS#8 "BEGIN PRIVATE KEY" or
    PKCS#1 "BEGIN RSA PRIVATE KEY") into the RSA components. Any
    deviation from the documented structures is fail-closed."""
    lines = [ln.strip() for ln in pem_text.splitlines()]
    body = [ln for ln in lines if ln and not ln.startswith("-----")]
    header = next((ln for ln in lines if ln.startswith("-----BEGIN ")), None)
    if header == "-----BEGIN PRIVATE KEY-----":
        kind = "pkcs8"
    elif header == "-----BEGIN RSA PRIVATE KEY-----":
        kind = "pkcs1"
    else:
        raise FcmError("PEM: expected a PRIVATE KEY / RSA PRIVATE KEY "
                       "label")
    if not any(ln.startswith("-----END ") for ln in lines):
        raise FcmError("PEM: no END label")
    try:
        der = base64.b64decode("".join(body), validate=True)
    except (binascii.Error, ValueError) as exc:
        raise FcmError("PEM: base64 body invalid: %s" % exc)

    if kind == "pkcs8":
        # RFC 5208: SEQ { version INTEGER 0, SEQ { OID, params },
        #               OCTET STRING pkcs1 }
        inner, _ = _read_der_seq(der, 0)
        version, offset = _read_der_int(inner, 0)
        if version != 0:
            raise FcmError("PKCS#8: unsupported version %d" % version)
        tag, _, offset = _read_der(inner, offset)
        if tag != 0x30:
            raise FcmError("PKCS#8: expected AlgorithmIdentifier")
        tag, octets, offset = _read_der(inner, offset)
        if tag != 0x04:
            raise FcmError("PKCS#8: expected OCTET STRING key")
        if offset != len(inner):
            raise FcmError("PKCS#8: trailing bytes")
        der = octets

    # RFC 8017 A.1.2 RSAPrivateKey ::= SEQ { version, n, e, d, p, q,
    #                                       dP, dQ, qInv }
    inner, _ = _read_der_seq(der, 0)
    version, offset = _read_der_int(inner, 0)
    if version != 0:
        raise FcmError("PKCS#1: unsupported version %d" % version)
    components = {}
    for name in RSA_COMPONENTS:
        components[name], offset = _read_der_int(inner, offset)
    if offset != len(inner):
        raise FcmError("PKCS#1: trailing bytes")
    if components["e"] < 3 or components["n"] <= components["d"]:
        raise FcmError("PKCS#1: implausible key components")
    return components


# ----------------------------------------------------------- signing

def rs256_sign(key, signing_input):
    """RSASSA-PKCS1-v1_5 with SHA-256 (RFC 8017 §8.2): EM = 0x00 0x01
    PS 0x00 DigestInfo(SHA-256, Hash(M)), signature = EM^d mod n."""
    digest = hashlib.sha256(signing_input).digest()
    digest_info = SHA256_DIGEST_INFO_PREFIX + digest
    k = (key["n"].bit_length() + 7) // 8
    ps_len = k - len(digest_info) - 3
    if ps_len < 8:
        raise FcmError("RSA key too small for the payload (RFC 8017: "
                       "PS >= 8 octets)")
    em = b"\x00\x01" + b"\xff" * ps_len + b"\x00" + digest_info
    signature = pow(int.from_bytes(em, "big"), key["d"], key["n"])
    return signature.to_bytes(k, "big")


def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def service_account_jwt(key, client_email, iat, ttl_seconds=3600):
    """The OAuth assertion: a compact-serialized RS256 JWT per Google's
    service-account flow (claims documented in the module docstring).
    Serialization is deterministic (sorted keys) for replayability."""
    header = {"alg": "RS256", "typ": "JWT"}
    claims = {
        "aud": OAUTH_TOKEN_URL,
        "exp": iat + ttl_seconds,
        "iat": iat,
        "iss": client_email,
        "scope": FCM_SCOPE,
    }
    segments = [
        _b64url(json.dumps(header, sort_keys=True, separators=(",", ":")
                           ).encode("utf-8")),
        _b64url(json.dumps(claims, sort_keys=True, separators=(",", ":")
                           ).encode("utf-8")),
    ]
    signing_input = ".".join(segments).encode("ascii")
    segments.append(_b64url(rs256_sign(key, signing_input)))
    return ".".join(segments)


# ------------------------------------------------- OAuth access token

class TokenSource:
    """The credential path (README §8): either the service-account JSON
    at a user-provided path outside the repository (JWT exchange), or a
    user-configured token command (platform delegation — the official
    client owns its own native credential storage, the collector's
    kiwoomcli precedent). Token values exist in process memory only."""

    def __init__(self, cfg, opener=None):
        self._sa_path = cfg.get("service_account_path")
        self._command = cfg.get("token_command")
        self._opener = opener or urllib.request.urlopen
        self._key = None
        self._client_email = None
        self._cached = None  # (access_token, expires_epoch)

    def get(self, now=None):
        """A valid access token, refreshing when within 60s of expiry.
        Raises FcmError (class names only — never a token value)."""
        now = time.time() if now is None else now
        if self._cached is not None:
            token, expires = self._cached
            if now < expires - 60:
                return token
        if self._command is not None:
            return self._from_command()
        return self._from_service_account(now)

    def _from_command(self):
        """Delegate token issuance to the platform's official client and
        read its stdout. Output is captured and never printed."""
        try:
            proc = subprocess.run(self._command, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise FcmError("token command failed: %s" % type(exc).__name__)
        if proc.returncode != 0:
            raise FcmError("token command exited %d" % proc.returncode)
        token = proc.stdout.decode("utf-8", "replace").strip()
        if not token or len(token) > 8192 or any(c.isspace() for c in token):
            raise FcmError("token command produced no usable token")
        self._cached = (token, float("inf"))
        return token

    def _from_service_account(self, now):
        if self._key is None:
            try:
                with open(self._sa_path, "r", encoding="utf-8") as f:
                    doc = json.load(f)
            except (OSError, ValueError) as exc:
                raise FcmError("service account unreadable: %s"
                               % type(exc).__name__)
            if not isinstance(doc, dict):
                raise FcmError("service account is not a JSON object")
            email = doc.get("client_email")
            pem = doc.get("private_key")
            if not isinstance(email, str) or not email or \
               not isinstance(pem, str) or not pem:
                raise FcmError("service account lacks client_email or "
                               "private_key")
            self._client_email = email
            try:
                self._key = parse_rsa_private_key(pem)
            except FcmError:
                raise
            except Exception as exc:
                raise FcmError("service account key unparsable: %s"
                               % type(exc).__name__)

        assertion = service_account_jwt(self._key, self._client_email,
                                        int(now))
        body = ("grant_type=%s&assertion=%s" %
                (urllib.parse.quote(GRANT_TYPE, safe=""),
                 urllib.parse.quote(assertion, safe=""))).encode("ascii")
        request = urllib.request.Request(
            OAUTH_TOKEN_URL, data=body, method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"})
        try:
            with self._opener(request, timeout=30) as resp:
                payload = resp.read()
                status = resp.status
        except urllib.error.HTTPError as exc:
            raise FcmError("token endpoint returned HTTP %d" % exc.code)
        except Exception as exc:
            raise FcmError("token endpoint unreachable: %s"
                           % type(exc).__name__)
        try:
            doc = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise FcmError("token endpoint response unparsable")
        if status != 200 or not isinstance(doc, dict) or \
           not isinstance(doc.get("access_token"), str) or \
           not doc["access_token"]:
            raise FcmError("token endpoint granted no access token")
        expires_in = doc.get("expires_in")
        if not isinstance(expires_in, int) or expires_in <= 0:
            expires_in = 3600
        token = doc["access_token"]
        self._cached = (token, now + expires_in)
        return token


# ------------------------------------------------------------ sending

def build_message(event, fcm_token):
    """The notification+data message for one event -> one device
    (README §6). The dispatcher's allowlist means the events reaching
    this in production are the TOP10 rank transitions: they get the
    dedicated Korean notification (title TOP10_TITLE, body
    "<name|symbol> <상승|하락> TOP10 <rank move>"), android.priority
    "high" and the market_rank_changes channel. The generic branch is
    the defensive assembly for any other event type that somehow
    reaches the transport — the dispatcher blocks them before this
    point; the transport stays general, not a second policy gate.
    android.priority is always explicit because the vendor's own pages
    disagree on the unset default (README §6 records the conflict
    verbatim); an explicit value is the only sure path. The FCM
    registration token is inside the request body only."""
    if event["event_type"] in TOP10_EVENT_TYPES:
        message = _top10_message(event, fcm_token)
    else:
        message = _generic_message(event, fcm_token)
    size = len(json.dumps(message, ensure_ascii=False,
                          separators=(",", ":")).encode("utf-8"))
    if size > PAYLOAD_LIMIT_BYTES:
        raise FcmError("payload is %d bytes; the vendor limit is %d "
                       "(keys and values included)" %
                       (size, PAYLOAD_LIMIT_BYTES))
    return message


def _top10_message(event, fcm_token):
    """The market TOP10 rank-transition notification (README §6).
    body = "<display> <direction word> TOP10 <rank move>": display is
    the vendor name, falling back to the symbol and (a fact that
    carries neither, defensively) to the event_type — never an
    invented name; an absent direction drops its word rather than
    guessing one. The rank move is exactly what the fact carries:
    both ranks -> "<prev>위 → <rank>위", rank only -> "신규 진입
    <rank>위", previous only -> "<prev>위 → 후보 제외", neither ->
    no move text (no invented rank). data values are all strings (the
    vendor requires string:string); ints are stringified."""
    display = event.get("name") or event.get("symbol") or \
        event["event_type"]
    direction = DIRECTION_WORDS.get(event.get("direction"), "")
    previous = event.get("previous_rank")
    rank = event.get("rank")
    if previous is not None and rank is not None:
        move = "%d위 → %d위" % (previous, rank)
    elif rank is not None:
        move = "신규 진입 %d위" % rank
    elif previous is not None:
        move = "%d위 → 후보 제외" % previous
    else:
        move = ""
    body = " ".join(part for part in (display, direction, "TOP10", move)
                    if part)
    data = {
        "event_id": event["event_id"],
        "event_type": event["event_type"],
        "severity": event["severity"],
    }
    for key in ("direction", "symbol", "previous_rank", "rank"):
        if key in event:
            data[key] = str(event[key])
    return {
        "message": {
            "token": fcm_token,
            "notification": {"title": TOP10_TITLE, "body": body},
            "android": {
                "priority": "high",
                "notification": {"channel_id": TOP10_CHANNEL_ID},
            },
            "data": data,
        },
    }


def _generic_message(event, fcm_token):
    """The defensive assembly for event types outside the TOP10
    allowlist (the dispatcher never forwards them, README §0/§6):
    minimal title/body, severity-mapped priority, ids in data."""
    body = event["event_type"]
    if "symbol" in event:
        body = "%s %s" % (body, event["symbol"])
    return {
        "message": {
            "token": fcm_token,
            "notification": {"title": "Hong Scanner %s" %
                                      event["severity"], "body": body},
            "android": {"priority": "high" if
                        event["severity"] in ("HIGH", "CRITICAL")
                        else "normal"},
            "data": {
                "event_id": event["event_id"],
                "event_type": event["event_type"],
                "severity": event["severity"],
            },
        },
    }


def send_message(project_id, access_token, message, opener=None):
    """One HTTP v1 send. Whatever the HTTP outcome (200 included), the
    answer comes back as a SendOutcome — nothing is swallowed here."""
    opener = opener or urllib.request.urlopen
    body = json.dumps(message, ensure_ascii=False,
                      separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        FCM_SEND_URL % project_id, data=body, method="POST",
        headers={"Authorization": "Bearer %s" % access_token,
                 "Content-Type": "application/json; charset=UTF-8"})
    try:
        with opener(request, timeout=30) as resp:
            return classify_send(resp.status, resp.headers, resp.read())
    except urllib.error.HTTPError as exc:
        # An HTTP error response is still a provider answer: classify it.
        return classify_send(exc.code, exc.headers, exc.read())
    except Exception:
        # No provider answer at all (transport): retryable per the
        # vendor's retry guidance; the record stays PENDING. The failure
        # class is recorded without its exception payload — the payload
        # could carry request data; the class name cannot.
        return SendOutcome("retry", None, error_code="HS_TRANSPORT",
                           retry_after_seconds=None)


def _parse_retry_after(headers):
    """Retry-After in seconds (the delta-seconds form FCM sends); an
    unparseable header is treated as absent (fail-closed, not guessed)."""
    raw = headers.get("Retry-After") if headers is not None else None
    if not raw:
        return None
    try:
        seconds = int(raw.strip())
    except ValueError:
        return None
    return seconds if seconds >= 0 else None


def classify_send(status, headers, body_bytes):
    """The vendor table (module docstring) as code. Unknown statuses and
    unknown error bodies land in `permanent` — kept verbatim, never
    mapped onto success (fail-closed)."""
    if status == 200:
        try:
            doc = json.loads(body_bytes.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            doc = None
        name = doc.get("name") if isinstance(doc, dict) else None
        if not isinstance(name, str) or not name:
            # Success without a message id is not provable acceptance:
            # record the refusal honestly, never a silent success.
            return SendOutcome("permanent", status,
                               error_code="HS_NO_PROVIDER_MESSAGE_ID")
        return SendOutcome("accepted", status, provider_message_id=name)

    error_code = "HTTP_%d" % status
    try:
        doc = json.loads(body_bytes.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        doc = None
    if isinstance(doc, dict) and isinstance(doc.get("error"), dict):
        vstatus = doc["error"].get("status")
        if isinstance(vstatus, str) and vstatus:
            error_code = vstatus  # verbatim, the set is open

    retry_after = _parse_retry_after(headers)
    # 404 retires the token under either code name: the Admin SDK
    # error table spells it UNREGISTERED ("remove this registration
    # token from the app server and stop using it",
    # firebase.google.com/docs/cloud-messaging/admin/errors), while
    # the REST wire's error object carries google.rpc codes whose
    # canonical name for 404 is NOT_FOUND — the same state, two names.
    # Measured wire (2026-11-03 delivery ledger, docs/GATES.md
    # evidence log): an invalid token answered 404 with error.status
    # "NOT_FOUND"; "UNREGISTERED" never reached the wire, so matching
    # it alone left real invalid tokens unretired. NOT_FOUND with any
    # status other than 404 is NOT this state: it falls through to
    # the verbatim permanent class below, never a guessed retirement.
    if status == 404 and error_code in ("UNREGISTERED", "NOT_FOUND"):
        return SendOutcome("unregistered", status,
                           error_code=error_code,
                           retry_after_seconds=retry_after)
    if status == 403 and error_code == "SENDER_ID_MISMATCH":
        return SendOutcome("sender_mismatch", status,
                           error_code=error_code,
                           retry_after_seconds=retry_after)
    if status in (429, 500, 503):
        return SendOutcome("retry", status, error_code=error_code,
                           retry_after_seconds=retry_after)
    return SendOutcome("permanent", status, error_code=error_code,
                       retry_after_seconds=retry_after)
