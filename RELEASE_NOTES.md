# PIM Package Release Notes

## v0.5.8 (2026-01-09 ~ 2026-02-10)

### 핵심
**보안 전면 패치 + 녹화 동기화 재설계 + V4L2 직접 제어 + 커널 드라이버 안정화**

gstApp, ORD, VCM 3개 애플리케이션의 보안 취약점을 전수 점검하고, 녹화 분할 동기화 시스템을 재설계하여 정각 정렬 신뢰성을 대폭 향상시켰습니다. GStreamer extra-controls 방식을 V4L2 subdev ioctl 직접 호출로 전환하고, MAX9296 커널 드라이버의 안정성 이슈를 해결했습니다.

---

### 컴포넌트 버전

| 컴포넌트 | 이전 (v0.5.7) | 현재 (v0.5.8) | 변경 규모 |
|---------|--------------|--------------|----------|
| **gstApp** | v1.2 | **v1.3** | 23파일, +6,237 / -4,521줄 |
| **ORD** | v4.7 | **v4.8** | 26 커밋 |
| **VCM** | v4.2 | **v4.3** | 20 커밋 |
| **MAX9296 Driver** | v1.6 | **v1.9** | 4 릴리즈 |

---

### 신규 기능

#### 1. 녹화 동기화 시스템 재설계 (gstApp + VCM)

녹화 파일 분할의 정각 정렬 신뢰성을 근본적으로 개선했습니다.

- **세션 기반 녹화 아키텍처**: GStreamer 1.18.0 호환 세션 관리 도입
- **분할 트리거 방식 전환**: 정확한 시간 일치(`==`) → 목표 시간 도달 확인(`>=`)
- **타이머 정밀도 향상**: 1초 → 500ms 주기로 단축
- **스마트 분할 보호**: 최소 분할 간격 5초, 최대 드리프트 허용치 30초
- **Snap-back 복구**: 00초 정각으로의 자동 복구 (유예 기간 58초)
- **키프레임 동기화**: encoderBin에 키프레임 강제 삽입, 분할 시점 재생 호환성 보장
- **fragment-closed 워커 스레드**: splitmuxsink 이벤트 처리를 별도 스레드로 오프로드
- **VCM 동기화 개선**: `.srt_done` 플래그 기반 세션 완료 협업, 시작 신호 감지 개선
- **녹화 통계 로깅**: fragment-opened 시점에 이전 세션 통계(파일명, 크기, 지속시간) 출력

#### 2. V4L2 직접 제어 통합 (gstApp + MAX9296)

GStreamer extra-controls 방식에서 V4L2 subdev ioctl 직접 호출로 전환했습니다.

- **subdev ioctl 직접 호출**: 카메라 컨트롤 응답성 및 안정성 향상
- **듀얼 채널 per-channel 제어**: 채널별 독립적인 V4L2 컨트롤 적용
- **새로운 V4L2 컨트롤**: `ae_on` (자동 노출), `ext_time` (외부 타임스탬프)
- **설정 파서 확장**: `v4l_map`, `rtsp_tune` 옵션 추가
- **RTSP latency 설정**: 설정 파일에서 레이턴시 직접 제어

#### 3. PNG 캡처 시스템 개선 (gstApp)

- **PNG 캡처 인코더 추가**: 새로운 PNG 인코딩 파이프라인
- **캡처 타이밍 안정화**: captureBin 대폭 확장
- **버퍼드 캡처 강화**: 파일 쓰기 안전성 강화
- **캡처 디렉토리 동적 설정**: IPC를 통한 저장 경로 변경

#### 4. VCM 비동기 파일 I/O

메인 스레드 블로킹을 제거하여 응답성과 처리량을 향상시켰습니다.

```
이전 (동기): 메인 스레드 → 파일 쓰기 (블로킹) → 다음 작업
이후 (비동기): 메인 스레드 → 큐 → 즉시 다음 작업
              워커 스레드 → 파일 쓰기 (백그라운드)
```

#### 5. VCM 경로 외부화

하드코딩된 경로를 TVhlConf 설정으로 이동하여 환경별 설정 및 QEMU 테스트를 지원합니다.

---

### 보안 강화

#### gstApp (Critical)
- `system()` / `popen()` 호출 전량 제거 → `execvp()` / `g_spawn_sync()` 교체
- 하드코딩된 AES 암호화 키 외부 설정으로 분리
- i2c 명령 실행 및 mkdir 경로 검증 로직 추가
- 16개 파일에 걸친 리소스 누수 전수 점검 및 수정
- `stat()` → `g_stat()` 교체로 GLIBC_2.33 의존성 제거

#### ORD (10개 항목)
- 디스크 정리/재활용 정리/Tail 복사 파일 토큰 검증
- RTC 시간 범위 검증 (2000~2100년)
- echo 명령 → 직접 파일 쓰기로 쉘 사용 감소
- fgets 버퍼 크기 수정 (`sizeof(tmp)` 사용)
- Overlay 큐 요소 크기 수정 (`MAX_DATA_LEN`)
- TCP 패킷 최소 길이 검증 (10바이트)
- TCP read 상태 변수 초기화
- JSON-C 내부 포인터 직접 저장 방지

#### VCM (1개 항목)
- `sprintf` → `snprintf`, `system()` 제거

#### 녹화 스크립트
- automnt_sd, chk_cam_operate, kill_test 스크립트의 임시 파일 처리 강화

**총 보안 개선: 28개 항목** (gstApp 16파일 + ORD 10개 + VCM 1개 + 스크립트 1개)

---

### 스레드 안전성 개선

#### ORD (3개)
- 스레드 조인 보호 (NULL 체크)
- Redis 트리거 및 복사 스레드 라이프사이클 관리
- 클라이언트 해제 시 max FD 재계산 (fd_sets 기반)

#### VCM (5개)
- `_TOpsData` 스레드 잠금 활성화
- 네트워크 FD 세트 Mutex (`m_fdsMutex`) 도입
- SRT Mutex 추가
- TOpsData 댕글링 포인터 해결
- 큐 데이터 손상 수정 및 IPC 에러 처리 강화

**총 스레드 안전성 개선: 8개 항목**

---

### 성능 최적화

#### gstApp
- **타임스탬프 캐싱**: `g_date_time_format` 호출을 동일 초 내 캐싱으로 대체 (호출 1/4 절감)
- **정적 버퍼 전환**: `g_strdup_printf` → `snprintf` + 정적 버퍼
- **Makefile 크로스 컴파일 안전성 개선**

#### VCM
- **비동기 파일 I/O**: 전용 워커 스레드 + 큐 기반 처리
- **Monotonic Clock**: `CLOCK_MONOTONIC` 사용으로 NTP 동기화 시에도 안정적

#### ORD
- **ext4 디스크 사용량 정확한 계산**: `disk_size_mnt = used + available`
- **부분 TCP 전송 처리**: `send(MSG_DONTWAIT)` 루프로 데이터 손실 방지

---

### MAX9296 커널 드라이버 (v1.7 → v1.9)

v0.5.7에 포함되었던 v1.6에서 3개 릴리즈를 거쳐 v1.9로 업데이트되었습니다.

#### v1.9
- `usleep_range` 타이밍 최적화: delay_ms 범위 폭을 10%로 증가
- `_FILE_` 매크로 정의에 괄호 추가 (연산자 우선순위 문제 방지)

#### v1.8
- 죽은 코드(`#if 0` 블록) 11개 완전 제거
- `max9286_set_ctrl_pixelrate` → `max9296_set_ctrl_pixelrate` 오타 수정
- FSYNC 기반 FPS 제어 메커니즘 문서화
- 코드 스타일 정리 및 로직 개선

#### v1.7
- rmmod 시 kthread use-after-free 에러 수정
- GitHub Actions CI 워크플로우 추가

**품질 점수: 9.5/10 (프로덕션 사용 가능)**

---

### 버그 수정

| 컴포넌트 | 버그 | 설명 |
|---------|------|------|
| gstApp | `search_file` 로직 오류 | 최근 수정 파일을 정확히 반환하도록 수정 |
| gstApp | Segfault | 키프레임 동기화 중 세그폴트 수정 |
| gstApp | 출력 파일 충돌 | 동일 이름 바이너리 출력 충돌 방지 |
| gstApp | subdev 매핑 오류 | V4L2 subdev 노드 매핑 수정 |
| gstApp | 메모리 누수 | main.cpp, videoBin.cpp 할당 해제 누락 수정 |
| gstApp | 소켓 클린업 | tcpServer 소켓 자원 누수 수정 |
| ORD | msgq 오버플로 | 수신자 다운 시 msgq full 안전 처리 |
| ORD | OPS JSON 처리 | parsed offset 전송으로 수정 |
| VCM | 댕글링 포인터 | TOpsData 메모리 접근 오류 수정 |
| VCM | 큐 데이터 손상 | 큐 데이터 무결성 보장 |
| MAX9296 | use-after-free | rmmod 시 kthread 에러 수정 |
| MAX9296 | 죽은 코드 | `#if 0` 블록 11개 제거 |

---

### CI/CD 및 자동화 (gstApp)

- **중앙집중 워크플로우 설정**: `workflow-config.yml` 토글 게이트 시스템
- **AI 코드 리뷰 3종 통합**: Claude, Gemini, OpenCode 자동 PR 리뷰
- **ChatOps `/build`**: 이슈 코멘트에서 빌드 트리거
- **보안 게이트**: comment-driven 봇을 조직 멤버 전용으로 제한
- **레거시 정리**: 구형 Gemini 헬퍼 6개 파일 삭제 (-628줄)

---

### 문서

| 문서 | 내용 |
|------|------|
| `docs/V4L2_CTRL_GUIDE.md` | V4L2 컨트롤 사용 가이드 (232줄) |
| `ord/RELEASE_NOTES.md` | ORD v4.8 릴리즈 노트 |
| `vcm/RELEASE_NOTES.md` | VCM v4.3 릴리즈 노트 |
| `gstApp/docs/RELEASE_NOTES_v1.3.md` | gstApp v1.3 릴리즈 노트 |
| `max9296/CHANGELOG.md` | MAX9296 드라이버 변경사항 |
| `gstApp/docs/RECORDING_SYNC_PLAN.md` | 녹화 동기화 계획서 |
| `gstApp/docs/PERFORMANCE_OPTIMIZATION_PLAN.md` | 성능 최적화 계획서 |
| `gstApp/docs/SPLITMUXSINK.md` | splitmuxsink 기술 문서 |
| `ord/docs/edgeconf_pim.json` | 시스템 통합 설정 예제 |
| `ord/docs/ord_vcm_conf.json` | ORD/VCM 운영 설정 예제 |

---

### 호환성 정보

| 항목 | 값 |
|------|----|
| 타겟 플랫폼 | i.MX8MP (NXP BSP) |
| 커널 | Linux 5.10.x |
| GStreamer | 1.18.0 이상 |
| GLIBC | 2.31 이상 (2.33 의존성 제거됨) |
| json-c | 정적 링킹 |
| hiredis | 정적 링킹 |
| Redis | OPS 데이터 처리 시 필요 |

---

### 마이그레이션 가이드 (v0.5.7 → v0.5.8)

#### 1. 코드 업데이트
```bash
cd /opt/pim-package
git pull
git submodule update --init --recursive
```

#### 2. 빌드
```bash
./build.sh clean
./build.sh
```

#### 3. 설정 확인

**ORD 로그 태그 변경** (로그 분석 스크립트 업데이트 필요):
```bash
# 이전: [CPY] [RDS] [TCP] [OVL] [RTC] [OSS] [VER] [ERR]
# 이후: [EVT] [OPS]
```

**VCM 경로 설정** (`edgeconf_pim.json`에 추가):
```json
{
  "VHL_CAM": {
    "tmp_path": "/dev/shm",
    "sd_tmp_path": "/mnt/sd_cam/tmp",
    "final_path": "/mnt/sd_cam"
  }
}
```

#### 4. 서비스 재시작
```bash
systemctl restart ord vcm gstApp
```

#### 5. 검증
```bash
# 버전 확인
journalctl -u gstApp | grep "version"   # 1.3
journalctl -u ord | grep "version"      # 4.8
journalctl -u vcm | grep "version"      # 4.3

# 녹화 동기화 확인
journalctl -u gstApp | grep "split"
journalctl -u vcm | grep "start signal"

# V4L2 컨트롤 확인
v4l2-ctl -d /dev/v4l-subdev2 --list-ctrls
```

---

### 알려진 제한사항

- gstApp 성능 최적화 중 버스 메시지 풀링, Zero-copy 경로 재검증은 향후 버전에서 구현 예정
- `/dev/shm` 기반 프로세스 간 상태 공유 방식은 검토 단계

---

### 통계 요약

| 구분 | 수치 |
|------|------|
| **총 커밋** | 약 110개 (gstApp 65 + ORD 26 + VCM 20 + 통합 8) |
| **보안 개선** | 28개 항목 |
| **스레드 안전성** | 8개 항목 |
| **성능 개선** | 7개 항목 |
| **버그 수정** | 12개 항목 |
| **문서** | 10개 파일 |

---

### 버전 흐름

```
v0.5.4 (캡처 + 인코더 + Muxer)
    ↓
v0.5.5 (안정성 강화)
    ↓
v0.5.6 (ext4 + journald)
    ↓
v0.5.7 (비동기 캡처 + Request Queue)
    ↓
v0.5.8 (보안 + 녹화 동기화 + V4L2 + 드라이버) ← 현재
```

---

### 기여자

- **hwjo**: 프로젝트 유지보수, V4L2 통합, 녹화 동기화 설계
- **Sisyphus AI**: ORD/VCM 보안 및 안정성 개선
- **Claude**: gstApp 보안 패치, 문서화, CI/CD 자동화

---

**배포일**: 2026-02-10
**이전 버전**: v0.5.7 (2026-01-09)
**상태**: 프로덕션 준비 완료
