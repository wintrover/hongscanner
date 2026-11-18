#!/usr/bin/env python3
"""Configuration loader for the notify tools (tools/notify/README.md §7).

The config file is user property OUTSIDE the repository; its path comes
from --config or $HSNOTIFY_CONFIG. Credential paths it names — the FCM
service-account key, the registration bearer secret and the device
registry (which stores registration tokens) — are REFUSED when they
resolve under this repository: credentials never enter the repository
(AGENTS.md §0.3; delivery.schema.json device_id x-ref). The event and
delivery ledgers carry no credential value, so they may live anywhere;
the drill keeps them in gitignored runs/ evidence directories.

Fail-closed: a missing, non-JSON or non-conforming config is a ConfigError
(exit 2 in the CLIs), never a default. Values below the vendor minimum
(retry_min_seconds) are not silently clamped: the live default IS the
vendor minimum and only synthetic drills/tests override it, on record.
The resident worker's tick interval (watch_poll_seconds, README §1/§7)
defaults to 1.0 and is bounded 0 < x <= 60: a zero or negative poll
would spin, an unbounded one would stall delivery.

The opening-peak section (peak_window) defaults to enabled, a 900-second
freshness bound and the one supported audible mode
("unlimited_per_group"); its validation is strict like admission's.
Being enabled is not the privilege: the dispatcher grants peak sound
only when the run's recorded session opening is KNOWN and the
observation is fresh (market_time owns the window arithmetic).
"""

import json
import os

import notify_fcm

REPO_ROOT = os.path.realpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", ".."))

# Per-command required path keys (tools/notify/README.md §7); project_id
# is a plain string key, validated separately for dispatch.
COMMAND_PATH_KEYS = {
    "ingest": {"ledger_path"},
    "check": {"ledger_path"},
    "dispatch": {"ledger_path", "delivery_path", "registry_path"},
    "register": {"registry_path", "register_bearer_file"},
}
INT_DEFAULTS = {"retry_min_seconds": 60, "backoff_cap_seconds": 900}
# The Global Attention Budget (README §0/§7): the sound admission window
# in seconds. Its default IS the policy (60 minutes); a zero would mean
# "no budget", so the key refuses anything below 1 (fail-closed).
AUDIBLE_COOLDOWN_DEFAULT = 3600
POSITIVE_INT_DEFAULTS = {"audible_cooldown_seconds": AUDIBLE_COOLDOWN_DEFAULT}
FLOAT_DEFAULTS = {"watch_poll_seconds": 1.0}
WATCH_POLL_MAX = 60

# The admission policy (README §0/§7; docs/ASSUMPTIONS.md P28): every
# event type in the admission universe — the same three TOP10 rank
# transitions the delivery policy has always allowed
# (notify_fcm.TOP10_EVENT_TYPES) — gets exactly one verdict mode:
# "immediate" (sound channel), "digest" (silent channel, batched per
# observation group) or "suppress" (never pushed; types outside the
# universe are always suppress — the type_skipped meaning). Plan B is
# the default; the config's admission section overrides it per type.
ADMISSION_MODES = ("immediate", "digest", "suppress")
ADMISSION_UNIVERSE = notify_fcm.TOP10_EVENT_TYPES
ADMISSION_DEFAULT = {
    "TOP10_ENTERED": "immediate",
    "TOP10_EXITED": "immediate",
    "RANK_CHANGED": "digest",
}

# The opening peak window (README §0/§7; the market_time authority):
# inside [open, open + 30m) KST on the run's session_date the per-group
# sound cap is lifted — every observation group may ring once (a group
# still yields at most one sound), with no global budget between
# groups. The privilege is granted only to a FRESH observation: 0 <=
# dispatch time - observed_at <= freshness_seconds. A future
# observation (negative age) is fail-closed. The section is strict (a
# typo would silently change when phones ring); absent -> these
# defaults. `enable` alone does not grant the privilege when the run's
# session opening is UNKNOWN (no --run-dir / no calendar record): the
# caller then keeps the P28 budget (fail-closed).
PEAK_AUDIBLE_MODES = ("unlimited_per_group",)
PEAK_WINDOW_DEFAULT = {
    "enable": True,
    "freshness_seconds": 900,
    "audible": "unlimited_per_group",
}

# The per-installation send deny-list (README §7): exact device_ids
# that stay registered in the registry but are never a send target.
# Absent -> [] (every active device is dispatched): the key has
# DENY-list polarity, so a missing key can never silence a device.
# Present -> a strict array of exact ids matching the registry's
# DEVICE_ID_RE; glob/regex patterns are refused (one typo must not
# turn a different device off). The registry itself is never written:
# exclusion is a dispatch policy, not a token fact.
DISABLED_DEVICES_KEY = "disabled_devices"


class ConfigError(Exception):
    """The config is missing, unreadable or non-conforming."""


def _require_abs_string(cfg, key):
    value = cfg.get(key)
    if not isinstance(value, str) or not value or \
       not os.path.isabs(value):
        raise ConfigError("%s must be a non-empty absolute path" % key)
    return value


def _refuse_under_repo(cfg, key):
    """A credential-bearing path may not resolve under this repository."""
    value = cfg.get(key)
    if not isinstance(value, str) or not value:
        return
    real = os.path.realpath(os.path.abspath(value))
    if real == REPO_ROOT or real.startswith(REPO_ROOT + os.sep):
        raise ConfigError("%s resolves inside the repository: credentials "
                          "never enter the repo (README §7)" % key)


def _validate_admission(cfg):
    """The one config section with NO permissive unknown-key policy
    (README §7): a typo in it would silently change the alert policy,
    so every key and value is checked. Absent -> the plan-B default
    (admission_source "default", which the admission report prints);
    present -> a {event_type: mode} mapping whose keys are admission-
    universe types and whose values are admission modes. Types the
    section does not name keep their plan-B default (the section is a
    per-type override, never a silent re-suppression)."""
    admission = cfg.get("admission")
    if admission is None:
        cfg["admission"] = dict(ADMISSION_DEFAULT)
        cfg["admission_source"] = "default"
        return
    if not isinstance(admission, dict):
        raise ConfigError("admission must be a JSON object "
                          "{event_type: mode}")
    unknown = set(admission) - set(ADMISSION_UNIVERSE)
    if unknown:
        raise ConfigError("admission names event types outside the "
                          "admission universe (%s): %s"
                          % (", ".join(sorted(ADMISSION_UNIVERSE)),
                             ", ".join(sorted(unknown))))
    for event_type, mode in admission.items():
        if mode not in ADMISSION_MODES:
            raise ConfigError("admission mode for %s must be one of %s "
                              "(got %r)" % (event_type,
                                            ", ".join(ADMISSION_MODES),
                                            mode))
    cfg["admission_source"] = "config"


def effective_admission(cfg):
    """The effective {event_type: mode} mapping for a config: the
    plan-B default overridden by the config's admission section. A
    config loaded through load_config always carries a validated
    section; a raw dict built without it (direct construction, tests)
    gets the default filled in — a missing key must never silently
    mean suppress."""
    merged = dict(ADMISSION_DEFAULT)
    admission = cfg.get("admission")
    if isinstance(admission, dict):
        merged.update(admission)
    return merged


def admission_mode(cfg, event_type):
    """The one admission verdict mode for an event type: "immediate",
    "digest" or "suppress" (types outside the admission universe are
    always "suppress"). THE shared verdict: the dispatch path and the
    --admission-report replay call this same function — replay judges
    exactly what production judges."""
    return effective_admission(cfg).get(event_type, "suppress")


def peak_window_settings(cfg):
    """The effective opening-peak section, validated with defaults.

    Absent -> PEAK_WINDOW_DEFAULT (enable true, freshness 900s,
    audible "unlimited_per_group"). A present section is strict like
    admission: a non-object, an unknown key, a non-bool `enable`, a
    non-positive/non-int `freshness_seconds` or any `audible` other
    than the one supported mode is a ConfigError. A raw dict built
    without load_config (direct construction, tests) gets the same
    defaults filled in — a missing section never silently disables the
    policy, and a typo never silently changes it."""
    section = cfg.get("peak_window")
    if section is None:
        section = {}
    if not isinstance(section, dict):
        raise ConfigError("peak_window must be a JSON object "
                          "{enable, freshness_seconds, audible}")
    unknown = set(section) - set(PEAK_WINDOW_DEFAULT)
    if unknown:
        raise ConfigError("peak_window names unknown keys: %s"
                          % ", ".join(sorted(unknown)))
    enable = section.get("enable", PEAK_WINDOW_DEFAULT["enable"])
    if not isinstance(enable, bool):
        raise ConfigError("peak_window.enable must be a boolean")
    freshness = section.get("freshness_seconds",
                            PEAK_WINDOW_DEFAULT["freshness_seconds"])
    if not isinstance(freshness, int) or isinstance(freshness, bool) or \
       freshness < 1:
        raise ConfigError("peak_window.freshness_seconds must be a "
                          "positive integer")
    audible = section.get("audible", PEAK_WINDOW_DEFAULT["audible"])
    if audible not in PEAK_AUDIBLE_MODES:
        raise ConfigError("peak_window.audible must be one of %s "
                          "(got %r)" % (", ".join(PEAK_AUDIBLE_MODES),
                                        audible))
    return {"enable": enable,
            "freshness_seconds": freshness,
            "audible": audible}


def _validate_peak_window(cfg):
    """Normalize the peak section into the loaded config (defaults
    filled); strict validation is peak_window_settings' job."""
    cfg["peak_window"] = peak_window_settings(cfg)


def _validate_disabled_devices(cfg):
    """Validate and normalize the send deny-list (README §7).

    An ABSENT key means every active device is a send target: the key
    is a deny-list, and its default may never silence a device. A
    PRESENT key must be an array of exact device_ids matching the
    registry's DEVICE_ID_RE (fullmatch: no glob/regex patterns, no
    surrounding whitespace, no trailing newline); anything else is a
    ConfigError (fail-closed), including an explicit JSON null. The
    ids are matched EXACTLY against active device ids, so a typo
    disables nothing instead of disabling the wrong phone."""
    if DISABLED_DEVICES_KEY not in cfg:
        cfg[DISABLED_DEVICES_KEY] = []
        return
    disabled = cfg[DISABLED_DEVICES_KEY]
    if not isinstance(disabled, list):
        raise ConfigError("%s must be an array of exact device_id "
                          "strings (got %r)"
                          % (DISABLED_DEVICES_KEY, disabled))
    # notify_ledger imports this module at import time; importing it
    # here (call time) keeps the registry's device-id grammar the one
    # definition without a circular module-level import.
    import notify_ledger
    for device_id in disabled:
        if not isinstance(device_id, str) or \
           notify_ledger.DEVICE_ID_RE.fullmatch(device_id) is None:
            raise ConfigError(
                "%s entries must be exact device_ids matching the "
                "registry pattern (got %r); glob/regex patterns are "
                "refused" % (DISABLED_DEVICES_KEY, device_id))
    cfg[DISABLED_DEVICES_KEY] = list(disabled)


def load_config(path, for_command):
    """Load and validate the config JSON for one command. Raises
    ConfigError on any deviation; there are no silent defaults except
    the documented INT/POSITIVE_INT/FLOAT/ADMISSION/PEAK/DISABLED
    defaults. Unknown top-level keys (a stale min_severity among them
    — the key is removed from the contract, README §7) pass through
    unvalidated: the policy no longer reads them. The admission,
    peak_window and disabled_devices keys are the validated
    exceptions."""
    if not isinstance(path, str) or not path:
        raise ConfigError("no config path (--config or $HSNOTIFY_CONFIG)")
    try:
        with open(path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except OSError as exc:
        raise ConfigError("config unreadable: %s" % exc)
    except ValueError as exc:
        raise ConfigError("config is not valid JSON: %s" % exc)
    if not isinstance(cfg, dict):
        raise ConfigError("config is not a JSON object")

    for key in COMMAND_PATH_KEYS[for_command]:
        _require_abs_string(cfg, key)

    if for_command == "dispatch":
        project_id = cfg.get("project_id")
        if not isinstance(project_id, str) or not project_id:
            raise ConfigError("project_id must be a non-empty string")
        has_sa = isinstance(cfg.get("service_account_path"), str) and \
            bool(cfg["service_account_path"])
        has_cmd = isinstance(cfg.get("token_command"), list) and \
            bool(cfg["token_command"])
        if has_sa == has_cmd:  # exactly one credential path
            raise ConfigError("dispatch needs exactly one of "
                              "service_account_path or token_command")
        if has_sa:
            _require_abs_string(cfg, "service_account_path")
        else:
            for arg in cfg["token_command"]:
                if not isinstance(arg, str) or not arg:
                    raise ConfigError("token_command entries must be "
                                      "non-empty strings")

    if for_command == "register":
        _require_abs_string(cfg, "register_bearer_file")

    # Credential-bearing paths never resolve under the repository.
    for key in ("registry_path", "service_account_path",
                "register_bearer_file"):
        _refuse_under_repo(cfg, key)

    for key, default in INT_DEFAULTS.items():
        value = cfg.get(key, default)
        if not isinstance(value, int) or isinstance(value, bool) or \
           value < 0:
            raise ConfigError("%s must be a non-negative integer" % key)
        cfg[key] = value

    for key, default in POSITIVE_INT_DEFAULTS.items():
        value = cfg.get(key, default)
        if not isinstance(value, int) or isinstance(value, bool) or \
           value < 1:
            raise ConfigError("%s must be a positive integer" % key)
        cfg[key] = value

    for key, default in FLOAT_DEFAULTS.items():
        value = cfg.get(key, default)
        if isinstance(value, bool) or \
           not isinstance(value, (int, float)) or \
           not 0 < value <= WATCH_POLL_MAX:
            raise ConfigError("%s must be a number with 0 < %s <= %d"
                              % (key, key, WATCH_POLL_MAX))
        cfg[key] = float(value)

    _validate_admission(cfg)
    _validate_peak_window(cfg)
    _validate_disabled_devices(cfg)
    return cfg
