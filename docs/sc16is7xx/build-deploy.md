# sc16is7xx_ext.ko 개인 패키지 기준

## 결론

`pim-package-jhw`의 `sc16is7xx_ext.ko`는 GitLab `sc16is7xx/main`에서 clean
build한 최신 바이너리다. 회사 `pim-package`의 역사적 바이너리와는 의도적으로
다르며, GitHub → GitLab 일반 동기화로 전파하지 않는다.

패키지 저장소의 `master` HEAD는 계속 변경되므로 HEAD 커밋은 기준값으로
고정하지 않는다. 바이너리가 반영된 패키지 커밋과 드라이버 source commit/blob을
기록한다.

## 현재 개인 패키지 바이너리

확인일은 **2026-08-27**이다.

| 항목 | 값 |
|---|---|
| 패키지 경로 | `dist/pim/opt/pim/driver/sc16is7xx_ext.ko` |
| 패키지 반영 기준 | 이 문서와 바이너리를 포함한 `master` 변경 |
| 반영 날짜 | `2026-08-27` |
| source 저장소/브랜치 | GitLab `hwjo/sc16is7xx`, `main` |
| source commit | `6c09f624d940f5a939002141e65e451cb185120a` |
| source commit 날짜 | `2026-08-27 15:49:36 +09:00` |
| `sc16is7xx.c` Git blob | `070bb868090420f23bebce8bfc1cd17173d20276` |
| `make-for-imx8` Git blob | `c967f640ea36300f27bee1c8ce7a91198b0e8027` |
| 파일 크기 | `664400` bytes |
| LFS SHA-256 OID | `8305c872356787a29b11cda11baa2138dc29835c9ebddd066741c1ac31a9137a` |
| ELF Build ID | `b0a6071ba131616db0966738ebf62fe05454b8b7` |
| vermagic | `5.10.35-lts-5.10.y+g2fce14defc04 SMP preempt mod_unload modversions aarch64` |
| module parameters | `diag`, `diag_period_ms`, `rx_trigger` |

source commit에는 드라이버 안정성 수정과 Yocto SDK 빌드 수정이 병합되어 있다.
드라이버 blob은 이전 개인 패키지 기준과 같지만, 병합된 `make-for-imx8`을 사용해
다시 생성한 산출물을 현재 기준으로 사용한다.

## 회사 패키지와의 차이

회사 `pim-package`는 아래 역사적 기준을 유지한다.

| 항목 | 회사 패키지 기준 |
|---|---|
| source commit | `9f71cb97ff1c0fe2401a0d1b8b6ababbecac2e19` |
| `sc16is7xx.c` blob | `62675b6ee0811dbf6e7bcad0ef95fc534a08a6ae` |
| 바이너리 SHA-256 | `05462e99a645a5e7386c73906bef24566e4ea80ce296deb339a7d5dc868c0793` |
| module parameters | 없음 |

두 바이너리는 파일명과 vermagic이 같아도 소스와 기능이 다르다. 개인 바이너리를
회사 패키지로 복사하는 작업은 단순 동기화가 아니라 별도 보드 검증이 필요한
드라이버 업그레이드다.

## 빌드 및 개인 패키지 반영

```bash
cd ~/ai/opencode/projects/sc16is7xx-gitlab
git status --short
git rev-parse HEAD
git rev-parse origin/main
git rev-parse HEAD:sc16is7xx.c
./make-for-imx8 clean
./make-for-imx8

sha256sum sc16is7xx_ext.ko
modinfo sc16is7xx_ext.ko
readelf -n sc16is7xx_ext.ko

cp sc16is7xx_ext.ko ../pim-package-jhw/dist/pim/opt/pim/driver/
cd ../pim-package-jhw
git lfs status
git lfs pointer --file dist/pim/opt/pim/driver/sc16is7xx_ext.ko
```

source repo가 dirty하거나 source blob을 확정할 수 없으면 패키지에 반영하지
않는다. 바이너리를 변경할 때는 source commit/blob, SHA-256, Build ID,
vermagic과 보드 검증 결과를 같은 변경 단위에 기록한다.

## 동기화 정책

`sync-to-gitlab.sh`는 다음 항목을 회사 패키지로 복사하지 않는다.

- `dist/pim/opt/pim/driver/sc16is7xx_ext.ko`
- `.github/binary-manifest.json`
- 이 개인 패키지 전용 문서

각 패키지는 자신의 실제 바이너리에 맞는 manifest와 provenance를 유지한다.

## 현재 검증 상태

- `sc16is7xx/main@6c09f62` clean build: 통과
- SHA-256, ELF Build ID, vermagic, module parameters 확인: 통과
- `pim-package-jhw` 바이너리 manifest strict 검증: 통과
- Docker 패키지 생성 및 `.deb` 내부 SC16 바이너리 SHA-256 대조: 통과
- 전체 release artifact gate: 현재 HEAD에 추적되지 않는 외부 구성요소
  (`adab`, `adab_ecat`, `cism`, `stm32update`, `mcp_trust_test`, `pim_gate`)
  부재로 미완료
- 타깃 보드 적재, UART 루프백 및 load/unload 검증: 패키지 배포 후 수행

## 보드 검증

새 바이너리를 반영하면 패키지 빌드와 배포 후 재부팅하여 다음을 확인한다.

1. `uname -r`과 모듈 vermagic 일치
2. `sc16is7xx_ext` 정상 적재
3. UART 송수신
4. load/unload 및 회귀 시나리오

## 재검증 명령

```bash
TARGET=dist/pim/opt/pim/driver/sc16is7xx_ext.ko

sha256sum "$TARGET"
modinfo "$TARGET"
readelf -n "$TARGET"
git lfs pointer --file "$TARGET"
git log -1 --oneline -- "$TARGET"
```
