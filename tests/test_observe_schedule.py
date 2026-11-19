#!/usr/bin/env python3
"""tools/observe_schedule.py 계약 테스트 — 표준 라이브러리만 사용한다.

권위는 런 달력의 open 하나다: 09:00 개장이면 체크포인트가 개장 피크
[09:00, 09:30) 안에 있어야 하고, 달력이 없을 때만 레거시(10:00 개장)
목록으로 후퇴한다. 이 테스트는 그 판정 축과 정렬·고유 불변식을 고정한다.

실행: python3 tests/test_observe_schedule.py
"""
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(REPO_ROOT, "tools"))

from observe_schedule import (  # noqa: E402
    FIXED_CHECKPOINTS, LEGACY_CHECKPOINTS, is_checkpoint, parse_open_hhmm,
    schedule)

FALLBACK = sorted(set(FIXED_CHECKPOINTS) | set(LEGACY_CHECKPOINTS))
FAILURES = []


def check(name, actual, expected):
    if actual == expected:
        print("PASS %s" % name)
    else:
        print("FAIL %s: expected %r, got %r" % (name, expected, actual))
        FAILURES.append(name)


def main():
    check("schedule(09:00)",
          schedule("09:00"),
          ["08:45", "08:55", "09:05", "09:15", "09:25", "09:35", "15:45"])
    check("peak checkpoint present for 09:00 open",
          "09:05" in schedule("09:00"), True)
    check("schedule(10:00)",
          schedule("10:00"),
          ["08:45", "08:55", "09:55", "10:05", "10:15", "10:25", "10:35",
           "15:45"])
    check("timestamp form equals bare HH:MM",
          schedule("10:00:00+09:00"), schedule("10:00"))
    check("schedule(None) falls back", schedule(None), FALLBACK)
    check("fallback has 8 checkpoints", len(FALLBACK), 8)
    check("fallback keeps legacy 10:31", "10:31" in FALLBACK, True)
    check("schedule('bad') falls back", schedule("bad"), FALLBACK)
    check("no negative checkpoint for 00:02 open",
          [name for name in schedule("00:02") if name < "00:00"], [])
    check("00:02 open keeps 00:07", "00:07" in schedule("00:02"), True)
    check("no checkpoint past 23:59 for 23:50 open",
          [name for name in schedule("23:50") if name > "23:59"], [])
    check("is_checkpoint 09:00/09:05",
          is_checkpoint("09:00", "09:05") is True, True)
    check("is_checkpoint 09:00/10:05",
          is_checkpoint("09:00", "10:05") is False, True)
    check("parse_open_hhmm rejects bad input", parse_open_hhmm("bad"), None)
    check("parse_open_hhmm keeps HH:MM",
          parse_open_hhmm("09:00:00+09:00"), "09:00")

    for open_value in ("09:00", "10:00", "10:31", "00:02", "23:50",
                       None, "bad", ""):
        values = schedule(open_value)
        check("sorted and unique for %r" % (open_value,),
              values == sorted(set(values)), True)
        check("HH:MM shape for %r" % (open_value,),
              all(len(name) == 5 and name[2] == ":" for name in values), True)

    if FAILURES:
        print("FAILED %d of the checks above" % len(FAILURES))
        return 1
    print("ALL OBSERVE SCHEDULE CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())