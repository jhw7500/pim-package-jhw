# Docker Build Environment for PIM Package

이 디렉터리는 타겟 환경(Ubuntu 20.04 aarch64 + GLIBC 2.31)과 동일한 도커 환경에서 PIM 패키지를 빌드하기 위한 파일들을 포함합니다.

## 📁 파일 구조

```
docker/
├── Dockerfile          # Ubuntu 20.04 ARM64 빌드 환경 정의
├── build-image.sh      # 도커 이미지 빌드 스크립트
├── build.sh            # PIM 패키지 컴파일 스크립트
├── .dockerignore       # 도커 빌드 시 제외할 파일 목록
└── README.md           # 이 파일
```

## 🚀 사용 방법

### 1단계: 도커 이미지 빌드 (최초 1회만)

```bash
cd /home/jhw/ai/my-claude-code-setup/pim-package
./docker/build-image.sh
```

**실행 내용:**
- x86_64 호스트에서 ARM64 에뮬레이션을 위한 QEMU 설정
- Ubuntu 20.04 ARM64 도커 이미지 빌드 (`--platform linux/arm64`)
- 필요한 빌드 도구 설치:
  - build-essential (gcc, g++, make)
  - cmake
  - pkg-config
  - libjson-c-dev (v4.0.0)
  - libhiredis-dev (v0.14)
  - git

**예상 시간:** 5-10분 (인터넷 속도에 따라 다름)

### 2단계: PIM 패키지 컴파일

```bash
./docker/build.sh
```

**실행 내용:**
- ARM64 도커 컨테이너 시작
- pim-package를 컨테이너의 `/workspace`로 마운트
- 컨테이너 안에서 `./build.sh` 실행 (네이티브 빌드 모드)
- 타겟 호환 바이너리 생성 (GLIBC 2.31)

**결과물:**
- `release/pim/usr/local/bin/ord` - 타겟 실행 가능
- `release/pim/usr/local/bin/vcm` - 타겟 실행 가능
- 기타 패키지 파일들

## ✅ 장점

1. **타겟 호환성**: Ubuntu 20.04 + GLIBC 2.31 환경에서 빌드되어 타겟에서 바로 실행 가능
2. **재현성**: 항상 동일한 빌드 환경 보장
3. **호스트 독립성**: 호스트 시스템을 오염시키지 않음
4. **자동화**: 한 번 설정하면 반복 사용 가능

## 🔍 빌드 검증

`build.sh`와 `docker/build.sh`는 빌드 완료 후
`tools/verify_binaries.py`를 자동 실행한다. Docker 빌드는 release 산출물의
ARM aarch64/GLIBC 정보도 추가로 확인한다.

검사는 두 종류이고 **기본값이 서로 다르다**.

| 검사 | 대상 | 환경변수 | 기본값 |
|---|---|---|---|
| 매니페스트 대조 | git 추적 바이너리(gstApp, `.ko` 등) | `PIM_VERIFY_BINARIES` | `warn` |
| release 산출물 검증 | 존재 / ARM aarch64 / GLIBC | `PIM_VERIFY_BINARIES` | **`strict`** |
| GLIBC 게이트 | 컴파일된 모듈 8종과 pim_gate 산출물 | `PIM_GLIBC_GATE` | **`strict`** |

GLIBC 게이트가 보는 모듈 8종은 `ord`, `vsd`, `vcm`, `adab`, `adab_ecat`, `cism`,
`stm32update`, `mcp_trust_test` 이고, `pim_gate` 는 자체 빌드 산출물의 실행 파일을
검사한다. 즉 `docker/build.sh` 의 `MODULE_BIN` 과 같은 집합이다.

매니페스트 불일치는 경고로 남긴다(검증 전 중간 상태 작업이 흔하다). 반면 release
산출물 결함과 GLIBC 초과는 `.deb`에 그대로 실릴 문제라 기본으로 빌드를 세운다.

```bash
# 기본: 산출물 결함·GLIBC 초과는 빌드 실패(exit 2), 매니페스트 불일치는 경고
./docker/build.sh

# 자동 검증 전부 생략
PIM_VERIFY_BINARIES=off ./docker/build.sh

# release 산출물 검증도 경고로 낮춤
PIM_VERIFY_BINARIES=warn ./docker/build.sh

# GLIBC 게이트만 경고로 낮춤 / 끔
PIM_GLIBC_GATE=warn ./docker/build.sh
PIM_GLIBC_GATE=off  ./docker/build.sh

# 타깃 rootfs 가 바뀌어 천장을 올릴 때 (기본 2.31)
# 점으로 구분된 숫자만 받는다 — 형식이 어긋나면 통과시키지 않고 exit 2 로 멈춘다.
PIM_MAX_GLIBC=2.35 ./docker/build.sh
```

`PIM_VERIFY_BINARIES` 지원 값은 `off`, `warn`, `strict`, `PIM_GLIBC_GATE` 는
`off`, `warn`, `strict` 다. 세 변수 모두 `docker run` 으로 컨테이너에 전달되므로
호스트에서 지정한 값이 컨테이너 안 검사에도 그대로 적용된다.

매니페스트는 빌드가 자동 갱신하지
않는다. 바이너리를 의도적으로 바꾼 경우에만 검토자가 경로를 명시해 갱신한다.

```bash
python3 tools/verify_binaries.py --update dist/pim/usr/local/bin/gstApp
```

수동 확인 예시:

```bash
# 아키텍처 확인
file release/pim/usr/local/bin/ord
# 예상 출력: ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), dynamically linked...

# GLIBC 버전 확인 (GLIBC_2.33이 없어야 함)
readelf -V release/pim/usr/local/bin/ord | grep GLIBC
# GLIBC_2.17, GLIBC_2.31까지만 있어야 정상
```

## 🎯 추가 기능

### 도커 컨테이너에 직접 접속

개발이나 디버깅을 위해 컨테이너에 직접 접속:

```bash
cd "$(git rev-parse --show-toplevel)"
docker run --rm -it \
    --platform linux/arm64 \
    -v $(pwd):/workspace \
    -w /workspace \
    pim-builder-ubuntu20.04-arm64 \
    /bin/bash
```

컨테이너 안에서:
```bash
# 수동 빌드
./build.sh

# 개별 모듈 빌드
cd ord/build
cmake ..
make

# 라이브러리 확인
pkg-config --modversion json-c
# 출력: 0.15 (SDK 버전과 다름, 타겟과 호환)

dpkg -l | grep json-c
dpkg -l | grep hiredis
```

### 클린 빌드

빌드 캐시 삭제 후 재빌드:

```bash
rm -rf */build release
./docker/build.sh
```

### 도커 이미지 재빌드

Dockerfile을 수정했거나 의존성을 업데이트한 경우:

```bash
./docker/build-image.sh
```

### 도커 이미지 삭제

더 이상 사용하지 않을 경우:

```bash
docker rmi pim-builder-ubuntu20.04-arm64
```

## 🐛 문제 해결

### 1. "permission denied" 오류

실행 권한 추가:
```bash
chmod +x docker/build-image.sh docker/build.sh
```

### 2. QEMU 에뮬레이션 느림

x86_64 호스트에서 ARM64를 에뮬레이션하므로 빌드 시간이 네이티브보다 느립니다.
- 예상 시간: 15-30분 (호스트 성능에 따라)
- 더 빠른 빌드를 원한다면 타겟에서 직접 빌드하는 것을 추천

### 3. "no match for platform in manifest" 오류

이미 수정되었습니다. 만약 여전히 발생한다면:
```bash
# Docker buildx 확인
docker buildx ls

# buildx가 없으면 설치
docker buildx create --use
```

### 4. 도커 이미지 빌드 실패

인터넷 연결 또는 도커 레지스트리 문제일 수 있습니다:
```bash
# 도커 데몬 재시작
sudo systemctl restart docker

# 이미지 다시 빌드
./docker/build-image.sh
```

## 📊 비교: 3가지 빌드 방법

| 항목 | 호스트 빌드 (SDK) | 도커 빌드 (Ubuntu 20.04) | 타겟 빌드 |
|------|-------------------|--------------------------|-----------|
| 환경 | Yocto SDK (GLIBC 2.33) | Ubuntu 20.04 (GLIBC 2.31) | Ubuntu 20.04 (GLIBC 2.31) |
| 타겟 실행 | ❌ 불가능 | ✅ 가능 | ✅ 가능 |
| 빌드 속도 | 빠름 (네이티브) | 느림 (에뮬레이션) | 빠름 (네이티브) |
| 설정 난이도 | SDK 설정 필요 | 도커만 필요 | 개발 도구 설치 |
| 사용 목적 | 개발/테스트 | 배포용 바이너리 생성 | 개발/배포 |

## 📝 참고사항

- 도커 컨테이너는 `--rm` 옵션으로 실행되어 종료 후 자동 삭제됩니다
- 빌드 결과물은 호스트의 `release/` 디렉터리에 저장됩니다
- 서브모듈(ord, vcm 등)의 빌드 캐시는 각 모듈의 `build/` 디렉터리에 유지됩니다
- 클린 빌드가 필요한 경우: `rm -rf */build release` 후 다시 빌드

## 🎓 기술 세부사항

### 왜 arm64v8/ubuntu가 아니라 ubuntu를 사용하나요?

- `ubuntu:20.04`는 멀티 아키텍처 이미지 (manifest list)
- `--platform linux/arm64` 옵션으로 ARM64 버전 자동 선택
- x86_64 호스트에서도 동작 (QEMU 덕분)
- `arm64v8/ubuntu:20.04`는 ARM64 전용이라 x86_64에서 직접 pull 불가능

### GLIBC 버전이 중요한 이유

- 바이너리가 컴파일된 환경의 GLIBC 버전보다 낮은 버전에서는 실행 불가
- SDK (GLIBC 2.33) → 타겟 (GLIBC 2.31) ❌
- 도커 (GLIBC 2.31) → 타겟 (GLIBC 2.31) ✅
- 타겟 (GLIBC 2.31) → 타겟 (GLIBC 2.31) ✅

### 왜 정적 링킹을 포기했나요?

- SDK의 정적 라이브러리(`.a`)도 GLIBC 2.33 기반으로 빌드됨
- 정적 링킹해도 `stat@GLIBC_2.33` 같은 심볼 사용
- 동적 링킹 + 타겟 환경 빌드가 더 간단하고 안전함
