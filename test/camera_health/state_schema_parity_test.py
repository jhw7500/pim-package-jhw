#!/usr/bin/env python3
"""service-state 스키마 조건의 두 사본이 어긋나지 않는지 본다.

cam_operate_control.sh 는 같은 조건을 두 곳에 적는다.

  * ``_coc_state_schema``  — 읽기 쪽 검증. runtime_consumer_path_test.py 의
    ``proven_helpers()`` 가 이 함수를 ``_coc_state_current`` 의 quiet_validator
    로 인정하는데, 그 정규식이 본문을 ``jq -e '<단일따옴표 리터럴>'`` 형태로
    못박아 셸 변수로 뽑아낼 수 없다.
  * ``_coc_write_state`` 의 ``select(...)`` — 쓰기 쪽 검증.

쓰기 쪽이 읽기 쪽보다 느슨해지면, 저장된 문서를 다음 부팅의
``cam_plan_startup_action`` 이 검증에 실패시켜 계획이 module_reload 에서
camera_hard_reset 으로 조용히 떨어진다. 그래서 두 사본은 반드시 같아야 한다.

한쪽만 고치면 이 테스트가 실패한다.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "dist/pim/opt/pim/lib/cam_operate_control.sh"

_READ_SIDE = re.compile(
    r"_coc_state_schema\(\)\s*\{\s*jq\s+-e\s+'(?P<filter>[^']*)'\s*>\s*/dev/null",
    re.S,
)
_WRITE_SIDE = re.compile(
    r"_coc_write_state\(\)\s*\{.*?jq\s+-c\s+'.*?\|\s*select\((?P<filter>.*?)\)'\s*<<<",
    re.S,
)


def normalize(filter_text: str) -> str:
    """조건을 공백 정규화한다 (줄바꿈·들여쓰기 차이는 무시)."""
    return " ".join(filter_text.split())


def main() -> int:
    source = TARGET.read_text(encoding="utf-8")

    read_match = _READ_SIDE.search(source)
    write_match = _WRITE_SIDE.search(source)

    failures: list[str] = []
    if read_match is None:
        failures.append(
            "_coc_state_schema 의 jq -e '<리터럴>' 본문을 찾지 못했다. "
            "형태를 바꾸면 runtime_consumer_path_test.py 의 quiet_validator "
            "인정도 함께 깨진다."
        )
    if write_match is None:
        failures.append("_coc_write_state 의 select(...) 조건을 찾지 못했다.")

    if read_match is None or write_match is None:
        for item in failures:
            print(f"  FAIL {item}")
        print(f"\nservice-state schema parity: {len(failures)} failure(s)")
        return 1

    read_filter = normalize(read_match.group("filter"))
    write_filter = normalize(write_match.group("filter"))
    if read_filter != write_filter:
        print(
            "  FAIL 읽기/쓰기 스키마 조건이 다르다.\n"
            f"       _coc_state_schema : {read_filter}\n"
            f"       _coc_write_state  : {write_filter}"
        )
        print("\nservice-state schema parity: 1 failure(s)")
        return 1

    clauses = read_filter.count(" and ") + 1
    print(f"  OK   read/write schema conditions identical ({clauses} clauses)")
    print("\nservice-state schema parity: 0 failure(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
