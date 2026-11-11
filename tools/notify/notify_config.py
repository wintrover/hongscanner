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
"""

import json
import os

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
FLOAT_DEFAULTS = {"watch_poll_seconds": 1.0}
WATCH_POLL_MAX = 60


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


def load_config(path, for_command):
    """Load and validate the config JSON for one command. Raises
    ConfigError on any deviation; there are no silent defaults except
    the documented INT/FLOAT_DEFAULTS. Unknown keys (a stale
    min_severity among them — the key is removed from the contract,
    README §7) pass through unvalidated: the policy no longer reads
    them."""
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

    for key, default in FLOAT_DEFAULTS.items():
        value = cfg.get(key, default)
        if isinstance(value, bool) or \
           not isinstance(value, (int, float)) or \
           not 0 < value <= WATCH_POLL_MAX:
            raise ConfigError("%s must be a number with 0 < %s <= %d"
                              % (key, key, WATCH_POLL_MAX))
        cfg[key] = float(value)
    return cfg
