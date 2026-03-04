# tmp_path(/dev/shm) 용량 관리 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** gstApp 비정상 종료 시 tmp_path(/dev/shm)에 남는 고아 파일을 정리하고, 예상치 못한 파일 누적에도 RAM 소진을 방지하는 2단계 방어 체계를 구축한다.

**Architecture:** 기존 정리 로직(`CleanupStalePartFiles`, `ProcessCompletedSessions`, `enforce_ram_cap_if_needed`)은 변경하지 않는다. `init_cam.sh`에서 `kill_test.sh` 완료 후 `start_cam.sh` 호출 직전에 2단계 정리를 수행한다. 1단계는 녹화 확장자(.mp4/.ts/.srt) 고아 파일 삭제, 2단계는 /dev/shm 용량 임계값 초과 시 보호 대상을 제외한 모든 파일을 mtime 오래된 순으로 삭제한다.

**Tech Stack:** Bash, 기존 init_cam.sh

---

## 문제 분석

### 고아 파일 발생 시나리오
1. gstApp이 `.part` → `.mp4` 리네임 완료 (splitmuxsink 자동)
2. `session_*.all_done` 마커 생성 전에 비정상 종료
3. 해당 파일은 기존 어떤 정리 루틴에도 해당하지 않음

### /dev/shm 사용 구조 (2.8GiB 할당)

| 경로 | 용도 | 관리 주체 |
|---|---|---|
| `/dev/shm/*.mp4.part` 등 | 녹화 tmp | `CleanupStalePartFiles` |
| `/dev/shm/recordings/` | RAM-only final_path | `enforce_ram_cap_if_needed` |
| `/dev/shm/capture/` | 캡처 파일 | 별도 프로세스 (이벤트 기반) |
| `/dev/shm/sd_mount_flag` 등 | 시스템 플래그 | 각 스크립트 |

### 정리 시점: init_cam.sh
- `kill_test.sh` 실행 후 gstApp 확실히 종료된 상태
- 드라이버 재초기화(rmmod/modprobe) 완료 후
- `start_cam.sh` 호출 직전 → 새 녹화 시작 전 깨끗한 상태 보장
- 타이밍 경합 없음

---

## Task 1: `init_cam.sh`에 2단계 정리 함수 추가

**Files:**
- Modify: `projects/pim-package/dist/pim/opt/pim/bin/init_cam.sh`

### 변경 내용

1. 스크립트 상단(source 직후)에 정리 함수 2개 추가
2. `start_cam.sh` 호출 직전(line 81)에 정리 호출 삽입

---

## Task 2: 테스트 스크립트 작성 및 실행

**Files:**
- Create: `projects/pim-package/test_init_cam_cleanup.sh`

---

## Task 3: release 디렉터리 동기화

**Files:**
- Modify: `projects/pim-package/release/pim/opt/pim/bin/init_cam.sh`

---

## 변경 영향도

| 기존 로직 | 영향 |
|---|---|
| `CleanupStalePartFiles` | 변경 없음 |
| `ProcessCompletedSessions` | 변경 없음 |
| `enforce_ram_cap_if_needed` | 변경 없음 |
| `MovePartFile` | 변경 없음 |
| `start_cam.sh` | 변경 없음 |
| `init_cam.sh` | 추가만 — start_cam.sh 호출 직전에 정리 함수 호출 |
