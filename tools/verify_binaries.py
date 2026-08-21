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

바이너리를 의도적으로 바꿨다면 `--update <경로>` 로 실측값을 매니페스트에 써넣는다.
손으로 sha256 을 옮겨적다 틀리는 일을 없앤다. 대상 경로를 반드시 명시해야 하는데,
일괄 갱신은 의도치 않은 변경까지 함께 승인해버려 이 검사의 존재 이유를 지우기 때문이다.
`required_strings` 는 갱신하지 않는다 — 그건 실측이 아니라 사람이 정하는 계약이다.

`--update` 는 지정한 항목만 갱신하고 **그 항목만 보고한다.** 남이 낸 drift 가 섞이면
내가 낸 것과 구분할 수 없고, 그러면 경고 전체를 무시하게 된다. 저장소 전체 점검은
인자 없이 실행한다 — CI 가 하는 것도 그것이다.
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


def measure(path_str: str) -> Tuple[Dict[str, Any], List[str]]:
    """(실측값, 재지 못한 필드의 사유). 계산할 수 없는 필드는 결과에서 뺀다."""
    path = ROOT / path_str
    if not path.is_file():
        raise ValueError("파일이 없다")

    actual: Dict[str, Any] = {}
    skipped: List[str] = []

    sha, is_real = read_content_hash(path)
    actual["sha256"] = sha

    size = path.stat().st_size if is_real else pointer_size(path)
    if size is None:
        skipped.append("size — LFS 포인터에서 크기를 못 읽었다")
    else:
        actual["size"] = size

    mode = index_mode(path_str)
    if mode is None:
        skipped.append("mode — git index 에 없다. 먼저 git add 한다")
    else:
        actual["mode"] = mode

    # arch 는 실제 ELF 를 봐야 안다. LFS 포인터만 있으면 기존 값을 그대로 둔다.
    if not is_real:
        skipped.append("arch — LFS 포인터라 ELF 를 볼 수 없다")
    else:
        arch = elf_arch(path)
        if arch is None:
            skipped.append("arch — ELF 가 아니다")
        else:
            actual["arch"] = arch

    return actual, skipped


def brief(value: Any) -> str:
    text = "(없음)" if value is None else str(value)
    return f"{text[:12]}…" if len(text) > 16 else text


def apply_updates(entries: List[Dict[str, Any]], targets: List[str],
                  set_commit: Optional[str]) -> Tuple[List[str], List[str]]:
    """지정한 항목만 실측값으로 덮어쓴다. (바뀐 줄, 못 잰 필드 줄)."""
    by_path = {entry["path"]: entry for entry in entries}
    unknown = [t for t in targets if t not in by_path]
    if unknown:
        raise SystemExit(
            "매니페스트에 없는 경로: " + ", ".join(unknown)
            + "\n등록된 경로:\n  " + "\n  ".join(by_path))

    # 커밋 해시는 한 상위 저장소 안에서만 뜻이 있다. 출처가 다른 바이너리에
    # 같은 해시를 박으면 기록이 조용히 거짓이 된다.
    if set_commit is not None:
        repos = {(by_path[t].get("source") or {}).get("repo") for t in targets}
        if len(repos) > 1:
            raise SystemExit(
                "--set-commit 대상의 상위 저장소가 서로 다르다: "
                + ", ".join(sorted(str(r) for r in repos))
                + "\n저장소별로 나눠서 실행한다.")

    changes: List[str] = []
    notes: List[str] = []
    for target in targets:
        entry = by_path[target]
        try:
            actual, skipped = measure(target)
        except (OSError, ValueError) as exc:
            raise SystemExit(f"{target}: {exc}")

        edits: List[str] = []
        for field, value in actual.items():
            before = entry.get(field)
            if before != value:
                entry[field] = value
                edits.append(f"      {field}: {brief(before)} -> {brief(value)}")

        if set_commit is not None:
            source = entry.get("source")
            if not isinstance(source, dict):
                raise SystemExit(
                    f"{target}: source 가 비어 있어 commit 을 넣을 수 없다. "
                    "출처가 기록되지 않은 바이너리다 — 매니페스트에서 source 를 먼저 채운다.")
            if source.get("commit") != set_commit:
                edits.append(f"      source.commit: "
                             f"{brief(source.get('commit'))} -> {brief(set_commit)}")
                source["commit"] = set_commit

        # 경로 머리글은 대상마다 한 번만. 필드마다 반복하면 무엇이 바뀌었는지 안 보인다.
        if edits:
            changes.append(f"  {target}")
            changes.extend(edits)
        if skipped:
            notes.append(f"  {target}")
            notes.extend(f"      건너뜀: {reason}" for reason in skipped)

    return changes, notes


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
    parser.add_argument(
        "--update", nargs="+", metavar="PATH",
        help="지정한 항목의 sha256/size/mode/arch 를 실측값으로 덮어쓰고, 그 항목만 검증해 "
             "보고한다. 저장소 전체 점검은 인자 없이 실행한다.")
    parser.add_argument(
        "--set-commit", metavar="REF",
        help="--update 대상의 source.commit 을 이 값으로 바꾼다. 상위 저장소 커밋 해시.")
    args = parser.parse_args()
    if args.set_commit and not args.update:
        parser.error("--set-commit 은 --update 와 함께 쓴다. 갱신할 대상이 있어야 한다.")

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1:
        raise SystemExit(f"지원하지 않는 매니페스트 schema: {manifest.get('schema')}")
    entries = manifest["binaries"]

    if args.update:
        changes, notes = apply_updates(entries, args.update, args.set_commit)
        print("=== 매니페스트 갱신 ===")
        if changes:
            args.manifest.write_text(
                json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            print("\n".join(changes))
        else:
            print("  실측값이 이미 매니페스트와 같다 — 파일을 쓰지 않았다.")
        if notes:
            print("\n".join(notes))
        print()

    # 갱신 실행은 그 항목만 본다. 무관한 항목의 경고가 섞이면 내가 낸 것과 남이 낸
    # 것을 구분할 수 없고, 그러면 경고 전체를 무시하게 된다. 미등록 스캔도 같은
    # 이유로 전체 점검에서만 돈다.
    checked = entries
    if args.update:
        wanted = set(args.update)
        checked = [entry for entry in entries if entry["path"] in wanted]

    findings: List[Finding] = []
    rows: List[Dict[str, str]] = []
    for entry in checked:
        entry_findings, row = check_entry(entry)
        findings.extend(entry_findings)
        rows.append(row)

    if not args.update:
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
    elif args.update:
        print("\n갱신한 항목이 매니페스트와 일치한다.")
        print("저장소 전체 점검은 인자 없이: python3 tools/verify_binaries.py")
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
