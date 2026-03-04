# SD 카드 마운트 udev 시그널 연동 설계 (Draft)

## 1. 개요
현재 `automnt_sd_for_emmc_boot.sh`는 3초 주기로 SD 카드의 상태를 체크(Polling)하고 있습니다. 이 방식은 카드가 제거된 후 최대 12초(3초 * 4회 확인)의 지연 시간이 발생하며, 이 기간 동안 커널 I/O 행업이 발생할 위험이 있습니다. 이를 해결하기 위해 커널의 `udev` 이벤트를 감지하여 즉시 스크립트를 깨우는(Wake-up) 방식을 제안합니다.

## 2. 기존 방식의 한계
- **지연 시간:** 3초 주기의 루프로 인해 즉각적인 대응이 어려움.
- **I/O Hang:** 카드가 뽑힌 직후부터 감지 시점 사이의 데이터 쓰기 시도가 시스템 성능 저하 유발.

## 3. 시그널 기반 연동 설계

### 3.1 udev 규칙 설정
`/etc/udev/rules.d/99-sd-card.rules` 파일을 생성하여 SD 카드의 삽입/제거 이벤트를 감지합니다.

```udev
# SD 카드 제거 시 시그널 전송
ACTION=="remove", SUBSYSTEM=="mmc", KERNEL=="mmcblk1p1", RUN+="/usr/bin/pkill -SIGUSR1 -f automnt_sd_for_emmc_boot.sh"

# SD 카드 삽입 시 시그널 전송
ACTION=="add", SUBSYSTEM=="mmc", KERNEL=="mmcblk1p1", RUN+="/usr/bin/pkill -SIGUSR1 -f automnt_sd_for_emmc_boot.sh"
```

### 3.2 스크립트 수정 방향 (`automnt_sd_for_emmc_boot.sh`)
스크립트 내부에 `trap` 명령을 추가하여 `SIGUSR1` 신호를 받으면 현재의 `sleep`을 즉시 종료하고 루프의 다음 단계(상태 체크)를 실행하도록 합니다.

#### 변경 예시 (Conceptual):
```bash
# SIGUSR1 신호를 받으면 아무 작업도 하지 않고(continue) sleep을 깨움
handler() {
    logger -p local0.notice "[$KEY][$TAG] udev signal received, checking status immediately..."
}
trap 'handler' SIGUSR1

while true; do
    case $mnt_state in
        # ... 기존 로직 ...
    esac
    
    # sleep 중에 신호가 오면 즉시 종료됨
    sleep 3 & wait $!
done
```

## 4. 기대 효과
1. **즉각적인 반응:** udev가 이벤트를 감지하는 즉시(1초 미만) `umount -l` 및 `fallback` 로직이 실행됩니다.
2. **충돌 방지:** 마운트 로직은 기존 스크립트 하나에서만 관리되므로 `udev`와 스크립트 간의 레이스 컨디션(Race Condition)이 발생하지 않습니다.
3. **안전성:** `udev` 서비스가 중단되더라도 기존의 3초 주기 폴링 로직이 안전장치(Fallback)로 계속 작동합니다.

## 5. 추후 작업 순서
1. 현재의 3초 폴링 방식 안정성 검토.
2. `/etc/udev/rules.d/` 설정 적용 및 테스트.
3. 스크립트에 `trap` 및 `wait` 로직 적용.
