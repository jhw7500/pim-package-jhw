# PIM Package 릴리즈 노트
## v0.5.4 ~ v0.5.7

---

## 🎯 핵심 수정사항 (Quick Summary)

- **v0.5.7** (2025-12-01 ~ 2026-01-09) : 💥 성능 혁명
  - **gstApp v1.2 비동기 캡처 시스템 구현**: 워커 쓰레드 기반 비동기 처리로 메인 애플리케이션 블로킹 없이 빠른 연속 캡처 가능, realtime muxer 공식 지원
  - **Request Queue 아키텍처 도입**: 연속된 캡처 명령을 큐에 저장하여 명령 누락 없이 순서대로 처리
  - **SD 복구 전략 변경**: 자동 fsck 복구 제거하고 SD 마운트 실패 시 /dev/shm으로 자동 폴백하여 서비스 중단 방지
  - **ORD v4.7 에러 리포팅 제어**: err_send_period 설정으로 에러 전송 주기 조절, 네트워크 트래픽 최적화
  - **ext4 파일시스템 커밋 주기 최적화**: 쓰기 성능 향상을 위한 커밋 주기 튜닝

- **v0.5.6** (2025-10-28 ~ 2025-11-26) : 💥 스토리지 혁명
  - **ext4 마운트 옵션 최적화**: commit=60, data=writeback 등 성능 옵션 적용으로 SD 카드 쓰기 성능 대폭 향상
  - **동적 파일시스템 감지 및 최적화**: SD 카드 삽입 시 FAT32/ext4/exfat 타입 자동 판별 후 최적 마운트 옵션 적용
  - **journald 통합 로깅 시스템 구축**: systemd-journald 기반 통합 로그 관리, RAM 제한 설정 및 eMMC 스냅샷 저장
  - **로그 레벨 표준화**: 모든 애플리케이션 로그 레벨을 INFO로 통일하여 로그량 최적화
  - **시스템 서비스 안정화**: timer 서비스를 crontab으로 전환하여 안정성 향상

- **v0.5.5** (2025-09-23 ~ 2025-10-28) : 안정성 강화
  - **ORD v4.6 이벤트 복사 시간 예측**: 높은 bps 영상의 큰 용량을 고려한 복사 지연 시간 자동 계산 (evt_copy_delay = (max_bps/1024) * recMinute)
  - **SD 카드 읽기 전용 자동 복구**: /sys/block/mmcblk1/ro 파일로 상태 감지 후 fsck.vfat 자동 실행 ⚠️ (v0.5.7에서 제거됨)
  - **RTC 초기화 개선**: Real-Time Clock 빠른 로딩으로 부팅 직후부터 정확한 타임스탬프 로깅 가능
  - **fake-hwclock 추가**: RTC 하드웨어 오류 시에도 시간 유지 가능
  - **카메라 회전 기능 재활성화**: streamApp에서 0°, 90°, 180°, 270° 회전 설정 가능, i2c 하드웨어 레벨 제어

- **v0.5.4** (2025-07-01 ~ 2025-09-22) : Capture + Encoder + Muxer
  - **gstApp v1.0 개발**: Turbojpeg 라이브러리 통합으로 고속 JPEG 인코딩 지원, Combined/Dual encoder 구현
  - **인코더 설정 기능 추가** (v0.5.4.1 테스트): edgeconf에서 JPEG/Turbo/RAW 인코더 선택 및 캡처 품질 0~100 조절 기능
  - **gstApp v1.1 정식 출시**: 스트림 watchdog 추가로 비디오 스트리밍 상태 실시간 모니터링, 카메라 설정 타이밍 최적화
  - **TS Muxer 지원**: MPEG-TS 컨테이너 포맷 지원으로 실시간 스트리밍 호환성 향상
  - **ord v4.5 업데이트**: 신규 장비 타입 12853, 12855 추가 및 TS 확장자 지원
  - **SD 카드 마운트 개선**: 시작 시 SD 카드 마운트 체크 후 실패 시 RAM으로 자동 폴백, 데몬 통합
  - **시스템 최적화**: /tmp를 tmpfs로 마운트하여 임시 파일 처리 속도 향상

---

## 💡 버전 선택 가이드

| 필요 기능 | 권장 버전 | 이유 |
|----------|----------|------|
| 보안 + 녹화 동기화 | **v0.5.8 (최신)** | 보안 전면 패치 + 녹화 동기화 재설계 + V4L2 |
| 빠른 연속 캡처 | **v0.5.7** | 비동기 캡처 + Request Queue |
| ext4 SD 카드 | **v0.5.6** 이상 | ext4 최적화 + journald |
| 안정성 최우선 | **v0.5.5** | SD 자동 복구 + RTC 개선 |
| FAT32 SD 카드 | v0.5.5 | ext4 전환 전 마지막 버전 |

**업그레이드 경로**: `v0.5.4` → `v0.5.5` → `v0.5.6` → `v0.5.7` → `v0.5.8`

---

## 📦 v0.5.7 (2025-12-01 ~ 2026-01-09)

### 🔥 핵심
**비동기 캡처 시스템 + ext4 안정화 + SD 복구 전략 변경**

### ✨ 신규 기능
- **gstApp v1.2**
  - 워커 쓰레드 기반 비동기 캡처
  - Request Queue로 연속 캡처 명령 처리
  - 캡처 인덱스 계산 개선
  - 메인 루프 최적화

- **ext4 안정화**
  - ext4 커밋 주기 최적화
  - ext4_downgrade.sh, chk_filesystem.sh, file_manager.sh 추가

- **SD 복구 전략 변경**
  - v0.5.5 자동 fsck 제거 (시스템 불안정)
  - SD 마운트 실패 시 `/dev/shm` 자동 폴백
  - edgeconf tmp_path 자동 변경

- **ORD v4.7**
  - `err_send_period` 설정 추가

### 🔧 개선
- .video.tmp 파일 처리
- 캡처 큐 race condition 해결
- journald 정리 개선
- realtime muxer(ts/fmp4) 개선

### 📊 컴포넌트
- gstApp: v1.2 | ORD: v4.7
- 배포일: 2026-01-09

---

## 📦 v0.5.6.1 (2025-10-28 ~ 2025-11-26)

### 🔥 핵심
**ext4 마운트 최적화 + journald 통합 로깅**

### ✨ 신규 기능
- **ext4 최적화**
  - 동적 파일시스템 감지 (FAT32/ext4/exfat)
  - ext4: commit=60, data=writeback 등
  - 읽기 전용 모드 지원

- **journald 시스템**
  - 스냅샷 기능 (MMC 저장)
  - RAM 크기 제한
  - rsync 설정

- **시스템 개선**
  - timer → crontab 전환
  - 기본 타임존 KST
  - fake-hwclock 로그 지원

### 🔧 개선
- 로그 레벨 INFO (전체 앱)
- SD 마운트 플래그 개선
- fsck 잔여 파일 정리

### 📊 컴포넌트
- 배포일: 2025-11-26

---

## 📦 v0.5.5 (2025-09-23 ~ 2025-10-28)

### 🔥 핵심
**ORD v4.6 + 시스템 안정성 강화**

### ✨ 신규 기능
- **ORD v4.6**
  - 이벤트 복사 시간 예측: `evt_copy_delay = (max_bps/1024) * recMinute`
  - SD 읽기 전용 자동 복구 ⚠️ (v0.5.7 제거)

- **RTC 개선**
  - RTC 빠른 로딩
  - fake-hwclock 추가

- **카메라 기능**
  - streamApp 회전 기능 재활성화 (0°, 90°, 180°, 270°)
  - i2c 하드웨어 rotate_bit 제어

### 🔧 개선
- gstApp 카메라 설정 타이밍
- JQ 파서 boolean 기본값 수정

### 🐛 버그 수정
- ORD SD 카드 버그
- JQ 파서 boolean 버그

### 📊 컴포넌트
- ORD: v4.6
- 배포일: 2025-10-28

---

## 📦 v0.5.4 (2025-07-01 ~ 2025-09-22)

### 🔥 핵심
**gstApp v1.0 → v1.1 개발, TS Muxer, SD 서비스**

### ✨ 신규 기능

**Phase 1: Capture + TS Muxer (07-15 ~ 07-22)**
- gstApp Capture 개발 (타임아웃, 응답, MP4/TS muxer)
- streamApp v2.4, PIMCAM v2.0 (TS muxer)
- ord v4.5 (장비 12853, 12855)
- /tmp tmpfs 마운트


**Phase 2: gstApp v1.0 (07-30)**
- Turbojpeg 구현 (libturbojpeg 2.0.3)
- Combined/Dual encoder
- SD 마운트 체크 → RAM 폴백
- 데몬 통합 (automnt_sd, imx8-media-dev)

**Phase 3: 인코더 설정 기능 (08-27 / v0.5.4.1 테스트)**
- edgeconf 인코더 선택 (JPEG, Turbo, RAW)
- 캡처 품질 조절 (0~100)
- Combined 인코더 모드

**Phase 4: gstApp v1.1 정식 출시 (09-18 ~ 09-22)**
- 스트림 watchdog
- 카메라 설정 타이밍 최적화
- sd-mount.service 추가
- v0.5.4.1 인코더/품질 설정 기능 정식 포함

### 🔧 개선
- 캡처 응답 지연 감소
- 로깅 레벨 INFO
- 네트워크 서비스 (링크 속도, sFTP_UDP)

### 📊 컴포넌트
- gstApp: v1.0 → v1.1 (v0.5.4.1 테스트 버전 포함)
- streamApp: v2.4
- PIMCAM: v2.0
- ord: v4.5
- 배포일: 2025-07-01 ~ 2025-09-22
- Base Commit: 9585a4b6

---

## 📈 버전별 통계

| 버전 | 기간 | 커밋 수 | 주요 키워드 |
|------|------|---------|------------|
| v0.5.7 | 2025-12-01~2026-01-09 | 12 | 비동기 캡처, ext4 안정화 |
| v0.5.6.1 | 2025-11-14~26 | 11 | ext4 최적화, journald |
| v0.5.5 | 2025-09-23~10-28 | 8 | ORD v4.6, RTC, 회전 |
| v0.5.4 | 2025-07-01~09-22 | 23 | gstApp v1.0→v1.1, TS, 인코더 |

---

## 🔄 마이그레이션 가이드

### v0.5.6 → v0.5.7
**필수 작업**
```json
// ORD 설정에 추가
{
  "err_send_period": 60
}
```
- gstApp 비동기 동작 테스트
- SD 자동 복구 제거됨 (수동 도구 사용)

### v0.5.5 → v0.5.6
**권장: ext4 SD 카드 사용**
- ext4 최적화 마운트 옵션 적용
- journald 커스텀 설정 백업
- FAT32/exfat도 계속 사용 가능

### v0.5.4 → v0.5.5
- ORD v4.6 설정 확인
- RTC 동작 확인
- 카메라 회전 설정 (필요시)

---

## 🎯 버전 흐름

```
v0.5.4 (Capture + encoder + muxer)
    ↓
v0.5.5 (안정성)
    ↓
v0.5.6 (ext4 + 로깅)
    ↓
v0.5.7 (비동기 캡처)
    ↓
v0.5.8 (보안 + 녹화 동기화 + V4L2 + 드라이버) ← 현재
```

---

## 👥 기여자
- **hwjo** -

---

**문서 작성일**: 2026-01-23
**Base Commit (v0.5.4)**: 9585a4b6845025192fc3d35ab194f59e5210ef4e
**HEAD Commit (v0.5.7)**: 4023034e96f25fd4bbb4d3efb05cff984fdfb4d2
