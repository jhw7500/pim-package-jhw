#!/usr/bin/env python3
"""추적되는 바이너리를 `.github/binary-manifest.json` 과 대조한다.

`.ko` 와 `gstApp` 은 diff 로 내용을 볼 수 없다. 리뷰어가 확인할 수 있는 건 PR 설명에
적힌 주장뿐이고, 그 주장이 실제 파일과 맞는지 검사하는 곳이 없었다. 이 스크립트가
그 자리를 메운다.

**불일치는 경고이지 실패가 아니다.** 검증되지 않은 중간 상태로 작업하는 경우가 흔해서,
차단하면 도움이 아니라 방해가 된다. 종료 코드는 기본 0이고, 막고 싶을 때만 `--strict`.

검사 항목:

  sha256   LFS 포인터면 `oid sha256:` 를 쓴다 — 그게 곧 내용 해시라 다운로드가 필요 없다.
  mode     git index 기준. 디스크 권한이 아니다 — 이 저장소는 core.fileMode=false 라
           디스크 권한이 git 에 반영되지 않고, 새 파일이 조용히 644 로 들어간 전례가 있다.
  arch     실제 ELF 일 때만. 호스트에서 빌드한 x86 바이너리가 섞여 들어가는 걸 잡는다.
  strings  실제 ELF 일 때만. 예: gstApp 에 health producer 심볼이 있는지 —
           producer 가 빠진 빌드가 패키지에 실린 적이 있다.

매니페스트에 없는 추적 바이너리도 경고한다(등록 없이 추가된 것).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / ".github/binary-manifest.json"

# 매니페스트에 등록돼 있어야 하는 대상. 여기 걸리는데 매니페스트에 없으면 경고한다.
TRACKED_PATTERN = re.compile(r"^dist/.*?(\.ko|/usr/local/bin/[^/]+)$")

LFS_POINTER_PREFIX = b"version https://git-lfs"


class Finding:
    def __init__(self, path: str, kind: str, detail: str) -> None:
        self.path = path
        self.kind = kind
        self.detail = detail


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=str(ROOT), check=True, capture_output=True, text=True
    ).stdout


def index_mode(path: str) -> Optional[str]:
    """git index 가 기록한 모드. 디스크 권한과 다를 수 있다."""
    line = git("ls-files", "--stage", "--", path).strip()
    return line.split()[0] if line else None


def read_content_hash(path: Path) -> Tuple[str, bool]:
    """(sha256, 실제_바이너리인가). LFS 포인터면 oid 를 그대로 쓴다."""
    with path.open("rb") as stream:
        head = stream.read(len(LFS_POINTER_PREFIX))
    if head == LFS_POINTER_PREFIX:
        text = path.read_text(encoding="utf-8", errors="replace")
        found = re.search(r"^oid sha256:([0-9a-f]{64})$", text, re.MULTILINE)
        if not found:
            raise ValueError("LFS 포인터인데 oid 를 못 읽었다")
        return found.group(1), False
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest(), True


def pointer_size(path: Path) -> Optional[int]:
    text = path.read_text(encoding="utf-8", errors="replace")
    found = re.search(r"^size (\d+)$", text, re.MULTILINE)
    return int(found.group(1)) if found else None


def elf_arch(path: Path) -> Optional[str]:
    """ELF 헤더 e_machine 을 직접 읽는다. `file` 명령에 의존하지 않는다."""
    with path.open("rb") as stream:
        header = stream.read(20)
    if len(header) < 20 or header[:4] != b"\x7fELF":
        return None
    little = header[5] == 1
    machine = int.from_bytes(header[18:20], "little" if little else "big")
    return {0x3E: "x86_64", 0xB7: "aarch64", 0x28: "arm"}.get(machine, f"0x{machine:x}")


def has_strings(path: Path, needles: List[str]) -> List[str]:
    """바이너리에서 못 찾은 문자열 목록을 돌려준다."""
    blob = path.read_bytes()
    return [n for n in needles if n.encode() not in blob]


def check_entry(entry: Dict[str, Any]) -> Tuple[List[Finding], Dict[str, str]]:
    path_str = entry["path"]
    path = ROOT / path_str
    findings: List[Finding] = []
    row = {"path": path_str, "sha256": "-", "size": "-", "mode": "-",
           "arch": "-", "strings": "-"}

    if not path.is_file():
        findings.append(Finding(path_str, "missing", "매니페스트에 있는데 파일이 없다"))
        row["sha256"] = "파일 없음"
        return findings, row

    try:
        actual_sha, is_real = read_content_hash(path)
    except (OSError, ValueError) as exc:
        findings.append(Finding(path_str, "unreadable", str(exc)))
        row["sha256"] = "읽기 실패"
        return findings, row

    expected_sha = entry.get("sha256")
    if expected_sha and actual_sha != expected_sha:
        findings.append(Finding(
            path_str, "sha256",
            f"기대 {expected_sha[:16]}… / 실제 {actual_sha[:16]}… "
            "— 바이너리를 바꾸고 매니페스트를 갱신하지 않았거나, 예기치 않은 변경",
        ))
        row["sha256"] = f"불일치 {actual_sha[:12]}…"
    elif expected_sha:
        row["sha256"] = f"OK {actual_sha[:12]}…"
    else:
        row["sha256"] = f"미등록 {actual_sha[:12]}…"

    expected_size = entry.get("size")
    actual_size = path.stat().st_size if is_real else pointer_size(path)
    if not expected_size:
        row["size"] = "미등록"
    elif actual_size is None:
        findings.append(Finding(
            path_str, "size", "크기를 읽지 못했다 — LFS 포인터가 손상됐을 수 있다"))
        row["size"] = "읽기 실패"
    elif actual_size != expected_size:
        findings.append(Finding(
            path_str, "size", f"기대 {expected_size} / 실제 {actual_size} 바이트"))
        row["size"] = f"불일치 {actual_size}"
    else:
        row["size"] = "OK"

    expected_mode = entry.get("mode")
    actual_mode = index_mode(path_str)
    if expected_mode and actual_mode and actual_mode != expected_mode:
        findings.append(Finding(
            path_str, "mode",
            f"git index 모드 기대 {expected_mode} / 실제 {actual_mode} "
            "— core.fileMode=false 라 디스크 권한으로는 안 보인다",
        ))
        row["mode"] = f"불일치 {actual_mode}"
    else:
        row["mode"] = actual_mode or "-"

    # 아래 둘은 실제 ELF 가 있을 때만 가능하다. CI 는 LFS 를 받지 않으므로
    # `.ko` 는 포인터로만 보이고, 그 경우 sha256 대조로 무결성은 이미 확인된다.
    if not is_real:
        row["arch"] = "LFS 포인터(생략)"
        row["strings"] = "LFS 포인터(생략)"
        return findings, row

    expected_arch = entry.get("arch")
    actual_arch = elf_arch(path)
    if expected_arch and actual_arch and actual_arch != expected_arch:
        findings.append(Finding(
            path_str, "arch",
            f"기대 {expected_arch} / 실제 {actual_arch} — 호스트 빌드가 섞였을 수 있다"))
        row["arch"] = f"불일치 {actual_arch}"
    else:
        row["arch"] = actual_arch or "-"

    needles = entry.get("required_strings") or []
    if needles:
        missing = has_strings(path, needles)
        if missing:
            findings.append(Finding(
                path_str, "strings",
                f"없는 문자열: {', '.join(missing)} — 기능이 빠진 빌드일 수 있다"))
            row["strings"] = f"누락 {len(missing)}/{len(needles)}"
        else:
            row["strings"] = f"OK {len(needles)}개"

    return findings, row


def unregistered(known: List[str]) -> List[str]:
    out = []
    for line in git("ls-files").splitlines():
        if TRACKED_PATTERN.search(line) and line not in known:
            out.append(line)
    return out


def emit_annotation(finding: Finding) -> None:
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return
    # Actions 워크플로우 명령은 %, \r, \n 을 인코딩해야 파싱이 깨지지 않는다.
    detail = (finding.detail.replace("%", "%25")
              .replace("\r", " ").replace("\n", " "))
    path = finding.path.replace("%", "%25").replace(",", "%2C")
    print(f"::warning file={path}::[{finding.kind}] {detail}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--strict", action="store_true",
        help="불일치가 있으면 종료 코드 1. 기본은 경고만 하고 0 으로 끝난다.")
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1:
        raise SystemExit(f"지원하지 않는 매니페스트 schema: {manifest.get('schema')}")
    entries = manifest["binaries"]

    findings: List[Finding] = []
    rows: List[Dict[str, str]] = []
    for entry in entries:
        entry_findings, row = check_entry(entry)
        findings.extend(entry_findings)
        rows.append(row)

    for path_str in unregistered([e["path"] for e in entries]):
        findings.append(Finding(
            path_str, "unregistered",
            "추적되는 바이너리인데 매니페스트에 없다 — .github/binary-manifest.json 에 등록한다"))

    print("=== 바이너리 검증 ===")
    for row in rows:
        print(f"  {row['path']}")
        print(f"      sha256 {row['sha256']}   size {row['size']}   mode {row['mode']}   "
              f"arch {row['arch']}   strings {row['strings']}")
    sys.stdout.flush()

    if findings:
        print(f"\n경고 {len(findings)}건:", file=sys.stderr)
        for finding in findings:
            print(f"  [{finding.kind}] {finding.path} — {finding.detail}", file=sys.stderr)
            emit_annotation(finding)
    else:
        print("\n모든 항목이 매니페스트와 일치한다.")

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as stream:
            stream.write("## 바이너리 검증\n\n")
            stream.write("| 파일 | sha256 | size | mode | arch | strings |\n"
                         "|---|---|---|---|---|---|\n")
            for row in rows:
                stream.write(f"| `{row['path']}` | {row['sha256']} | {row['size']} "
                             f"| {row['mode']} | {row['arch']} | {row['strings']} |\n")
            if findings:
                stream.write(f"\n**경고 {len(findings)}건** (차단하지 않음)\n\n")
                for finding in findings:
                    stream.write(f"- `{finding.path}` **[{finding.kind}]** {finding.detail}\n")
                stream.write("\n바이너리를 의도적으로 바꿨다면 "
                             "`.github/binary-manifest.json` 을 같은 커밋에서 갱신한다.\n")
            else:
                stream.write("\n모든 항목이 매니페스트와 일치한다.\n")

    if findings and args.strict:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
