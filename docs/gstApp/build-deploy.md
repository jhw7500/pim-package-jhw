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
# 1. gstApp 빌드
cd ~/ai/opencode/projects/gstApp
make                     # bin/gstApp 생성

# 2. pim-package-jhw로 복사
./update_bin.sh          # 단순 cp: bin/gstApp → ../pim-package-jhw/dist/pim/usr/local/bin/

# 3. pim-package-jhw 측 commit (binary tracked)
cd ../pim-package-jhw
git add dist/pim/usr/local/bin/gstApp
git commit -m "chore(pim): gstApp binary 업데이트 (<gstapp-commit-hash>)"
```

### `update_bin.sh` 본문 (참고)

```bash
#!/bin/bash
cp bin/gstApp  ../pim-package-jhw/dist/pim/usr/local/bin/
```

단순 `cp`만 수행. build artifact 갱신 후 호출 필수.

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
mtime이 gstApp 측 last commit 시각보다 오래되면 rebuild 누락 — `make` 다시 실행.

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
| `gstApp/bin/gstApp`이 없음 | `make` 누락 또는 build fail | `cd gstApp && make` (build.log 확인) |
| sha256은 같은데 pim commit에 hash 없음 | binary는 cp했지만 git commit 누락 | `git add dist/.../gstApp && git commit -m "..."` |
| 보드 운영 시 fix 미반영 | 보드 deploy 단계 누락 | `./build.sh` 후 `release/` 트리를 보드에 복사 |

## 양측 동시 변경 시 (예: gstApp + vcm)

`gstApp/muxSinkBin.cpp`와 `pim-package-jhw/vcm/tcpServer.cpp`처럼 두 repo에 짝되는 변경이 있을 때:

1. gstApp 측 commit (`fix(muxsink): ...`)
2. `gstApp && make && ./update_bin.sh`
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
