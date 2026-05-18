# max9296.ko Build → pim-package-jhw Deploy 가이드

`max9296.ko`는 **별도 git repo**에서 빌드되는 GMSL2 deserializer kernel module입니다.
`gstApp`와 동일하게 외부 빌드 + 수동 deploy 흐름을 사용합니다.

## 토폴로지

| 역할 | 경로 |
|---|---|
| Source repo (별도 git) | `~/ai/opencode/projects/max9296/` |
| Build artifact | `~/ai/opencode/projects/max9296/max9296.ko` |
| Deploy 도구 | `~/ai/opencode/projects/max9296/update_bin.sh` |
| Deploy target (pim tracked) | `dist/pim/opt/pim/driver/max9296.ko` |

## 빌드 + 배포 워크플로우

```bash
# 1. max9296 빌드 (out-of-tree kernel module)
cd ~/ai/opencode/projects/max9296
make                     # max9296.ko 생성 (cross-compile toolchain 필요)

# 2. pim-package-jhw로 복사
./update_bin.sh          # 단순 cp: max9296.ko → ../pim-package-jhw/dist/pim/opt/pim/driver/

# 3. pim-package-jhw 측 commit (binary tracked)
cd ../pim-package-jhw
git add dist/pim/opt/pim/driver/max9296.ko
git commit -m "chore(pim): max9296.ko 업데이트 (<max9296-commit-hash>)"
```

### `update_bin.sh` 본문 (참고)

```bash
#!/bin/bash
cp max9296.ko ../pim-package-jhw/dist/pim/opt/pim/driver/
```

## 업데이트 시 sync 검증 (drift 확인)

### 1. binary sha256 일치

```bash
sha256sum ~/ai/opencode/projects/max9296/max9296.ko \
          ~/ai/opencode/projects/pim-package-jhw/dist/pim/opt/pim/driver/max9296.ko
```
두 해시가 같으면 sync OK. 다르면 `update_bin.sh` 재실행.

### 2. commit 내역 일치

```bash
cd ~/ai/opencode/projects/max9296 && git log -1 --oneline
cd ~/ai/opencode/projects/pim-package-jhw && git log -1 --oneline -- dist/pim/opt/pim/driver/max9296.ko
```
pim 측 commit 메시지에 max9296 commit hash 또는 버전 (예: `version 2.3`)이 명시되어야 추적 가능.

### 3. build mtime 신선성

```bash
stat -c '%y' ~/ai/opencode/projects/max9296/max9296.ko
```
mtime이 max9296 last commit 시각보다 오래되면 rebuild 누락 — `make` 다시 실행.

## `.gitignore` 주의

`max9296.ko`는 **tracked** (.gitignore 명시 없음). 외부 repo build이므로 binary로 commit해야 다른 환경에서 일관 deploy 가능.

같은 driver 디렉토리에 함께 tracked되는 binary:
- `dist/pim/opt/pim/driver/max9296.ko` ← max9296 repo build
- `dist/pim/opt/pim/driver/sc16is7xx_ext.ko` ← 별도 build (소스 위치 확인 필요)
- `dist/pim/opt/pim/driver/laird_backport.tar` ← WiFi driver backport (벤더 제공)

## 보드 적용 흐름

```
gstApp + max9296 변경 후:
1. max9296 빌드 + update_bin.sh
2. gstApp 빌드 + update_bin.sh (있다면)
3. pim-package-jhw: ./build.sh (release/ 트리 갱신, dist/ → release/ sync)
4. release/ 트리를 보드에 deploy
5. 보드에서 cam-operate restart 또는 reboot
   - max9296.ko가 module로 load되면 rmmod + modprobe 필요
   - cam_enable.sh가 자동 rmmod/modprobe 처리
```

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| pim 측 sha256이 max9296/max9296.ko와 다름 | `update_bin.sh` 누락 | `cd max9296 && ./update_bin.sh` |
| `max9296.ko`가 없음 | `make` 누락 또는 cross-compile toolchain 미설정 | `cd max9296 && make` (build.log 확인) |
| sha256는 같은데 pim commit에 hash 없음 | binary cp 후 git commit 누락 | `git add dist/.../max9296.ko && git commit` |
| 보드에서 max9296 driver init 실패 | 보드 deploy 누락 또는 modprobe 실패 | `release/` 트리 보드에 복사 후 `cam_enable.sh` 또는 reboot |
| `Magic value mismatch` / module load 실패 | 커널 버전 mismatch | 보드 커널과 동일한 cross-compile toolchain으로 rebuild 필요 |

## 관련 문서

- `docs/max9296/CHANGELOG.md` — max9296 자체 변경 이력
- `docs/max9296/RELEASE_NOTES.md` — 버전별 릴리스 노트
- `docs/max9296/V4L2_CTRL_GUIDE.md` — V4L2 컨트롤 가이드
- `docs/max9296/CAMERA_HELPER_SCRIPTS.md` — 카메라 보조 스크립트
- `docs/gstApp/build-deploy.md` — gstApp 측 동일 패턴 (외부 binary deploy)
