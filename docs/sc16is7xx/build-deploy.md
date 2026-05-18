# sc16is7xx_ext.ko Build → pim-package-jhw Deploy 가이드

`sc16is7xx_ext.ko`는 **별도 git repo**에서 빌드되는 SC16IS752 SPI UART kernel module (out-of-tree).
`gstApp` / `max9296`와 동일한 외부 빌드 + deploy 패턴이지만, **`update_bin.sh` 도구가 없어 수동 cp로 운영**합니다.

## 토폴로지

| 역할 | 경로 |
|---|---|
| Source repo (별도 git) | `~/ai/opencode/projects/sc16is7xx/` |
| Build entry | `Makefile` 또는 `make-for-imx8` (cross-compile) |
| Build artifact | `~/ai/opencode/projects/sc16is7xx/sc16is7xx_ext.ko` |
| Deploy 도구 | **없음** (수동 cp) |
| Deploy target (pim tracked) | `dist/pim/opt/pim/driver/sc16is7xx_ext.ko` |

## 빌드 + 배포 워크플로우

```bash
# 1. sc16is7xx 빌드
cd ~/ai/opencode/projects/sc16is7xx
./make-for-imx8          # 또는 make (cross-compile toolchain 필요)

# 2. pim-package-jhw로 수동 복사 (update_bin.sh 없음)
cp sc16is7xx_ext.ko ../pim-package-jhw/dist/pim/opt/pim/driver/

# 3. pim-package-jhw 측 commit (binary tracked)
cd ../pim-package-jhw
git add dist/pim/opt/pim/driver/sc16is7xx_ext.ko
git commit -m "chore(pim): sc16is7xx_ext.ko 업데이트 (<sc16is7xx-commit-hash>)"
```

> **개선 후보**: `update_bin.sh` 추가 (gstApp/max9296와 동일 패턴) — `cp sc16is7xx_ext.ko ../pim-package-jhw/dist/pim/opt/pim/driver/` 한 줄. 운영 일관성 ↑.

## 업데이트 시 sync 검증 (drift 확인)

### 1. binary sha256 일치

```bash
sha256sum ~/ai/opencode/projects/sc16is7xx/sc16is7xx_ext.ko \
          ~/ai/opencode/projects/pim-package-jhw/dist/pim/opt/pim/driver/sc16is7xx_ext.ko
```
두 해시가 같으면 sync OK. 다르면 수동 cp 필요.

### 2. commit 내역 일치

```bash
cd ~/ai/opencode/projects/sc16is7xx && git log -1 --oneline
cd ~/ai/opencode/projects/pim-package-jhw && git log -1 --oneline -- dist/pim/opt/pim/driver/sc16is7xx_ext.ko
```

### 3. build mtime 신선성

```bash
stat -c '%y' ~/ai/opencode/projects/sc16is7xx/sc16is7xx_ext.ko
```

## `.gitignore`

`sc16is7xx_ext.ko`는 **tracked** (.gitignore 명시 없음). 외부 repo build이므로 binary로 commit해야 다른 환경에서 일관 deploy 가능.

## 보드 적용 흐름

```
sc16is7xx 변경 후:
1. sc16is7xx 빌드 (make-for-imx8)
2. cp sc16is7xx_ext.ko → pim/dist/pim/opt/pim/driver/
3. pim ./build.sh (release/ 트리 갱신)
4. release/ 트리를 보드에 deploy
5. 보드에서 rmmod + modprobe (또는 reboot)
   - sc16is7xx는 SPI UART driver → 시스템 부팅 초기 load됨
   - 갱신 후엔 일반적으로 reboot 권장
```

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| pim 측 sha256이 sc16is7xx/sc16is7xx_ext.ko와 다름 | 수동 cp 누락 | `cp sc16is7xx_ext.ko ../pim-package-jhw/dist/pim/opt/pim/driver/` |
| `sc16is7xx_ext.ko`가 없음 | `make` 또는 `make-for-imx8` 누락 | cross-compile toolchain 확인 후 재빌드 |
| `Magic value mismatch` / module load 실패 | 커널 버전 mismatch (target=5.10) | `make-for-imx8`로 imx8 커널 toolchain 사용 (commit fad5bb9 참고) |
| sha256 다른데 commit 흔적 없음 | binary cp 후 git commit 누락 | `git add dist/.../sc16is7xx_ext.ko && git commit` |

## 관련 문서

- `docs/sc16is7xx/` (별도 운영 문서가 있다면 여기 추가)
- `docs/gstApp/build-deploy.md` — gstApp 측 동일 패턴
- `docs/max9296/build-deploy.md` — max9296 측 동일 패턴 (kernel module)
- `sc16is7xx/README.md` — sc16is7xx repo 자체 README (빌드 방법, baud rate 등)
