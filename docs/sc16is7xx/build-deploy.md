# sc16is7xx_ext.ko Build → pim-package-jhw Deploy 가이드

이 문서는 개인 GitHub workflow용 `pim-package-jhw`에 포함된
`sc16is7xx_ext.ko`의 정확한 소스 기준을 기록하고, 이후 빌드·패키지 작업에서
정식 릴리스용 source repo `master`와 개인 workflow용 fix 브랜치를 혼동하지
않도록 하는 운영 기준이다.

이 저장소에서 정식 GitLab 패키지로 동기화할 때 `sc16is7xx_ext.ko`는 제외한다.
따라서 이 바이너리의 변경은 정식 릴리스로 자동 전파되지 않는다.

`sc16is7xx_ext.ko`는 별도 Git 저장소에서 빌드되는 SC16IS752 SPI UART
out-of-tree kernel module이다. 자동 deploy 도구가 없어 빌드 산출물을 수동으로
복사하며, 패키지에서는 Git LFS로 관리한다.

> **중요:** `.ko` 파일명과 vermagic이 같아도 소스 버전은 다를 수 있다.
> 빌드·복사 전에 패키지에 기록된 source commit과
> `fix/sc16is7xx-critical-regressions`의 `sc16is7xx.c` blob을 반드시 비교한다.

## 관리 대상

| 역할 | 경로 |
|---|---|
| Source repo | `~/ai/opencode/projects/sc16is7xx/` |
| Build entry | `make-for-imx8` |
| Build artifact | `~/ai/opencode/projects/sc16is7xx/sc16is7xx_ext.ko` |
| Package target | `dist/pim/opt/pim/driver/sc16is7xx_ext.ko` |
| Binary storage | Git LFS (`*.ko`) |

## 현재 패키지 바이너리 provenance

검증일: **2026-08-25**

| 항목 | 값 |
|---|---|
| 패키지 반영 커밋 | `158fff47257d0ce875f24f03f13ac2c49c78027d` |
| 패키지에 기록된 기존 source commit | `1788388e038760c899e78009e6a4b1b0e3bdfc8c` |
| 기존 source의 마지막 드라이버 변경 | `85a3de446edc1b3d4f67ea97364e41e0e727713e` |
| 기존 source 보존 tag | `package/pim-package-jhw-158fff4-source` |
| `sc16is7xx.c` Git blob | `070bb868090420f23bebce8bfc1cd17173d20276` |
| 파일 크기 | `550888` bytes |
| LFS SHA-256 OID | `1b38dd57647123b62674757e89483182555605c246dc7c321ccd7e932b5b6fe2` |
| ELF Build ID | `9cb171f3153cc8b5b8fec8151f1e6a73fafd1a2b` |
| vermagic | `5.10.35-lts-5.10.y+g2fce14defc04 SMP preempt mod_unload modversions aarch64` |

`1788388`은 critical regression 수정 PR #3의 merge commit이다. 해당 트리의
`sc16is7xx.c`는 PR의 마지막 소스 커밋 `85a3de4`와 동일하다.

패키지 커밋 `158fff4`는 source commit `1788388`을 커밋 메시지에 명시하며,
패키지 반영 당시 Git LFS pointer의 OID와 빌드 산출물 SHA-256도 일치했다.
`1788388`은 clean-history 재작성 후에도 위 annotated tag로 보존된다.

## sc16is7xx 소스 브랜치와의 관계

source repo `master`는 정식 GitLab 릴리스의 `9f71cb9` 소스 내용을 유지한다.
이 패키지의 기록된 source commit은 `1788388`이며 최신 수정 소스는
`fix/sc16is7xx-critical-regressions`에서 유지한다.

| 항목 | 값 |
|---|---|
| `master:sc16is7xx.c` 기대 blob | `62675b6ee0811dbf6e7bcad0ef95fc534a08a6ae` |
| 기록된 source commit | `1788388e038760c899e78009e6a4b1b0e3bdfc8c` |
| clean-history 마지막 드라이버 커밋 | `ec75a5e2f6f61bf3483347495b00caa8a0f7361d` |
| fix 브랜치 `sc16is7xx.c` 기대 blob | `070bb868090420f23bebce8bfc1cd17173d20276` |

기존 패키지 바이너리를 재현하려면
`package/pim-package-jhw-158fff4-source` tag를 checkout한다. 현재 fix 브랜치는
동일한 최종 source blob을 FIFO, 진단·serial 설정, TX/IER, modem IRQ 기능별
커밋으로 재구성했다. source blob이 달라졌다면 새 빌드는 개인 workflow
드라이버의 명시적 버전 업데이트로 처리한다. `master`에서 빌드한 바이너리는
이 패키지 기준이 아니다.

## 실제 clean build 대조

검증일: **2026-08-25**

source repo의 실제 경로에서 `master`와 fix를 각각 clean build해 현재 패키지
바이너리와 비교했다.

| 항목 | 현재 패키지 바이너리 | fresh `master` | fresh fix |
|---|---|---|---|
| source ref | tag → `1788388` | `1db36fc` | `ec75a5e` |
| source blob | `070bb868...` | `62675b6e...` | `070bb868...` |
| 파일 크기 | `550888` | `533232` | `550976` |
| SHA-256 | `1b38dd57...` | `709c62f9...` | `82f6c65b...` |
| Build ID | `9cb171f3...` | `00383b7f...` | `6ed76ac4...` |
| module parameters | 3개 | 없음 | 동일한 3개 |
| byte-for-byte 동일 | 기준 파일 | 아니오 | 아니오 |

판정:

- `master`는 source blob과 module parameters가 다르므로 이 패키지와 맞지 않는다.
- fix는 패키지와 source blob, vermagic, 전체 `modinfo` 항목(파일명 제외)이
  일치하므로 **소스/ABI 기준이 맞다**.
- fresh fix의 SHA-256과 Build ID는 기존 패키지와 다르므로 **기존 바이너리를
  byte-for-byte 재현했다고 판정하지 않는다**.
- 기존 바이너리 자체가 필요하면 패키지의 Git LFS 객체를 사용한다. 재빌드
  산출물을 반영하려면 새 SHA-256과 Build ID를 새 패키지 버전으로 기록한다.

## 작업 전 버전 판정 게이트

빌드 전에 아래 값을 모두 확인한다.

```bash
cd ~/ai/opencode/projects/sc16is7xx
git status --short
git branch --show-current
git rev-parse HEAD
git rev-parse HEAD:sc16is7xx.c

cd ../pim-package-jhw
git log -1 --format=fuller -- dist/pim/opt/pim/driver/sc16is7xx_ext.ko
git show HEAD:dist/pim/opt/pim/driver/sc16is7xx_ext.ko
```

판정 기준:

- `1788388`과 `sc16is7xx.c` blob이 문서 값과 같으면 기존 소스 내용 재빌드다.
- fix 브랜치 HEAD만 다르고 `sc16is7xx.c` blob이 같으면 문서·CI 변경일 수 있다.
- `sc16is7xx.c` blob이 다르면 명시적인 드라이버 업그레이드로 처리한다.
- source repo `master`는 정식 릴리스 기준이므로 이 패키지 빌드에 사용하지 않는다.
- source repo가 dirty하면 미커밋 변경을 포함한 빌드이므로 패키지에 반영하지 않는다.

## 빌드 및 반영 절차

```bash
# 1. source revision 기록 및 빌드
cd ~/ai/opencode/projects/sc16is7xx
git status --short
git branch --show-current
git rev-parse HEAD
git rev-parse HEAD:sc16is7xx.c
./make-for-imx8 clean
./make-for-imx8

# 2. 산출물 메타데이터 확인
sha256sum sc16is7xx_ext.ko
modinfo sc16is7xx_ext.ko
readelf -n sc16is7xx_ext.ko

# 3. pim-package-jhw로 수동 복사
cp sc16is7xx_ext.ko ../pim-package-jhw/dist/pim/opt/pim/driver/

# 4. Git LFS pointer와 작업 트리 확인
cd ../pim-package-jhw
git lfs status
git lfs pointer --file dist/pim/opt/pim/driver/sc16is7xx_ext.ko
git diff --stat -- dist/pim/opt/pim/driver/sc16is7xx_ext.ko
```

패키지 커밋에는 최소한 다음 정보를 남긴다.

```text
sc16is7xx source commit: <full SHA>
sc16is7xx.c blob: <blob SHA>
sc16is7xx_ext.ko sha256: <SHA-256>
vermagic: <vermagic>
board verification: <결과>
```

커밋 예시:

```bash
git add dist/pim/opt/pim/driver/sc16is7xx_ext.ko
git commit -m "chore(pim): sc16is7xx_ext.ko 업데이트 (<source-commit>)"
```

## 보드 적용 흐름

```text
1. source revision과 source blob 기록
2. make-for-imx8 빌드
3. 산출물의 SHA-256, Build ID, vermagic 확인
4. dist/pim/opt/pim/driver/로 복사하고 Git LFS 반영 확인
5. pim 패키지 빌드로 release/ 트리 생성
6. 보드에 배포
7. reboot 후 module load와 UART 송수신 검증
```

`sc16is7xx_ext`는 시스템 부팅 초기에 로드되는 SPI UART 드라이버이므로 갱신
후에는 일반적으로 reboot 검증을 권장한다.

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| 복사 직후 source artifact와 package SHA-256이 다름 | 수동 복사 누락 또는 다른 파일 | source revision 확인 후 다시 복사 |
| 같은 source blob의 fresh build가 기존 package SHA와 다름 | 빌드 환경·경로·kernel output 차이 | `modinfo`와 source blob 확인 후 새 바이너리 반영 여부를 별도 결정 |
| source HEAD가 문서 값과 다름 | source repo 후속 커밋 | `HEAD:sc16is7xx.c` blob 비교 후 재현/업그레이드 판정 |
| source repo가 dirty함 | 미커밋 소스를 포함할 위험 | 변경을 커밋하거나 제거한 뒤 빌드 |
| `Magic value mismatch` 또는 load 실패 | 타깃 커널과 vermagic 불일치 | `make-for-imx8` 환경과 보드 `uname -r` 확인 |
| Git diff가 작은 text pointer로 보임 | `.ko`가 Git LFS 관리 대상 | `git lfs status`와 pointer OID 확인 |
| SHA-256이 바뀌었는데 source 기록이 없음 | provenance 누락 | 반영 중단 후 source commit/blob부터 복구 |

## 관련 문서

- `docs/gstApp/build-deploy.md`
- `docs/max9296/build-deploy.md`
- `~/ai/opencode/projects/sc16is7xx/README.md`
- `~/ai/opencode/projects/sc16is7xx/docs/sc16is7xx-ext-ko-provenance.md`
