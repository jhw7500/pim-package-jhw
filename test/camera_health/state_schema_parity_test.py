#!/usr/bin/env python3
"""service-state 스키마 조건의 두 사본이 어긋나지 않는지 본다.

cam_operate_control.sh 는 같은 조건을 두 곳에 적는다.

  * ``_coc_state_schema``  — 읽기 쪽 검증. runtime_consumer_path_test.py 의
    ``proven_helpers()`` 가 이 함수를 ``_coc_state_current`` 의 quiet_validator
    로 인정하는데, 그 정규식이 본문을 ``jq -e '<단일따옴표 리터럴>'`` 형태로
    못박아 셸 변수로 뽑아낼 수 없다.
  * ``_COC_STATE_CANONICAL_FILTER`` 의 ``select(...)`` — 쓰기 쪽 검증. service-state
    를 쓰는 네 함수가 모두 이 변수로 끝나는 jq 하나로 쓸 문서를 만든다 (이슈 #168).
    그래서 이 테스트는 그 변수가 최상위에서 한 번만 대입되는지(비면 jq 1.6 은 빈
    프로그램을 ``.`` 로 돌려 검증 없이 쓴다), service-state 를 쓰는 함수가 그 넷뿐인지,
    넷 모두 쓰기 직전의 jq 가 그 변수로 끝나는지도 본다.

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
    r"^_COC_STATE_CANONICAL_FILTER='[^']*?\|\s*select\((?P<filter>[^']*)\)'$",
    re.M,
)
_ASSIGN = re.compile(r"^(?P<prefix>.*?)\b_COC_STATE_CANONICAL_FILTER=", re.M)
_FUNCTION = re.compile(r"^(?P<name>[A-Za-z_]\w*)\(\)\s*\{\n(?P<body>.*?)^\}", re.M | re.S)
_SERVICE_WRITE = '_cr_atomic_write "$(_cr_service_file)"'
_FILTER_END = re.compile(r'\$_COC_STATE_CANONICAL_FILTER"(?:\s*<<<"\$\w+")?\)\s*\|\|\s*return 70$')
_WRITERS = {"_coc_write_state", "_coc_set_dirty", "_coc_persist_success", "cam_mark_degraded"}


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
        failures.append("_COC_STATE_CANONICAL_FILTER='...| select(...)' 정의를 찾지 못했다.")

    assigns = list(_ASSIGN.finditer(source))
    if len(assigns) != 1 or assigns[0].group("prefix") != "":
        failures.append(
            "_COC_STATE_CANONICAL_FILTER 는 최상위에서 한 번만 대입해야 한다 "
            f"(찾은 대입 {len(assigns)}개: {[a.group(0) for a in assigns]})."
        )

    writers = {}
    for fn in _FUNCTION.finditer(source):
        body = fn.group("body")
        if _SERVICE_WRITE in body:
            writers[fn.group("name")] = body
    if set(writers) != _WRITERS:
        failures.append(
            "service-state 를 쓰는 함수가 바뀌었다: "
            f"{sorted(writers)} (기대 {sorted(_WRITERS)}). "
            "새 쓰기는 이 필터로 끝나는 jq 로 만들고 여기에 더한다."
        )
    for name, body in sorted(writers.items()):
        # 쓰기 직전 jq 명령(마지막 'jq ' 부터 첫 '|| return 70' 까지)이 이 변수로 끝나야 한다.
        head = body[: body.index(_SERVICE_WRITE)]
        command = head[head.rfind("jq "):] if "jq " in head else ""
        end = command.find("|| return 70")
        command = command[: end + len("|| return 70")] if end >= 0 else ""
        if not _FILTER_END.search(command):
            failures.append(
                f"{name}: service-state 를 쓰기 직전의 jq 가 _COC_STATE_CANONICAL_FILTER 로 끝나지 않는다."
            )

    if failures:
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
            f"       _COC_STATE_CANONICAL_FILTER : {write_filter}"
        )
        print("\nservice-state schema parity: 1 failure(s)")
        return 1

    clauses = read_filter.count(" and ") + 1
    print(f"  OK   read/write schema conditions identical ({clauses} clauses)")
    print(
        "  OK   _COC_STATE_CANONICAL_FILTER assigned once at top level and ends the jq "
        f"of all {len(_WRITERS)} service-state writers"
    )
    print("\nservice-state schema parity: 0 failure(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
