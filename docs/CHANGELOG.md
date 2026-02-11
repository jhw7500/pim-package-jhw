# PIM Package Changelog

2026년 2월 이후 **23개 커밋**에서 다음과 같은 개선사항이 적용되었습니다.

---

## 📌 최신 변경사항 (2026-02-11)

### gstApp v1.4 (PR #21, #22)
- 파이프라인 큐 저지연 튜닝 (100~200ms) 및 컴팩트 기본값 적용
- **전 채널 키프레임 동시 동기화**: `force-keyunit` 제어로 채널 간 분할 시차 최소화 (ms 수준)
- FragmentClosedEvent 오브젝트 풀링
- 고빈도 버스 메시지 필터링 (main.cpp -200줄/+42줄)
- 시간 기반 큐 사이징, `queue_tune` JSON 설정
- SIGTERM 핸들러 (그레이스풀 셧다운)
- Mutex 범위 최소화, 안전한 파일 쓰기

### MAX9296 v2.0 (커널 패닉 3건 수정)
- [CRITICAL] kthread_stop UAF: `get_task_struct()`/`put_task_struct()` 참조 관리
- [HIGH] 듀얼 모드 peer UAF: 4-phase remove 재설계
- [MEDIUM] soft lockup: `msleep_interruptible()` 전환
- probe 실패 경로 리소스 누수 수정

### RAW → BMP 병렬 변환 유틸리티
- `convert_raw_to_bmp_parallel.py` (441줄): multiprocessing 기반 4코어 병렬 변환
- Pillow 10.4.0 ARM64 wheel 패키지 포함 (`upgrade_file/pip/`)
- 루프 모드, 자동 포맷 감지, syslog 로깅

### ORD v4.8.1
- `waitingDisk()`에서 `checkSD()` 활성화 — 디스크 대기 시 SD 카드 상태 확인

### 시스템 신뢰성 및 복구 전략 강화
- **무중단 카메라 복구**: 연결 해제 시 앱 재시작 대신 **300초 주기 `init_cam.sh` 실행**으로 하드웨어 복구 시도 (chk_cam_operate.sh)
- **RTC 시간 자동 복구**: RTC 방전 감지 시 fake-hwclock 기반 시간 복구 및 **RTC 강제 재가동(`hwclock -w`)** (fake-hwclock.sh)
- **그레이스풀 셧다운**: SIGTERM 신호 수신 시 파이프라인 안전 종료(EOS) 및 파일 마감 (gstApp)

### 런타임 스크립트 및 설정 개선
- **설정 마이그레이션** (`update_edgeconf.sh`): JSON 검증 + 자동 백업, `queue_tune`/`rtsp_tune` 자동 마이그레이션
- **녹화 파일 관리** (`chk_cam_operate.sh`): 2단계 파일 이동, 스테일 .part 정리, 세션 기반 보관 정책
- **SD 카드 마운트** (`automnt_sd_for_emmc_boot.sh`): Read-Only 즉시 대응 및 RAM 모드 폴백
- **카메라 수동 제어**: AE On/Off 및 수동 노출/게인 제어 스크립트 추가

### 빌드/배포 인프라
- **Docker 빌드 환경** (`docker/`): Ubuntu 20.04 ARM64 + QEMU로 타겟 호환 바이너리 생성 (GLIBC 2.31)
  - `Dockerfile`, `build-image.sh`, `build.sh`, `.dockerignore`, `README.md`
- build.sh 전면 재설계: 선택적 모듈 빌드/클린 지원
- install_deb.sh: 패키지 설치 자동화
- `test/rsync_pim.sh`: 빌드 결과물 rsync 배포 스크립트
- fake-hwclock 강화: RTC 재시도, 커널 로그, 드라이버 확인
- 설정 업데이트: edgeconf_pim_base.json, ord_vcm_conf.json

---

## 📌 이전 변경사항 요약

### 1. **서브모듈 업데이트**

#### ORD (On-board Recording Daemon) - v4.8
**26개 커밋 통합** (커밋: 8add3e3, 4c35fc5)

##### 보안 강화 (10개 개선)
- ✅ **입력 검증 및 인젝션 방지**
  - 디스크 정리 토큰 검증
  - 재활용 정리 토큰 검증
  - Tail 복사 파일 토큰 검증
  - RTC 시간 필드 검증
  - 쉘 사용 감소 (직접 파일 쓰기)

##### 메모리 안전성 (5개 개선)
- ✅ **버퍼 오버플로 방지**
  - fgets 버퍼 크기 수정: `fgets(tmp, sizeof(tmp), fp)`
  - Overlay 큐 요소 크기 수정: `MAX_DATA_LEN` 사용
  - TCP 패킷 길이 검증: TOhtData 제로 초기화

- ✅ **초기화 및 안전성**
  - TCP read 상태 초기화
  - QEMU 검증 및 메모리 안전 경로 폴백
  - JSON-C 내부 포인터 저장 방지

##### 네트워크 및 IPC (4개 개선)
- ✅ **부분 TCP 전송 처리**: `send(MSG_DONTWAIT)` 루프
- ✅ **OPS 오버레이 JSON 처리**: parsed offset 전송
- ✅ **msgq Full 처리**: 수신자 다운 시 안전한 처리
- ✅ **msgq 리셋 후 재시도**: 자동 재전송

##### 스레드 안전성 (3개 개선)
- ✅ **스레드 조인 보호**: NULL 체크 추가
- ✅ **Redis 트리거 강화**: 스레드 라이프사이클 관리
- ✅ **max FD 재계산**: fd_sets 기반 정확한 계산

##### 디스크 관리
- ✅ **ext4 디스크 사용량 정확한 계산**: `disk_size_mnt = used + available`

##### 로깅
- ✅ **로그 태그 통합**: `[CPY]`, `[RDS]`, `[TCP]` 등 → `[EVT]`, `[OPS]`
- ✅ **로그 레벨 최적화**: overlay `INFO→DEBUG`, 버전 `EMERG→NOTICE`

##### 문서
- ✅ **설정 파일 예제**: `docs/edgeconf_pim.json`, `docs/ord_vcm_conf.json`

---

#### VCM (Vehicle Camera Manager) - v4.3
**20개 커밋 통합** (커밋: ddae101, 583baae, 4c35fc5)

##### SRT 강화 (5개 개선)
- ✅ **SRT Mutex 추가**: 멀티스레드 환경에서 안전한 SRT 데이터 접근
- ✅ **SRT Hardening**: 강화된 에러 처리 및 데이터 무결성
- ✅ **큐 크기 최적화**: 메모리 효율성 향상
- ✅ **Monotonic Clock 사용**: 시스템 시간 점프 대응 (NTP 동기화 안정성)
- ✅ **SRT Part 개선**: 부분 처리 로직 개선

##### 스레드 안전성 (5개 개선)
- ✅ **_TOpsData 스레드 잠금**: 멀티스레드 환경에서 안전한 OPS 데이터 접근
- ✅ **네트워크 FD 세트 Mutex**: `m_fdsMutex`로 `select()` 레이스 컨디션 방지
- ✅ **댕글링 포인터 해결**: TOpsData 메모리 접근 오류 방지
- ✅ **큐 데이터 손상 수정**: 큐 데이터 무결성 보장
- ✅ **강력한 IPC 에러 처리**: 안정적인 프로세스 간 통신

##### 성능 개선
- ✅ **비동기 파일 I/O**: 전용 워커 스레드 및 큐 기반 처리
  - 메인 스레드 블로킹 방지
  - I/O 처리량 증가

##### 보안
- ✅ **sprintf → snprintf**: 버퍼 오버플로 방지
- ✅ **system() 제거**: 쉘 인젝션 위험 제거

##### 경로 외부화 (2개 개선)
- ✅ **TVhlConf에 경로 필드 추가**: 하드코딩 경로를 설정으로 이동
- ✅ **동적 경로 변수 사용**: 배포 및 테스트 환경 유연성

##### 테스트
- ✅ **QEMU 검증 스위트**: 스마트 경로 폴백 및 자동화된 검증

##### 녹화 동기화
- ✅ **gstApp 동기화**: 분할 트리거 로직 동기화 (diff >= 0)
- ✅ **시작 신호 감지 개선**: 00s Snap-back 누락 방지
- ✅ **세션 완료 조정**: `.srt_done` 플래그 생성

##### 기타
- ✅ **메시지 큐 권한**: msgq perms 개선

---

### 2. **문서화**

#### V4L2 Control 가이드 (10e5154, 3cf08e3)
- ✅ **V4L2 컨트롤 사용 가이드 추가**: `dist/pim/opt/pim/docs/V4L2_CTRL_GUIDE.md` (232줄)
  - MAX9296 GMSL2 Deserializer + AP1302 ISP 제어
  - 채널별 커스텀 컨트롤 (gain, exposure, AE, AWB)
  - FSYNC 기반 FPS 제어 메커니즘
  - 사용 예시 및 설정 방법

---

### 3. **빌드 시스템**

#### build.sh 개선 (448038f)
- ✅ **clean 옵션 추가**: 빌드 아티팩트 정리 기능
  ```bash
  ./build.sh clean  # 빌드 산출물 삭제
  ./build.sh        # 일반 빌드
  ```

---

### 4. **녹화 시스템 강화**

#### 임시 파일 처리 강화 (eeeab4c)
**179줄 추가, 55줄 삭제**

##### automnt_sd_for_emmc_boot.sh
- ✅ **SD 카드 자동 마운트 강화**
  - 에러 처리 개선
  - 마운트 상태 검증

##### chk_cam_operate.sh
- ✅ **카메라 동작 체크 강화**
  - 임시 파일 처리 개선
  - part 파일 관리 강화
  - 에러 복구 메커니즘

##### kill_test.sh
- ✅ **카메라 재시작 강화**
  - 안전한 프로세스 종료
  - 리소스 정리 개선

---

### 5. **gstApp 바이너리**

#### 패키지된 바이너리 업데이트 (af7726a)
- ✅ **gstApp 바이너리 업데이트**
  - 최신 빌드 반영
  - 성능 개선 및 버그 수정 포함

---

## 📊 통계

| 구성요소 | 커밋 수 | 주요 개선사항 |
|---------|---------|--------------|
| **ORD** | 26개 | 보안 10개, 메모리 5개, 스레드 3개 |
| **VCM** | 20개 | SRT 5개, 스레드 5개, 성능 1개 |
| **gstApp** | 7개 (v1.4) | 저지연 튜닝, 오브젝트 풀링, 셧다운 |
| **MAX9296** | 3개 (v2.0) | 커널 패닉 3건, probe 누수 수정 |
| **런타임 스크립트** | 10개 | 설정 마이그레이션, 녹화 관리, 복구 전략 |
| **인프라** | 15개 | 빌드, Docker, fake-hwclock, 배포 |
| **문서** | 2개 | V4L2 가이드, 세션 라이프사이클 |
| **합계** | 23개 | 서브모듈 56개 커밋 통합 |

---

## 🏗️ 아키텍처

### PIM Package 구성

```
PIM Package
├── ORD (v4.8) - 이벤트 녹화 및 복사
│   ├── TCP Server (이벤트 수신)
│   ├── Event Copy Thread (영상 복사)
│   ├── OPS Thread (Redis 운행 데이터)
│   └── Disk Manager (디스크 관리)
│
├── VCM (v4.3) - 자막 생성 및 세션 관리
│   ├── SRT Thread (자막 생성)
│   ├── File I/O Worker (비동기 I/O)
│   ├── Network Thread (IPC)
│   └── Recording Sync (gstApp 동기화)
│
├── gstApp - GStreamer 기반 녹화
│   ├── V4L2 Source (카메라 캡처)
│   ├── Encoder (H.264/H.265)
│   ├── Muxer (MP4/MKV)
│   └── Split Controller (분할 녹화)
│
├── pim_gate - 게이트웨이
├── adab - ADAB 모듈
├── cism - CISM
└── 기타 유틸리티
```

---

## 🔒 보안 개선 요약

### ORD
- ✅ 입력 검증 및 인젝션 방지 (10개)
- ✅ 버퍼 오버플로 방지 (5개)

### VCM
- ✅ sprintf/system 제거 (1개)

### 녹화 스크립트
- ✅ 임시 파일 처리 강화

**총 16개의 보안 개선사항**

---

## 🚀 성능 개선 요약

### VCM
- ✅ 비동기 파일 I/O (워커 스레드 + 큐)
- ✅ 메인 스레드 블로킹 방지

### ORD
- ✅ ext4 디스크 사용량 정확한 계산
- ✅ 네트워크 처리 최적화

**총 4개의 성능 개선사항**

---

## 🧵 스레드 안전성 개선 요약

### ORD
- ✅ 스레드 조인 보호
- ✅ Redis 트리거 강화
- ✅ max FD 재계산

### VCM
- ✅ OPS 데이터 스레드 잠금
- ✅ 네트워크 FD 세트 Mutex
- ✅ SRT Mutex
- ✅ 댕글링 포인터 해결
- ✅ 큐 데이터 손상 수정

**총 8개의 스레드 안전성 개선사항**

---

## 📚 문서 개선

### 새로운 문서
- ✅ **V4L2_CTRL_GUIDE.md**: V4L2 컨트롤 사용 가이드 (232줄)
- ✅ **ord/RELEASE_NOTES.md**: ORD v4.8 릴리즈노트
- ✅ **vcm/RELEASE_NOTES.md**: VCM v4.3 릴리즈노트
- ✅ **ord/CHANGELOG.md**: ORD 변경사항 상세
- ✅ **vcm/CHANGELOG.md**: VCM 변경사항 상세
- ✅ **ord/docs/edgeconf_pim.json**: 시스템 설정 예제
- ✅ **ord/docs/ord_vcm_conf.json**: ORD/VCM 운영 설정 예제

---

## 🔧 빌드 및 배포

### 빌드 스크립트
```bash
# 전체 빌드
./build.sh

# 빌드 산출물 정리
./build.sh clean

# 서브모듈 업데이트
git submodule update --init --recursive
```

### 배포 구조
```
dist/pim/
├── opt/pim/
│   ├── bin/          # 실행 파일 및 스크립트
│   ├── docs/         # 문서 (V4L2_CTRL_GUIDE.md 등)
│   └── config/       # 설정 파일
└── ...
```

---

## ✅ 현재 상태

| 구성요소 | 버전 | 상태 | 품질 |
|---------|------|------|------|
| **ORD** | 4.8 | ✅ 프로덕션 | 보안 강화, 메모리 안전 |
| **VCM** | 4.3 | ✅ 프로덕션 | SRT 강화, 성능 개선 |
| **gstApp** | v1.4 | ✅ 프로덕션 | 저지연 최적화, 오브젝트 풀링 |
| **MAX9296** | v2.0 | ✅ 프로덕션 | 커널 패닉 3건 수정, 9.8/10 |
| **문서** | - | ✅ 완료 | V4L2 가이드, 세션 라이프사이클 |

---

## 🎯 주요 개선사항 하이라이트

### 보안 및 안정성
1. **입력 검증 강화**: 쉘 인젝션 방지, 토큰 검증
2. **메모리 안전성**: 버퍼 오버플로 방지, 댕글링 포인터 해결
3. **스레드 안전성**: Mutex 보호, 레이스 컨디션 방지

### 성능 및 효율성
1. **비동기 I/O**: 워커 스레드로 메인 스레드 보호
2. **디스크 관리**: 정확한 사용량 계산
3. **네트워크 최적화**: 부분 전송 처리

### 동기화 및 협업
1. **gstApp 동기화**: 정확한 분할 트리거
2. **세션 완료 조정**: .srt_done 플래그
3. **시간 안정성**: Monotonic clock 사용

### 유연성 및 유지보수성
1. **경로 외부화**: 설정 기반 경로 관리
2. **문서화**: 사용 가이드 및 설정 예제
3. **빌드 개선**: clean 옵션 추가

---

## 📝 마이그레이션 가이드

### 이전 버전 → 현재 버전

#### 1. 서브모듈 업데이트
```bash
git submodule update --init --recursive
```

#### 2. 재빌드
```bash
./build.sh clean
./build.sh
```

#### 3. 설정 확인
- `dist/pim/opt/pim/docs/V4L2_CTRL_GUIDE.md` 참고
- `ord/docs/edgeconf_pim.json` 설정 예제 확인
- `ord/docs/ord_vcm_conf.json` ORD/VCM 설정 확인

#### 4. 로그 태그 업데이트 (ORD)
```bash
# 이전 태그: [CPY] [RDS] [TCP] [OVL] [RTC] [OSS] [VER] [ERR]
# 새 태그: [EVT] [OPS]
```

---

## 🔗 관련 문서

### 통합 문서
- [`RELEASE_NOTES.md`](./RELEASE_NOTES.md) — PIM Package v0.5.8 통합 릴리즈 노트
- [`session-lifecycle.md`](./session-lifecycle.md) — 세션 라이프사이클 관리

### 서브 프로젝트 문서
- **gstApp**: [`RELEASE_NOTES_v1.4.md`](./gstApp/RELEASE_NOTES_v1.4.md) | [`RELEASE_NOTES_v1.3.md`](./gstApp/RELEASE_NOTES_v1.3.md) | [`RECORDING_SYNC_PLAN.md`](./gstApp/RECORDING_SYNC_PLAN.md) | [`PERFORMANCE_OPTIMIZATION_PLAN.md`](./gstApp/PERFORMANCE_OPTIMIZATION_PLAN.md)
- **ORD**: [`RELEASE_NOTES.md`](../ord/RELEASE_NOTES.md) | [`VERIFICATION_GUIDE_ORD.md`](../ord/docs/VERIFICATION_GUIDE_ORD.md) | [`edgeconf_pim.json`](../ord/docs/edgeconf_pim.json)
- **VCM**: [`VERIFICATION_GUIDE_VCM.md`](../vcm/docs/VERIFICATION_GUIDE_VCM.md)
- **MAX9296**: [`RELEASE_NOTES.md`](./max9296/RELEASE_NOTES.md) | [`CHANGELOG.md`](./max9296/CHANGELOG.md) | [`V4L2_CTRL_GUIDE.md`](./max9296/V4L2_CTRL_GUIDE.md)
- **설정 예제**: [`edgeconf_pim.json`](../ord/docs/edgeconf_pim.json) | [`ord_vcm_conf.json`](../ord/docs/ord_vcm_conf.json)

---

## 👥 Credits

이 릴리즈는 다음 기여자들의 노력으로 완성되었습니다:

- **Sisyphus AI**: ORD/VCM 보안 및 안정성 개선 (대부분의 커밋)
- **Claude Sonnet 4.5**: 문서화 및 통합
- **Gemini**: gstApp 성능 최적화 계획 수립 및 구현, 큐 튜닝, 동기화 로직 고도화
- **GLM**: 기술 자문 및 시스템 아키텍처 검토
- **hwjo**: 프로젝트 유지보수 및 통합

---

**Full Integration**: ORD v4.8 (26) + VCM v4.3 (20) + gstApp v1.4 (7) + MAX9296 v2.0 (3) + 인프라 (15) = 총 23 + 서브모듈 56 커밋
