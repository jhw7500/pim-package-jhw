# gstApp Build → pim-package-jhw Deploy 가이드

`gstApp`은 **별도 git repo**에서 빌드되어 pim-package-jhw의 deploy 트리로 복사되는 외부 binary입니다.
`ord` / `vcm` / `vsd`는 pim-package-jhw 내부의 `build.sh`로 빌드되지만, `gstApp`는 외부 빌드 + 수동 deploy 흐름을 사용합니다.

## 토폴로지

| 역할 | 경로 |
|---|---|
| Source repo (별도 git) | `~/ai/opencode/projects/gstApp/` |
| Build artifact | `~/ai/opencode/projects/gstApp/bin/gstApp` |
| Deploy 도구 | `~/ai/opencode/projects/gstApp/update_bin.sh` |
| Deploy target (pim tracked) | `dist/pim/usr/local/bin/gstApp` |

## 빌드 + 배포 워크플로우

```bash
# 1. gstApp 빌드 (Yocto SDK 크로스 컴파일)
cd ~/ai/opencode/projects/gstApp
./make-for-imx8 -j4      # bin/gstApp 생성

# 2. 복사 + 매니페스트 갱신
./update_bin.sh          # sha256/size/mode 를 실측 기입하고 그 항목만 검증

# 3. commit — binary 와 매니페스트를 한 커밋에 넣는다
cd ../pim-package-jhw
git add dist/pim/usr/local/bin/gstApp .github/binary-manifest.json
git commit -m "chore(pim): gstApp binary 업데이트 (<gstapp-commit-hash>)"
```

맨 `make` 는 호스트 g++ 로 x86 바이너리를 만든다. `./make-for-imx8` 이 Yocto SDK
환경을 잡아준다 — 매니페스트의 `arch` 검사가 이 실수를 잡으라고 있는 것이다.

2단계가 `sha256`·`size`·`mode`·`arch` 를 실측해서 매니페스트에 써넣는다. 손으로
옮겨적지 않는다. 바이너리와 매니페스트를 나눠 커밋하면 그 사이 커밋에서 둘이
어긋난 상태가 남으므로 한 커밋에 담는다.

`update_bin.sh` 는 **자기 바이너리만** 갱신하고 보고한다. 저장소 전체 점검은
pim-package 안에서 따로 돌린다:

```bash
cd ~/ai/opencode/projects/pim-package-jhw
python3 tools/verify_binaries.py      # 등록된 바이너리 전부 + 미등록 스캔
```

### `update_bin.sh` 옵션

```bash
./update_bin.sh                          # 복사 + 매니페스트 갱신 (기본)
./update_bin.sh --no-manifest            # 복사만 (예전 동작)
./update_bin.sh --pim-dir <경로>         # 대상 트리 지정
PIM_PACKAGE_DIR=<경로> ./update_bin.sh   # 같은 것을 환경변수로
```

대상 트리 기본값은 이 저장소와 나란히 있는 `pim-package-jhw` 이고, CWD 가 아니라
스크립트 위치를 기준으로 잡는다. 어느 디렉터리에서 실행해도 같은 곳을 가리킨다.

`source.commit` 은 **바이너리 내용이 실제로 바뀐 경우에만** 갱신한다. 재빌드 없이
돌리기만 하면 손대지 않는다 — 의미 없는 diff 가 쌓이지 않게.

## 업데이트 시 sync 검증 (drift 확인)

`gstApp` 코드 변경 또는 새 빌드 후, 두 트리가 일관 상태인지 다음 3축으로 확인:

### 1. binary sha256 일치

```bash
sha256sum ~/ai/opencode/projects/gstApp/bin/gstApp \
          ~/ai/opencode/projects/pim-package-jhw/dist/pim/usr/local/bin/gstApp
```
두 해시가 같으면 sync OK. 다르면 `update_bin.sh` 재실행 필요.

### 2. commit 내역 일치

```bash
# gstApp 측 최신 commit
cd ~/ai/opencode/projects/gstApp && git log -1 --oneline

# pim 측 gstApp binary 마지막 commit
cd ~/ai/opencode/projects/pim-package-jhw && git log -1 --oneline -- dist/pim/usr/local/bin/gstApp
```
pim 측 commit 메시지에 gstApp commit hash 또는 변경 요약이 포함되어야 추적 가능.

### 3. build mtime 신선성

```bash
stat -c '%y' ~/ai/opencode/projects/gstApp/bin/gstApp
```
mtime이 gstApp 측 last commit 시각보다 오래되면 rebuild 누락 — `./make-for-imx8 -j4` 다시 실행.

## `.gitignore` 주의

| 파일 | tracked? | 이유 |
|---|---|---|
| `dist/pim/usr/local/bin/ord` | ❌ ignored | pim 내부에서 `build.sh ord`로 빌드 |
| `dist/pim/usr/local/bin/vcm` | ❌ ignored | pim 내부에서 `build.sh vcm`로 빌드 |
| `dist/pim/usr/local/bin/vsd` | ❌ ignored | pim 내부에서 `build.sh vsd`로 빌드 |
| `dist/pim/usr/local/bin/gstApp` | **✅ tracked** | 외부 repo build이므로 binary로 commit해야 다른 환경에서 일관 deploy 가능 |

gstApp 변경 시 binary commit이 함께 들어가야 새 clone / 다른 환경 / `build.sh` 후 release 단계에서 일관 동작합니다.

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| pim 측 sha256이 `gstApp/bin/gstApp`과 다름 | `update_bin.sh` 누락 | `cd gstApp && ./update_bin.sh` |
| `gstApp/bin/gstApp`이 없음 | 빌드 누락 또는 build fail | `cd gstApp && ./make-for-imx8 -j4` |
| `Binary Verify` 가 sha256/size 불일치 경고 | 매니페스트 갱신 누락 | `cd gstApp && ./update_bin.sh` |
| 같은 검사가 `arch` 불일치 경고 | SDK 없이 맨 `make` 로 빌드해 x86 바이너리가 실림 | `./make-for-imx8 -j4` 로 재빌드 후 `update_bin.sh` |
| sha256은 같은데 pim commit에 hash 없음 | binary는 cp했지만 git commit 누락 | `git add dist/.../gstApp && git commit -m "..."` |
| 보드 운영 시 fix 미반영 | 보드 deploy 단계 누락 | `./build.sh` 후 `release/` 트리를 보드에 복사 |

## 양측 동시 변경 시 (예: gstApp + vcm)

`gstApp/muxSinkBin.cpp`와 `pim-package-jhw/vcm/tcpServer.cpp`처럼 두 repo에 짝되는 변경이 있을 때:

1. gstApp 측 commit (`fix(muxsink): ...`)
2. `gstApp && ./make-for-imx8 -j4 && ./update_bin.sh`
3. pim-package-jhw 측 `./build.sh vcm` (vcm rebuild)
4. pim-package-jhw 측 commit:
   - `vcm/tcpServer.cpp` (source)
   - `dist/pim/usr/local/bin/gstApp` (gstApp binary)
   - commit 메시지에 gstApp commit hash 명시

## 관련 문서

- `docs/gstApp/RELEASE_NOTES_v1.4.md` — gstApp 자체 릴리스 노트
- `docs/gstApp/CAPTURE_OPTIMIZATIONS.md` — gstApp 내부 최적화
- `docs/gstApp/RECORDING_SYNC_PLAN.md` — 녹화 동기화 정책
- (이 문서) — pim-package-jhw 측 deploy 흐름
