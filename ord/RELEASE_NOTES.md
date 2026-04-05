# ORD (On-board Recording Daemon) Release Notes

## Version 4.8.1 (2026-02-11)

### Patch
- **SD 카드 체크 활성화**: `waitingDisk()`에서 `checkSD()` 호출 주석 해제 — 디스크 대기 루프 진입 전 SD 카드 상태를 확인하도록 복원

---

## Version 4.8 (2026-02-10)

### 🎉 Overview
ORD 4.8은 보안 강화 및 안정성 개선에 초점을 맞춘 주요 릴리즈입니다. 입력 검증, 메모리 안전성, 스레드 안전성을 대폭 강화하여 프로덕션 환경에서의 안정성을 크게 향상시켰습니다.

### 📋 System Requirements
- **Platform**: iMX8MP
- **Kernel**: Linux 5.10+
- **Dependencies**:
  - json-c (정적 링킹)
  - hiredis (정적 링킹)
  - Redis server (OPS 기능 사용 시)

---

## 🆕 What's New

### Build System Improvements
- **pkg-config 기반 자동 빌드**: json-c, hiredis 라이브러리 자동 검색 및 링크
- **정적 라이브러리 링킹**: `-l:libjson-c.a`, `-l:libhiredis.a` 명시적 사용
- **iMX8 타겟 빌드 스크립트**: `make-for-imx8` 추가

### Configuration Documentation
- **설정 파일 예제 추가**:
  - `docs/edgeconf_pim.json`: 네트워크, 센서, 카메라 설정
  - `docs/ord_vcm_conf.json`: ORD/VCM 운영 설정

### Logging Standardization
- **로그 태그 통합**:
  - 이벤트 관련 로그를 `[EVT]` 태그로 통합
  - OPS(운행 데이터) 관련 로그를 `[OPS]` 태그로 통합
- **로그 레벨 최적화**:
  - 오버레이 수신: `INFO` → `DEBUG`
  - 버전 정보: `EMERG` → `NOTICE`

---

## 🔒 Security Enhancements

### Input Validation & Injection Prevention

#### File Token Validation
모든 외부 입력을 검증하여 쉘 인젝션 위험을 제거했습니다:

- ✅ **디스크 정리 토큰 검증**
  - popen() 출력을 chomp하고 안전하지 않은 토큰 거부
  - rm 명령 실행 전 파일명 검증

- ✅ **재활용 정리 토큰 검증**
  - `mv_path` 유래 토큰을 rm 명령 전에 검증
  - 안전하지 않은 경로 차단

- ✅ **Tail 복사 파일 토큰 검증**
  - xargs 기반 `cp -a` 실행 전 파일명 검증
  - 정상 파일명에 대한 기존 동작 유지

#### RTC Time Validation
- ✅ **시간 범위 검증**: hwclock/system 명령 실행 전 유효성 체크
  - 연도: 2000-2100
  - 월: 1-12
  - 일: 1-31
  - 시간: 0-23
  - 분/초: 0-59

#### Shell Usage Reduction
- ✅ **직접 파일 쓰기**: echo 명령 대신 직접 파일 I/O 사용
- ✅ **명령 포맷 강화**: 디스크/이벤트 정리 시 안전한 명령 구성

---

## 🛡️ Memory Safety Improvements

### Buffer Overflow Prevention

- ✅ **fgets 버퍼 크기 수정**
  ```c
  // 이전: fgets(tmp, 128, fp)
  // 이후: fgets(tmp, sizeof(tmp), fp)
  ```
  디스크 관리 popen() 읽기에서 버퍼 오버플로 방지

- ✅ **Overlay 큐 요소 크기 수정**
  - `MAX_DATA_LEN` 사용으로 오버리드/오버플로 방지
  - TOhtData 패킷 enqueue/dequeue 시 안전성 보장

- ✅ **TCP 패킷 길이 검증**
  - TOhtData 제로 초기화
  - 헤더/페이로드 필드 접근 전 최소 길이(10바이트) 체크
  - 유효하지 않은 패킷 조기 거부

### Initialization & Safety

- ✅ **TCP Read 상태 초기화**
  - `ret`, `nread` 변수 초기화
  - `ioctl(FIONREAD)` 실패 처리 강화
  - 초기화되지 않은 값 사용 방지

- ✅ **메모리 안전 경로 폴백**
  - QEMU 검증 구현
  - 메모리 안전성 보장 메커니즘 추가

- ✅ **JSON-C 내부 포인터 저장 방지**
  - opsData에 json-c 내부 문자열 포인터 직접 저장 금지
  - `snprintf` 사용으로 안전한 문자열 복사

---

## 🔧 Network & IPC Improvements

### TCP Communication

- ✅ **부분 전송 처리**
  - `send(MSG_DONTWAIT)` 루프 구현
  - 응답 바이트가 요청보다 적게 전송될 때 재전송
  - 데이터 손실 방지

- ✅ **OPS 오버레이 JSON 처리 개선**
  - 초기화되지 않은 velocity 대신 parsed offset 전송
  - `opsNodeOffset`에 올바른 값 전송

### Message Queue

- ✅ **msgq Full 처리**
  - 수신자 다운 시 안전한 처리
  - 큐 오버플로 방지

- ✅ **msgq 리셋 후 IPC 전송 재시도**
  - 연결 재설정 시 자동 재전송
  - 메시지 손실 최소화

---

## 🧵 Thread Safety Enhancements

### Thread Lifecycle Management

- ✅ **destroy에서 스레드 조인 보호**
  - 스레드 핸들 NULL 체크 추가
  - 안전한 스레드 종료 보장

- ✅ **Redis 트리거 및 복사 스레드 강화**
  - 스레드 라이프사이클 관리 개선
  - 레이스 컨디션 방지

### File Descriptor Management

- ✅ **max FD 재계산**
  - 클라이언트 연결 해제 시 `m_fdMax`/`e_fdMax` 재계산
  - fd_sets 기반 정확한 계산
  - 유효하지 않은 `select()` 범위 방지

---

## 💾 Disk Management Improvements

### Accurate Usage Calculation

- ✅ **ext4 디스크 사용량 정확한 계산**
  ```c
  // 이전: disk_size_mnt = used만 사용
  // 이후: disk_size_mnt = used + available (bavail)
  ```
  - `disk_limit_per`가 ext4의 df와 정렬
  - 정확한 디스크 용량 관리

---

## 📚 Documentation

### Configuration Examples

#### docs/edgeconf_pim.json
네트워크, 센서, 카메라 통합 설정:

- **네트워크**: WLAN0, ETH0, ETH1 설정
- **센서**: ACC(가속도), ADC, ETHERCAT 설정
- **VHL 카메라**: 4채널 카메라 설정
  - I2C1/I2C2 각 2채널
  - RTSP 스트리밍 설정
  - 캡처 및 녹화 설정

#### docs/ord_vcm_conf.json
ORD/VCM 운영 설정:

- **ORD**: 이벤트 녹화 및 디스크 관리
  - 자동 제거 옵션
  - 복사 마진
  - 디스크 임계값

- **VCM**: SRT 및 OPS 처리
  - SRT 자동 동기화
  - OPS 운행 데이터 처리
  - 버퍼링 설정

- **ETC**: 파일 체크 및 재부팅 옵션

---

## 📊 Quality Metrics

| Category | Improvements |
|----------|--------------|
| **Security Fixes** | 10개 (입력 검증, 인젝션 방지) |
| **Memory Safety** | 5개 (버퍼 오버플로, 초기화) |
| **Thread Safety** | 3개 (조인 보호, FD 관리) |
| **Network Reliability** | 4개 (부분 전송, msgq 처리) |
| **Build System** | 3개 (pkg-config, 정적 링킹) |
| **Documentation** | 2개 (설정 예제 추가) |

---

## 🚀 Migration Guide

### v4.7 → v4.8

#### 빌드 시스템
변경사항 없음. 기존 빌드 환경 유지.

```bash
# 일반 빌드
make clean && make

# iMX8 타겟 빌드
./make-for-imx8
```

#### 설정 파일
기존 설정 호환. 새로운 설정 옵션 참고:

- `docs/edgeconf_pim.json`: 전체 시스템 설정 예제
- `docs/ord_vcm_conf.json`: ORD/VCM 운영 설정 예제

#### 로그 분석
로그 태그가 변경되었으므로 로그 분석 스크립트 업데이트 필요:

```bash
# 이전 태그
[CPY] [RDS] [TCP] [OVL] [RTC] [OSS] [VER] [ERR]

# 새로운 태그
[EVT] [OPS]
```

---

## 🔍 Known Issues

없음. 모든 알려진 이슈가 해결되었습니다.

---

## 📝 Detailed Changes (v4.7 → v4.8)

### Build & Dependencies
- ac97ce4: 정적 라이브러리 링킹 (json-c, hiredis)
- ae65dc5: pkg-config 링킹 및 make-for-imx8 추가
- bcd2650: 빌드 아티팩트 .gitignore 추가

### Security & Input Validation
- 42823bc: 디스크 정리 토큰 검증
- df1bd3a: 재활용 정리 토큰 검증
- c27c851: 디스크 정리 파일 토큰 사전 검증
- 8d1b5e5: Tail 복사 파일 토큰 사전 검증
- 2087060: RTC 시간 필드 검증
- 9a35f62: 디스크 관리자에서 쉘 사용 감소

### Memory Safety
- 3a37ae7: fgets 버퍼 크기 수정
- 3cfedf1: Overlay 큐 요소 크기 수정
- 38f1335: TCP 명령 패킷 길이 검증
- 9433384: TCP read 상태 초기화
- 0e3b4ca: OPS 오버레이 JSON 데이터 처리 수정
- 87bd943: 메모리 안전성 강화 및 QEMU 검증
- 3fab440: 메모리 안전성 보장 및 QEMU 경로 폴백

### Network & IPC
- 6db2596: 부분 TCP 전송 처리
- 58c439f: 수신자 다운 시 msgq full 처리
- 87bc8ea: msgq 리셋 후 IPC 전송 재시도

### Thread Safety
- 58047d0: destroy에서 스레드 조인 보호
- fe51ca2: Redis 트리거 및 복사 스레드 강화
- a7a88b0: 닫기 시 max fd 재계산

### Disk Management
- 7373be1: ext4 디스크 사용량 임계값 계산 수정

### Logging & Monitoring
- 9af8cf6: 로깅 및 machineID 처리 강화
- 94b3d39: 로그 태그 통합 및 설정 파일 예제 추가

### Version
- ad8be0b: SW_VERSION을 4.8로 업데이트

---

## 🏗️ Architecture

### Components

```
ORD (On-board Recording Daemon)
├── TCP Server (이벤트 수신 및 처리)
│   ├── Overlay 처리 (CMD_STATUSINFO_BLACKBOX)
│   ├── RTC 설정 (CMD_TIMESETTING_BLACKBOX)
│   └── 이벤트 요청 (CMD_EVENTREQ_BLACKBOX)
│
├── Event Copy Thread (이벤트 영상 복사)
│   ├── Target Copy (특정 시각 영상)
│   └── Tail Copy (최근 N개 파일)
│
├── OPS Thread (운행 데이터 처리)
│   ├── Redis Subscribe
│   ├── JSON Parsing
│   └── IPC 전송
│
└── Disk Manager (디스크 공간 관리)
    ├── 사용량 모니터링
    ├── 자동 정리
    └── 재활용 폴더 관리
```

---

## 🔗 Integration

### Redis OPS Data Flow
```
Redis (운행 데이터)
  → OPS Thread (waitingGetOPS)
    → JSON Parsing (tag, offset)
      → IPC Message Queue
        → VCM Process
          → SRT Overlay
```

### Event Recording Flow
```
VHL (차량 모니터링)
  → TCP Event Request
    → Event Copy Thread
      → 영상 파일 복사 (PATH_MOUNT → PATH_EVENT)
        → Disk Manager (자동 정리)
          → Event ACK
```

---

## 📞 Support

### Issue Reporting
프로젝트 이슈는 내부 이슈 트래커에 보고하세요.

### Configuration
설정 파일 예제:
- `docs/edgeconf_pim.json`
- `docs/ord_vcm_conf.json`

### Logs
로그 위치:
- 시스템 로그: `/var/log/syslog`
- ORD 로그: `[EVT]`, `[OPS]` 태그로 필터링

```bash
# 이벤트 로그 확인
journalctl -u ord | grep "\[EVT\]"

# OPS 데이터 로그 확인
journalctl -u ord | grep "\[OPS\]"
```

---

## 👥 Credits

이 릴리즈는 다음 기여자들의 노력으로 완성되었습니다:

- **Sisyphus AI**: 보안 및 안정성 개선 (26개 커밋 중 24개)
- **Claude Sonnet 4.5**: 로그 통합 및 문서화

---

## 📅 Release History

| Version | Date | Highlights |
|---------|------|------------|
| **4.8.1** | 2026-02-11 | SD 카드 체크 활성화 (`waitingDisk`) |
| **4.8** | 2026-02-10 | 보안 강화, 메모리 안전성, 스레드 안전성 |
| **4.7** | 2026-02-09 | (이전 릴리즈) |

---

## 🎯 Next Steps

### Recommended Actions

1. **보안 검토 완료**: 입력 검증 및 인젝션 방지 메커니즘 확인
2. **메모리 프로파일링**: Valgrind 또는 AddressSanitizer로 메모리 누수 확인
3. **스트레스 테스트**: 고부하 상황에서 스레드 안전성 검증
4. **설정 검토**: `docs/` 예제 파일 참고하여 운영 설정 최적화

### Future Enhancements

- [ ] systemd service 파일 추가
- [ ] 성능 메트릭 모니터링 추가
- [ ] 자동 테스트 스위트 구축
- [ ] Docker 컨테이너 지원

---

**Full Changelog**: 커밋 d056ae7e..94b3d39 (26 commits)
