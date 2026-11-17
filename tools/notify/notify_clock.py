#!/usr/bin/env python3
"""Same-boot monotonic time stamps for log lines (tools/notify/README.md
§1 "Time instrumentation").

time.monotonic_ns() is immune to wall-clock adjustment (NTP steps,
manual clock sets) but comparable only within one boot; boot_id — the
kernel's random boot identifier — names that boot. stamp() prints both
so elapsed-time reasoning stays inside one boot: mono_ns values from
different boot_ids (or different devices) are never subtracted.
"""

import time


def boot_id():
    try:
        return open("/proc/sys/kernel/random/boot_id").read().strip()
    except OSError:
        return "unknown"


def stamp():
    return "mono_ns=%d boot_id=%s" % (time.monotonic_ns(), boot_id())
