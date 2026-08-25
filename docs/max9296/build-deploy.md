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
./make-for-imx8          # max9296.ko 생성. SDK 환경과 KERNEL_SRC 를 잡아준다

# 2. 복사 + 매니페스트 갱신
./update_bin.sh          # sha256/size/mode 를 실측 기입하고 그 항목만 검증

# 3. commit — binary 와 매니페스트를 한 커밋에 넣는다
cd ../pim-package-jhw
git add dist/pim/opt/pim/driver/max9296.ko .github/binary-manifest.json
git commit -m "chore(pim): max9296.ko 업데이트 (<max9296-commit-hash>)"
```

맨 `make` 는 `ARCH`·`CROSS_COMPILE`·`KERNEL_SRC` 가 비어 실패하거나 엉뚱한 것을
만든다. `./make-for-imx8` 을 쓴다.

2단계가 `sha256`·`size`·`mode`·`arch` 를 실측해서 매니페스트에 써넣는다. 손으로
옮겨적지 않는다. 바이너리와 매니페스트를 나눠 커밋하면 그 사이 커밋에서 둘이
어긋난 상태가 남으므로 한 커밋에 담는다.

`update_bin.sh` 는 **자기 바이너리만** 갱신하고 보고한다. 저장소 전체 점검은
pim-package 안에서 따로 돌린다:

```bash
cd ~/ai/opencode/projects/pim-package-jhw
python3 tools/verify_binaries.py      # 등록된 바이너리 전부 + 미등록 스캔
```

이 파일은 LFS 라 포인터만 있는 체크아웃에서는 `arch` 를 잴 수 없고, 그 경우
해당 필드를 건드리지 않고 사유를 출력한다 — 실물이 있는 곳에서 돌린다.

`module_version` 과 `required_strings` 는 자동으로 바뀌지 않는다. 드라이버 버전을
올렸거나 심볼 계약을 바꿨다면 손으로 고친다.

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
- `dist/pim/opt/pim/driver/sc16is7xx_ext.ko` ← `../sc16is7xx` 별도 build; 버전 판정은 `docs/sc16is7xx/build-deploy.md` 참조
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
| `max9296.ko`가 없음 | 빌드 누락 또는 SDK 미설정 | `cd max9296 && ./make-for-imx8` |
| `Binary Verify` 가 sha256/size 불일치 경고 | 매니페스트 갱신 누락 | `cd max9296 && ./update_bin.sh` |
| 소스는 같은데 sha256 이 달라짐 | 커널 빌드 플래그 차이(예: `-mbranch-protection` 의 BTI 유무) | `modinfo` 의 `srcversion` 이 같으면 소스는 동일하다. 타깃이 Cortex-A53 이라 `bti`/`pac` 는 NOP 이므로 동작 차이는 없다 |
| sha256는 같은데 pim commit에 hash 없음 | binary cp 후 git commit 누락 | `git add dist/.../max9296.ko && git commit` |
| 보드에서 max9296 driver init 실패 | 보드 deploy 누락 또는 modprobe 실패 | `release/` 트리 보드에 복사 후 `cam_enable.sh` 또는 reboot |
| `Magic value mismatch` / module load 실패 | 커널 버전 mismatch | 보드 커널과 동일한 cross-compile toolchain으로 rebuild 필요 |

## max9296 tools/ 에서 가져온 스크립트

`.ko` 말고도 max9296 저장소의 도구를 배포에 싣는 경우가 있다. 이 절이 그 목록과
출처를 기록한다.

| 배포 경로 | 정본 | 파일 마지막 변경 | 복사 시점 master | sha256 |
| --- | --- | --- | --- | --- |
| `dist/pim/opt/pim/bin/cam_hard_reset.sh` | max9296 `tools/cam_hard_reset.sh` | `fceeddd` | `edd8fda` | `081e3fd242a3e95006e5cee14eb1dc4ed6ad01357c26c7328fb791c4370de531` |

### 드리프트 확인

배포본은 정본과 **바이트 동일하게** 유지한다. 헤더에 출처 주석을 덧붙이지 않는
이유는, 그래야 한 줄로 드리프트를 판정할 수 있기 때문이다:

```bash
# <max9296-checkout> = max9296 저장소 체크아웃 경로. 기준 커밋은 표의
# "파일 마지막 변경" 열 — master 가 움직여도 판정이 흔들리지 않는다.
git -C <max9296-checkout> show fceeddd:tools/cam_hard_reset.sh \
  | diff - dist/pim/opt/pim/bin/cam_hard_reset.sh && echo "동일"
```

정본이 갱신되면 다시 복사하고 이 표의 커밋·sha256 을 함께 고친다. `.ko` 와 달리
`binary-manifest.json` 은 이 파일을 보지 않는다 - 매니페스트의 `TRACKED_PATTERN`
이 `.ko` 와 `usr/local/bin/*` 만 잡고, arch·ELF 심볼 검사도 셸 스크립트에는
적용되지 않는다.

### cam_hard_reset.sh 범위

**테스트·검증 전용이다.** 운영 워치독(`chk_cam_operate.sh`)과 결합하지 않으며
자동 복구 경로에 들어가 있지 않다. 수동 호출과 온타겟 하네스
(gstApp `test/run-max9296-board-test.sh`, max9296 prepare 게이트)만 쓴다.

현행 리셋 계층(killcam→respawn → 모듈 리셋 → 워치독 재부팅)은 SoC 빌트인
CSI2/ISI 를 건드리지 않아, D-PHY 락 실패류(STREAMON 성공 + CSI2 이벤트 0)는
재부팅까지 가야 풀린다. 이 스크립트는 CSI2 까지 unbind/bind 한다.

> **주의**: pim-check 의 케이스 간 재부팅을 이 스크립트로 대체하는 것은 아직
> 하지 않는다. 부팅 시간이 사라지면 AE 레지스터 정착(콜드 기동 후 `gstApp+16s`)
> 전에 readback 체크가 샘플링될 수 있다. jhw7500/pim-check#61 이 선결이다.

## 관련 문서

- `docs/max9296/CHANGELOG.md` — max9296 자체 변경 이력
- `docs/max9296/RELEASE_NOTES.md` — 버전별 릴리스 노트
- `docs/max9296/V4L2_CTRL_GUIDE.md` — V4L2 컨트롤 가이드
- `docs/max9296/CAMERA_HELPER_SCRIPTS.md` — 카메라 보조 스크립트
- `docs/gstApp/build-deploy.md` — gstApp 측 동일 패턴 (외부 binary deploy)
