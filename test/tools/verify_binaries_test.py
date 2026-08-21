#!/usr/bin/env python3
"""`tools/verify_binaries.py --update` 의 CLI 계약을 검사한다. 보드가 필요 없다.

값을 하드코딩하지 않는다. 매니페스트 사본을 일부러 어긋나게 만든 뒤 `--update` 가
그것을 원본과 바이트 단위로 되돌리는지 본다. 그래서 바이너리를 갱신해도 이 테스트는
고쳐 쓸 필요가 없다.

실제 `.github/binary-manifest.json` 과 `dist/` 의 바이너리는 읽기만 한다.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/verify_binaries.py"
MANIFEST = ROOT / ".github/binary-manifest.json"

# gstApp 은 LFS 가 아니라 항상 실제 ELF 로 존재한다. LFS 를 받지 않은 체크아웃에서도
# arch 갱신 경로까지 검사할 수 있어야 하므로 주 대상으로 쓴다.
GSTAPP = "dist/pim/usr/local/bin/gstApp"
DRIVER = "dist/pim/opt/pim/driver/max9296.ko"


def run(manifest: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--manifest", str(manifest), *args],
        cwd=str(ROOT), capture_output=True, text=True,
    )


def minimal_tree(root: Path, body: str, arch: str = "aarch64") -> Tuple[Path, str]:
    """arch 를 선언한 항목 하나만 있는 최소 저장소. (스크립트 경로, 대상 경로).

    실제 dist/ 바이너리는 건드릴 수 없으므로, ELF 가 아닌 파일을 다루는 경로는
    별도 트리에서만 시험한다."""
    target = "dist/pim/usr/local/bin/streamApp"
    (root / target).parent.mkdir(parents=True, exist_ok=True)
    (root / target).write_text(body, encoding="utf-8")
    (root / "tools").mkdir(exist_ok=True)
    (root / ".github").mkdir(exist_ok=True)
    shutil.copy(SCRIPT, root / "tools" / SCRIPT.name)
    (root / ".github/binary-manifest.json").write_text(json.dumps({
        "schema": 1,
        "binaries": [{
            "path": target,
            "sha256": "0" * 64,
            "size": 1,
            "mode": "100644",
            "arch": arch,
            "source": None,
        }],
    }, indent=2), encoding="utf-8")
    for args in (["init", "-q"], ["add", "-A"]):
        subprocess.run(["git", *args], cwd=str(root), capture_output=True, check=False)
    return root / "tools" / SCRIPT.name, target


def load(manifest: Path) -> Dict[str, Any]:
    return json.loads(manifest.read_text(encoding="utf-8"))


def entry_of(manifest: Path, path: str) -> Dict[str, Any]:
    for item in load(manifest)["binaries"]:
        if item["path"] == path:
            return item
    raise SystemExit(f"매니페스트에 {path} 가 없다 — 테스트 전제가 깨졌다")


def null_source_path() -> Optional[str]:
    """source 가 기록되지 않은 항목 하나. 없으면 해당 검사를 건너뛴다."""
    for item in load(MANIFEST)["binaries"]:
        if not isinstance(item.get("source"), dict):
            return item["path"]
    return None


def write(manifest: Path, data: Dict[str, Any]) -> None:
    manifest.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def corrupt(manifest: Path, path: str, **fields: Any) -> None:
    data = load(manifest)
    for item in data["binaries"]:
        if item["path"] == path:
            for key, value in fields.items():
                if key == "commit":
                    item["source"]["commit"] = value
                else:
                    item[key] = value
    write(manifest, data)


class Tests:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0

    def check(self, condition: bool, label: str) -> None:
        if condition:
            self.passed += 1
            print(f"  OK   {label}")
        else:
            self.failed += 1
            print(f"  FAIL {label}", file=sys.stderr)

    def run(self) -> int:
        print("=== verify_binaries --update ===")
        if not SCRIPT.is_file():
            print("  FAIL tools/verify_binaries.py 가 없다", file=sys.stderr)
            return 1
        with tempfile.TemporaryDirectory(prefix="verify-binaries-test.") as temporary:
            work = Path(temporary)
            self.misuse_tests(work)
            self.update_tests(work)
            self.scope_tests(work)
            self.elf_tests(work)
        print()
        print(f"verify_binaries --update: {self.passed} passed / {self.failed} failed")
        return 1 if self.failed else 0

    # --- 잘못된 사용은 조용히 넘어가지 않는다 ---------------------------------

    def misuse_tests(self, work: Path) -> None:
        manifest = work / "misuse.json"
        shutil.copy(MANIFEST, manifest)

        result = run(manifest, "--set-commit", "deadbee")
        self.check(result.returncode == 2,
                   "--set-commit 을 --update 없이 쓰면 argparse 오류")

        result = run(manifest, "--update", "dist/pim/nope")
        self.check(result.returncode == 1 and GSTAPP in result.stdout + result.stderr,
                   "없는 경로는 등록된 경로 목록과 함께 거부")

        result = run(manifest, "--update", GSTAPP, DRIVER, "--set-commit", "cacb78a")
        self.check(result.returncode == 1,
                   "상위 저장소가 다른 대상에 같은 커밋을 박으려 하면 거부")

        orphan = null_source_path()
        if orphan is None:
            print("  SKIP source 가 null 인 항목이 없어 검사를 건너뛴다")
        else:
            result = run(manifest, "--update", orphan, "--set-commit", "abc1234")
            self.check(result.returncode == 1,
                       "출처 미기록 항목에 --set-commit 하면 거부")

        self.check(manifest.read_text(encoding="utf-8")
                   == MANIFEST.read_text(encoding="utf-8"),
                   "거부된 실행은 매니페스트를 건드리지 않는다")

    # --- 갱신이 실제로 값을 되돌리는가 ---------------------------------------

    def update_tests(self, work: Path) -> None:
        manifest = work / "update.json"
        shutil.copy(MANIFEST, manifest)
        pristine = manifest.read_text(encoding="utf-8")
        commit = entry_of(manifest, GSTAPP)["source"]["commit"]

        # 갱신할 게 없으면 파일을 쓰지 않는다 — 불필요한 diff 와 mtime 변동을 막는다.
        os.utime(manifest, (0, 0))
        result = run(manifest, "--update", GSTAPP)
        self.check(result.returncode == 0 and manifest.stat().st_mtime == 0,
                   "이미 일치하면 매니페스트를 쓰지 않는다")

        corrupt(manifest, GSTAPP,
                sha256="0" * 64, size=1, arch="x86_64", commit="0000000")
        result = run(manifest, "--update", GSTAPP, "--set-commit", commit)
        self.check(result.returncode == 0,
                   "손상된 항목을 --update 로 갱신하면 정상 종료")
        self.check(manifest.read_text(encoding="utf-8") == pristine,
                   "sha256/size/arch/source.commit 이 원본과 바이트 단위로 일치")

        corrupt(manifest, GSTAPP, sha256="0" * 64)
        self.check(run(manifest, "--strict").returncode == 1,
                   "불일치가 남아 있으면 --strict 는 1")
        run(manifest, "--update", GSTAPP)
        self.check(run(manifest, "--strict").returncode == 0,
                   "갱신 후에는 --strict 도 0")

    # --- 지정하지 않은 것은 건드리지 않는다 -----------------------------------

    def scope_tests(self, work: Path) -> None:
        manifest = work / "scope.json"
        shutil.copy(MANIFEST, manifest)

        corrupt(manifest, GSTAPP, sha256="0" * 64)
        corrupt(manifest, DRIVER, size=999)
        result = run(manifest, "--update", GSTAPP)
        self.check(entry_of(manifest, GSTAPP)["sha256"] != "0" * 64,
                   "지정한 항목은 갱신된다")
        self.check(entry_of(manifest, DRIVER)["size"] == 999,
                   "지정하지 않은 항목은 손상된 채로 남는다 — 일괄 승인하지 않는다")

        # 남이 낸 drift 가 내 실행 결과에 섞이면 둘을 구분할 수 없고, 그러면
        # 경고 전체를 무시하게 된다. 갱신 실행은 자기 항목만 보고한다.
        report = result.stdout + result.stderr
        self.check(DRIVER not in report,
                   "갱신 실행은 무관한 항목을 보고하지 않는다")
        self.check(GSTAPP in report, "갱신 실행은 자기 항목을 보고한다")

        # 전체 점검은 인자 없이. 그때는 손상된 항목이 보여야 한다.
        sweep = run(manifest)
        self.check(DRIVER in sweep.stdout + sweep.stderr,
                   "인자 없는 전체 점검은 모든 항목을 본다")

        # required_strings 는 실측이 아니라 사람이 정하는 계약이다. 자동으로 맞춰버리면
        # 기능이 빠진 빌드를 잡아내는 검사가 스스로 무력해진다.
        # sha256 도 함께 어긋나게 둔다. 그래야 갱신이 실제로 파일을 쓰고,
        # 그 쓰기에 required_strings 가 딸려 나가지 않는지 볼 수 있다.
        shutil.copy(MANIFEST, manifest)
        corrupt(manifest, GSTAPP,
                sha256="0" * 64, required_strings=["없을리없는문자열은아님"])
        run(manifest, "--update", GSTAPP)
        self.check(entry_of(manifest, GSTAPP)["sha256"] != "0" * 64,
                   "required_strings 검사가 실제로 파일이 쓰인 상황을 본다")
        self.check(entry_of(manifest, GSTAPP)["required_strings"]
                   == ["없을리없는문자열은아님"],
                   "required_strings 는 --update 가 건드리지 않는다")


    # --- arch 를 선언했는데 ELF 가 아니면 승인하지 않는다 -------------------

    def elf_tests(self, work: Path) -> None:
        tree = work / "not-elf"
        tree.mkdir()
        script, target = minimal_tree(tree, "#!/bin/sh\necho not a binary\n")

        result = subprocess.run(
            [sys.executable, str(script), "--update", target],
            cwd=str(tree), capture_output=True, text=True)
        self.check(result.returncode == 1,
                   "arch 선언 항목이 ELF 가 아니면 --update 를 거부한다")
        manifest = tree / ".github/binary-manifest.json"
        self.check(entry_of(manifest, target)["sha256"] == "0" * 64,
                   "거부된 갱신은 매니페스트를 건드리지 않는다")

        sweep = subprocess.run(
            [sys.executable, str(script), "--strict"],
            cwd=str(tree), capture_output=True, text=True)
        self.check(sweep.returncode == 1,
                   "전체 점검에서도 ELF 아닌 파일은 --strict 를 실패시킨다")
        self.check("ELF" in sweep.stdout + sweep.stderr,
                   "그 사유가 출력에 드러난다")

        # ELF 인 경우까지 막으면 정상 갱신이 불가능해진다.
        ok_tree = work / "real-elf"
        ok_tree.mkdir()
        ok_script, ok_target = minimal_tree(
            ok_tree, "", arch="aarch64")
        shutil.copy(ROOT / GSTAPP, ok_tree / ok_target)
        subprocess.run(["git", "add", "-A"], cwd=str(ok_tree),
                       capture_output=True, check=False)
        ok = subprocess.run(
            [sys.executable, str(ok_script), "--update", ok_target],
            cwd=str(ok_tree), capture_output=True, text=True)
        self.check(ok.returncode == 0,
                   "실제 ELF 는 그대로 갱신된다")


if __name__ == "__main__":
    raise SystemExit(Tests().run())
