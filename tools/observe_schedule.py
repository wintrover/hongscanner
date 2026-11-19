"""Checkpoint schedule — the run's own calendar opening is the authority.

The checkpoint times are not constants: the session opening recorded in
runs/session-<date>/input.hcj.jsonl (raw.days.<date>.open) decides them.
FIXED_CHECKPOINTS bracket the session (pre-open, post-close evidence);
PEAK_OFFSETS_MINUTES are measured from the recorded open, so a 09:00
opening puts checkpoints inside the [09:00, 09:30) peak. LEGACY_CHECKPOINTS
is the fallback only when no calendar opening is readable — it is the old
10:00-opening list and proves nothing about a 09:00 opening.

Pure functions: no I/O, no clock read.
"""

import re

FIXED_CHECKPOINTS = ("08:45", "08:55", "15:45")
PEAK_OFFSETS_MINUTES = (-5, 5, 15, 25, 35)
LEGACY_CHECKPOINTS = ("09:55", "10:05", "10:15", "10:25", "10:31")

_OPEN_RE = re.compile(r"^(\d{2}):(\d{2})")
_DAY_MINUTES = 24 * 60


def parse_open_hhmm(value):
    """'HH:MM' from a recorded open ('HH:MM:SS+09:00'), or None."""
    if not isinstance(value, str):
        return None
    match = _OPEN_RE.match(value)
    if match is None:
        return None
    hour, minute = int(match.group(1)), int(match.group(2))
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        return None
    return "%02d:%02d" % (hour, minute)


def _hhmm(total_minutes):
    return "%02d:%02d" % (total_minutes // 60, total_minutes % 60)


def schedule(open_value):
    """Sorted unique 'HH:MM' checkpoint list for a recorded opening."""
    opening = parse_open_hhmm(open_value)
    if opening is None:
        return sorted(set(FIXED_CHECKPOINTS) | set(LEGACY_CHECKPOINTS))
    base = int(opening[:2]) * 60 + int(opening[3:])
    names = set(FIXED_CHECKPOINTS)
    for offset in PEAK_OFFSETS_MINUTES:
        minutes = base + offset
        if 0 <= minutes < _DAY_MINUTES:
            names.add(_hhmm(minutes))
    return sorted(names)


def is_checkpoint(open_value, hhmm):
    """True iff hhmm is a checkpoint of the schedule for open_value."""
    return hhmm in schedule(open_value)