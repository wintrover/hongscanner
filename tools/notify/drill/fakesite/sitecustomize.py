"""Drill-only urllib patch (fake-FCM process-pair drill).

The dispatcher's transports are stdlib ``urllib.request.urlopen``
(notify_fcm.send_message POST to the FCM HTTP v1 endpoint and the
service-account JWT exchange POST to the OAuth token endpoint), and
stdlib modules cannot be shadowed through PYTHONPATH the way a site
package can. This ``sitecustomize`` is auto-imported at interpreter
start when tools/notify/drill/fakesite is on PYTHONPATH, and patches
``urllib.request.urlopen`` with a simulated FCM backend.

Scope guard (fail-safe): the patch is installed ONLY when the drill
driver exported ``HSDRILL=1``. Without it this file is completely inert
— no import side effect beyond this check — so a leaked PYTHONPATH can
never patch urllib outside the drill. Inert here also means the REAL
FCM endpoints stay real everywhere else.

Simulated behavior (scripted by HSDRILL_FCM_SCRIPT, a JSON file):
  - the OAuth token endpoint answers with the scripted access token;
  - the FCM send endpoint answers per (device -> [response...]) script,
    popping one entry per call; ``status`` plus optional ``retry_after``
    and ``error_status`` build the vendor-shaped body
    ``{"error":{"code":..,"status":..}}``;
  - device identification is by the message's registration token (the
    tokens are drill fakes, mapped in the script's ``devices`` table);
  - an optional delay (HSDRILL_SEND_DELAY seconds) is inserted after
    the SEND wirelog marker, so the drill's SIGKILL lands in the
    provider-accepted-but-unrecorded window deterministically.

Wirelog (HSDRILL_WIRELOG): one line per message, timestamps included —
``OAUTH``, ``SEND <event16> <device> <token-hash>`` (the single,
per-event message form) or ``SEND <kind> count=<n> first=<event16>
<device> <token-hash>`` (the group forms summary/digest: composition
kind, member count, first covered event), ``RESP <status> <device>``,
``ANOMALY <what>``. Credential values are NEVER logged:
tokens appear as sha256 prefixes only (README §8). Any request that is
not the official endpoint shape, or any unexpected bearer, is recorded
as ANOMALY and answered 400 — the drill fails on any ANOMALY line.
"""

import hashlib
import json
import os
import time
from datetime import datetime, timedelta, timezone

if os.environ.get("HSDRILL") == "1":  # drill-only: inert anywhere else
    import urllib.request

    KST = timezone(timedelta(hours=9))

    def _now():
        return datetime.now(KST).strftime("%Y-%m-%dT%H:%M:%S+09:00")

    _wirelog_path = os.environ.get("HSDRILL_WIRELOG", "")
    _script_path = os.environ.get("HSDRILL_FCM_SCRIPT", "")
    _send_delay = float(os.environ.get("HSDRILL_SEND_DELAY", "0"))

    OAUTH_URL = "https://oauth2.googleapis.com/token"
    SEND_URL_TEMPLATE = ("https://fcm.googleapis.com/v1/projects/%s"
                         "/messages:send")

    _state = None  # loaded lazily: the patch installs without a script

    def _load():
        with open(_script_path, "r", encoding="utf-8") as f:
            script = json.load(f)
        state = {
            "token_to_device": {token: device for device, token in
                                script["devices"].items()},
            "responses": {device: list(resps) for device, resps in
                          script["responses"].items()},
            "oauth_token": script["oauth_token"],
            "send_url": SEND_URL_TEMPLATE % script.get(
                "project_id", "drill-project"),
        }
        return state

    def _log(line):
        if _wirelog_path:
            with open(_wirelog_path, "a", encoding="utf-8") as f:
                f.write("%s %s\n" % (_now(), line))

    class _FakeResponse:
        """The slice of urlopen()'s result the notify tools use:
        status / headers.get(...) / read(), as a context manager."""

        def __init__(self, status, body, headers=None):
            self.status = status
            self.headers = headers or {}
            self._body = body if isinstance(body, bytes) else \
                json.dumps(body).encode("utf-8")

        def read(self):
            return self._body

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def _error_body(status, error_status):
        return {"error": {"code": status, "message": "drill fake",
                          "status": error_status}}

    def _drill_urlopen(req, timeout=None):
        global _state
        if _state is None:
            _state = _load()
        url = req.full_url
        headers = {k.lower(): v for k, v in req.header_items()}
        if url == OAUTH_URL:
            _log("OAUTH")
            return _FakeResponse(200, {"access_token":
                                       _state["oauth_token"],
                                       "expires_in": 3600})
        if url != _state["send_url"]:
            _log("ANOMALY unexpected-url=%r" % url)
            return _FakeResponse(400, _error_body(400, "INVALID_ARGUMENT"))
        auth = headers.get("authorization", "")
        if auth != "Bearer %s" % _state["oauth_token"]:
            _log("ANOMALY bearer-mismatch")
            return _FakeResponse(401,
                                 _error_body(401, "THIRD_PARTY_AUTH_ERROR"))
        try:
            body = json.loads(bytes(req.data).decode("utf-8"))
        except (ValueError, UnicodeDecodeError, TypeError):
            _log("ANOMALY unparsable-body")
            return _FakeResponse(400, _error_body(400, "INVALID_ARGUMENT"))
        message = body.get("message") if isinstance(body, dict) else None
        token = message.get("token") if isinstance(message, dict) else None
        device = _state["token_to_device"].get(token)
        if device is None:
            _log("ANOMALY unknown-token=%s" %
                 ("sha256:" + hashlib.sha256(
                     str(token).encode("utf-8")).hexdigest()[:16]))
            return _FakeResponse(400, _error_body(400, "INVALID_ARGUMENT"))
        data = message.get("data") or {}
        token_hash = "sha256:" + hashlib.sha256(
            token.encode("utf-8")).hexdigest()[:16]
        if data.get("event_id"):
            # The single (per-event) message form — the exact
            # historical wirelog shape; the W3 timing parser reads it.
            _log("SEND %s %s %s" % (str(data["event_id"])[:16],
                                    device, token_hash))
        else:
            # The group forms (summary/digest): the composition kind,
            # the member count and the first covered event — the full
            # member list travels in the payload's event_ids.
            event_ids = str(data.get("event_ids", ""))
            _log("SEND %s count=%s first=%s %s %s" % (
                data.get("kind", "?"), data.get("count", "?"),
                event_ids.split(",", 1)[0][:16], device, token_hash))
        if _send_delay > 0:
            time.sleep(_send_delay)  # the SIGKILL window lives here
        script = _state["responses"].get(device) or \
            [{"status": 200, "name": "projects/drill/messages/m-fake"}]
        response = script.pop(0) if len(script) > 1 else script[0]
        status = int(response.get("status", 200))
        retry_after = response.get("retry_after")
        if status == 200:
            _log("RESP 200 %s" % device)
            return _FakeResponse(200, {"name": response.get(
                "name", "projects/drill/messages/m-fake")})
        _log("RESP %d %s" % (status, device))
        resp_headers = {}
        if retry_after is not None:
            resp_headers["Retry-After"] = str(retry_after)
        return _FakeResponse(
            status,
            _error_body(status, response.get("error_status",
                                            "INVALID_ARGUMENT")),
            headers=resp_headers)

    urllib.request.urlopen = _drill_urlopen
