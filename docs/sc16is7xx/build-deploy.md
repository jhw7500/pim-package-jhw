# sc16is7xx_ext.ko 개인 패키지 기준

## 결론

`pim-package-jhw`의 `sc16is7xx_ext.ko`는 개인 GitHub `sc16is7xx`의 수정
드라이버를 사용하는 바이너리다. 회사 `pim-package`의 역사적 바이너리와는
의도적으로 다르며, GitHub → GitLab 일반 동기화로 전파하지 않는다.

패키지 저장소의 `master` HEAD는 계속 변경되므로 HEAD 커밋은 기준값으로
고정하지 않는다. 바이너리가 반영된 패키지 커밋과 드라이버 source commit/blob을
기록한다.

## 현재 개인 패키지 바이너리

확인일은 **2026-08-26**이다.

| 항목 | 값 |
|---|---|
| 패키지 경로 | `dist/pim/opt/pim/driver/sc16is7xx_ext.ko` |
| 패키지 반영 커밋 | `158fff47257d0ce875f24f03f13ac2c49c78027d` |
| 반영 날짜 | `2026-07-24 16:57:04 +09:00` |
| 기록된 source commit | `1788388e038760c899e78009e6a4b1b0e3bdfc8c` |
| 마지막 드라이버 변경 | `85a3de446edc1b3d4f67ea97364e41e0e727713e` |
| `sc16is7xx.c` Git blob | `070bb868090420f23bebce8bfc1cd17173d20276` |
| 파일 크기 | `550888` bytes |
| LFS SHA-256 OID | `1b38dd57647123b62674757e89483182555605c246dc7c321ccd7e932b5b6fe2` |
| ELF Build ID | `9cb171f3153cc8b5b8fec8151f1e6a73fafd1a2b` |
| vermagic | `5.10.35-lts-5.10.y+g2fce14defc04 SMP preempt mod_unload modversions aarch64` |
| module parameters | `diag`, `diag_period_ms`, `rx_trigger` |

`1788388`은 수정 PR의 merge commit이고 `sc16is7xx.c`는 마지막 소스 커밋
`85a3de4`와 같은 blob이다. 현재 개인 source repo의 `master`도 같은 source
blob을 유지한다.

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
cd ~/ai/opencode/projects/sc16is7xx
git status --short
git rev-parse HEAD
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
