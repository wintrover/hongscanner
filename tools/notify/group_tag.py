"""The Android notification slot tag shared by the dispatcher and the
post attestation tool.

A sound unit is one (observed_at, device_id) observation group
(tools/notify/README.md §0). The tag names that unit's slot in the
Android tray: the same group reuses the same slot, different groups get
different slots. The tag is identity only — the server's admission stays
the sole authority on whether a sound is sent.
"""

SEPARATOR = "|"
PREFIX = "hs-g"


def _check(field, value):
    if not isinstance(value, str) or not value:
        raise ValueError("%s must be a non-empty string" % field)
    if any(ch.isspace() for ch in value) or SEPARATOR in value:
        raise ValueError("%s must not contain whitespace or %r"
                         % (field, SEPARATOR))


def group_tag(observed_at, device_id):
    _check("observed_at", observed_at)
    _check("device_id", device_id)
    return SEPARATOR.join((PREFIX, observed_at, device_id))


def parse_group_tag(tag):
    parts = tag.split(SEPARATOR) if isinstance(tag, str) else []
    if len(parts) != 3 or parts[0] != PREFIX:
        raise ValueError("not a group tag: %r" % (tag,))
    return parts[1], parts[2]