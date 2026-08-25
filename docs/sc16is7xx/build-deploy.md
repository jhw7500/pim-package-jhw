# sc16is7xx_ext.ko Build → pim-package-jhw Deploy 가이드

이 문서는 개인 GitHub workflow용 `pim-package-jhw`에 포함된
`sc16is7xx_ext.ko`의 정확한 소스 기준을 기록하고, 이후 빌드·패키지 작업에서
정식 GitLab 패키지의 역사적 소스와 현재 source repo의 수정 소스를 혼동하지
않도록 하는 운영 기준이다.

이 저장소에서 정식 GitLab 패키지로 동기화할 때 `sc16is7xx_ext.ko`는 제외한다.
따라서 이 바이너리의 변경은 정식 릴리스로 자동 전파되지 않는다.
`.github/binary-manifest.json`도 저장소별 바이너리 증명서이므로 동기화에서
제외한다. GitHub manifest는 아래 개인 workflow 바이너리를, GitLab manifest는
정식 GitLab 패키지 바이너리를 각각 기록해야 한다.

`sc16is7xx_ext.ko`는 별도 Git 저장소에서 빌드되는 SC16IS752 SPI UART
out-of-tree kernel module이다. 자동 deploy 도구가 없어 빌드 산출물을 수동으로
복사하며, 패키지에서는 Git LFS로 관리한다.

> **중요:** `.ko` 파일명과 vermagic이 같아도 소스 버전은 다를 수 있다.
> 빌드·복사 전에 패키지에 기록된 source commit과
> 반영하려는 source ref의 `sc16is7xx.c` blob을 반드시 비교한다.

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
| `sc16is7xx.c` Git blob | `070bb868090420f23bebce8bfc1cd17173d20276` |
| 파일 크기 | `550888` bytes |
| LFS SHA-256 OID | `1b38dd57647123b62674757e89483182555605c246dc7c321ccd7e932b5b6fe2` |
| ELF Build ID | `9cb171f3153cc8b5b8fec8151f1e6a73fafd1a2b` |
| vermagic | `5.10.35-lts-5.10.y+g2fce14defc04 SMP preempt mod_unload modversions aarch64` |

`1788388`은 critical regression 수정 PR #3의 merge commit이다. 해당 트리의
`sc16is7xx.c`는 PR의 마지막 소스 커밋 `85a3de4`와 동일하다.

패키지 커밋 `158fff4`는 source commit `1788388`을 커밋 메시지에 명시하며,
패키지 반영 당시 Git LFS pointer의 OID와 빌드 산출물 SHA-256도 일치했다.
`1788388`은 검증 당시 source repo `master`의 조상으로 정상 개발 이력에
남아 있으므로 별도 보존 tag를 사용하지 않는다.

## sc16is7xx 소스 브랜치와의 관계

source repo 브랜치는 정상 개발 이력을 유지하며, 정식 GitLab 패키지의 과거
바이너리에 맞추기 위해 되돌리지 않는다. 이 패키지의 기록된 source commit은
`1788388`이고, 검증 당시 `master`와 원래 fix 브랜치도 같은 드라이버 source
blob을 가진다.

| 항목 | 값 |
|---|---|
| 검증 당시 `master` | `fb086e00d8d755c2d1cc331f2b16fb49cf845825` |
| `master:sc16is7xx.c` blob | `070bb868090420f23bebce8bfc1cd17173d20276` |
| 기록된 source commit | `1788388e038760c899e78009e6a4b1b0e3bdfc8c` |
| 원래 fix 브랜치 tip | `85a3de446edc1b3d4f67ea97364e41e0e727713e` |
| 정식 GitLab 패키지 역사적 소스 | `9f71cb97ff1c0fe2401a0d1b8b6ababbecac2e19` |
| 정식 GitLab 패키지 source blob | `62675b6ee0811dbf6e7bcad0ef95fc534a08a6ae` |

기존 패키지 바이너리의 소스 내용을 재현하려면 브랜치를 변경하지 않고
`1788388` 또는 `85a3de4`를 별도 detached worktree에서 checkout한다. 현재
`master`도 같은 source blob이므로 소스/ABI 계보는 일치하지만, 빌드 환경이
다르면 기존 ELF의 SHA-256과 Build ID는 달라질 수 있다. source blob이
달라졌다면 새 빌드는 개인 workflow 드라이버의 명시적 버전 업데이트로 처리한다.

## 실제 clean build 대조

검증일: **2026-08-25**

현재 패키지, 정식 GitLab 패키지의 역사적 소스, 복원된 source repo 이력을
source blob과 module parameters 기준으로 비교했다.

| 항목 | 현재 패키지 바이너리 | 정식 GitLab 패키지 기준 | 현재 source repo 기준 |
|---|---|---|---|
| source ref | `1788388` | `9f71cb9` | `master` (`fb086e0`) |
| source blob | `070bb868...` | `62675b6e...` | `070bb868...` |
| module parameters | 3개 | 없음 | 동일한 3개 |
| source/ABI 계보 | 기준 파일 | 다름 | 일치 |
| 기존 ELF SHA 재현 | 기준 파일 | 대상 아님 | 빌드 환경까지 같아야 판정 가능 |

판정:

- 정식 GitLab 패키지의 역사적 소스는 source blob과 module parameters가
  다르므로 이 패키지와 맞지 않는다.
- `1788388`, `85a3de4` 및 검증 당시 `master`는 같은 source blob을 가지므로
  **소스/ABI 계보가 맞다**.
- 같은 source blob의 fresh build도 SHA-256과 Build ID가 달라질 수 있으므로
  **기존 바이너리를 byte-for-byte 재현했다고 자동 판정하지 않는다**.
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
- source repo `master`를 사용할 때도 source commit과 blob을 패키지 기록에 남긴다.
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
