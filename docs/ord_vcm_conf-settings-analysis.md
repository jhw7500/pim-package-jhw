# `ord_vcm_conf.json` 현행 설정 분석

> 기준: 2026-08-25 GitHub `master`. 변하기 쉬운 행 번호 대신 설정 키와 소비자
> 함수명을 기준으로 설명한다.

## 1. 설정 파일과 정본 관계

| 구분 | 경로/소유자 | 역할 |
|---|---|---|
| 패키지 기본 파일 | `dist/pim/opt/pim/config/ord_vcm_conf.json` | 새 설치와 패키지에 포함되는 기본값 |
| 운영 파일 | `/root/shared_v/ord_vcm_conf.json` | 단말에서 실제로 읽는 설정 |
| 보강 스크립트 | `dist/pim/opt/pim/bin/update_ordvcmconf.sh` | 일부 누락 키를 운영 파일에 추가 |
| ORD 소비자 | `ord/tcpServer.cpp` | `ORD`, 일부 `VCM`, `edgeconf_pim.json`의 `VHL_CAM` 사용 |
| VCM 소비자 | `vcm/tcpServer.cpp` | `VCM`, 일부 `ORD`, `edgeconf_pim.json`의 `VHL_CAM` 사용 |
| 감시 스크립트 | `chk_cam_operate.sh`, `BG_Check_for_pim.sh` | `ETC`와 카메라 복구 설정 사용 |

GitHub `master`의 코드가 동작 정본이다. 이 문서의 “패키지 값”은 배포 템플릿의
값이고, 키가 없을 때 프로그램 내부에서 사용하는 fallback과 같다는 뜻은 아니다.

## 2. ORD 그룹

| 키 | 패키지 값 | 주요 효과 |
|---|---:|---|
| `vhl_max` | `1` | VHL 클라이언트 최대 연결 수 |
| `event_auto_remove` | `true` | 이 파일의 값은 ORD 동작에 사용되지 않음. 아래 “설정 위치 주의” 참조 |
| `copy_margin_sec` | `10` | 이벤트가 녹화 구간 초입/중간/말미인지 나누는 여유시간(초) |
| `debug_level` | `0` | 디버그 로그 수준 |
| `log_level` | `5` | 로그 수준 |
| `ip_static` | `""` | ORD 설정 구조체에 로드되는 정적 IP 문자열 |
| `port_num` | `10007` | ORD TCP 포트 |
| `disk_manage` | `true` | 디스크 관리 스레드 활성화 |
| `target_copy` | `true` | 이벤트 타깃 복사 활성화 |
| `rtc_reset` | `true` | 이벤트 경로의 RTC/카메라 리셋 정책 |
| `disk_limit_per` | `90` | 패키지·보강 스크립트가 강제하는 디스크 사용률 임계값(%) |
| `disk_limit_file` | `1000` | 디스크 파일 수 임계값 |
| `disk_manage_period` | `40` | 디스크 관리 주기(초) |
| `ovl_buffering` | `0` | 오버레이 큐 버퍼 설정 |
| `vib_enable` | `false` | 진동 데이터 처리 활성화 |
| `evt_copy_delay` | `15` | 이벤트 복사 전 추가 지연(초) |
| `err_send_period` | `180` | 에러 상태 전송 주기(초). `0`이면 주기 전송 비활성 |

`init_json_config()`의 내부 fallback 중 `disk_limit_per=95`,
`err_send_period=0`은 패키지 값과 다르다. 정상 운영에서는 JSON이 로드되므로
패키지 값 `90`, `180`이 적용된다. 설정 파일 로드 자체가 실패하면 ORD는 오류를
반환하므로 내부 초기값만 보고 정상 운용값으로 간주하면 안 된다.

## 3. VCM 그룹

| 키 | 패키지 값 | 주요 효과 |
|---|---:|---|
| `debug_level` | `0` | 디버그 로그 수준 |
| `log_level` | `5` | 로그 수준 |
| `ip_static` | `""` | VCM 설정 구조체에 로드되는 정적 IP 문자열 |
| `port_num` | `10009` | VCM TCP 포트 |
| `srt_enable` | `true` | SRT 파일 생성과 세션 완료 조건 활성화 |
| `srt_auto_sync` | `true` | 자동 시간 동기화 사용 |
| `srt_test` | `false` | SRT 테스트 동작/로그 |
| `srt_period` | `500` | SRT 루프 주기(ms) |
| `srt_delay` | `0` | SRT 처리 지연(ms) |
| `srt_set_index` | `1` | SRT 큐 처리 인덱스 기준 |
| `srt_buffering` | `0` | SRT 큐 버퍼 임계값 |
| `file_time_check` | `true` | 현재 설정 로그에 노출되는 파일 시간 플래그 |
| `ops_enable` | `false` | OPS 데이터 처리 활성화 |
| `ops_period` | `500` | OPS 루프 주기(ms) |
| `ops_buffering` | `0` | OPS 큐 버퍼 임계값 |
| `ops_delay` | `0` | OPS 처리 지연(ms) |
| `vib_test` | `false` | 진동 데이터 테스트 모드 |

`vcm`의 `init_json_config()`는 `srt_enable=FALSE`로 시작한 뒤 JSON의 명시값을
읽는다. 따라서 패키지 기본 파일을 정상 로드하면 `true`지만, 키 누락 시에는
`false`가 유지된다. gstApp parser와 `chk_cam_operate.sh`도 누락을 `false`로
해석한다. 운영 파일에는 `true` 또는 `false`를 명시한다.

## 4. ETC 그룹

`ETC`는 주로 셸 스크립트에서 `jq`로 읽는다.

| 키 | 패키지 값 | 소비 시 fallback | 효과 |
|---|---:|---:|---|
| `file_check_delay` | `10` | `10` | 시작 파일 검사 유예와 파일 미생성 타임아웃에 사용 |
| `file_check_reboot` | `true` | `false` | 복구 사다리의 마지막 reboot 단계 허용 |
| `startup_grace_extra_sec` | `10` | `10` | 시작 grace와 FINAL STALL 워밍업에 추가 |
| `init_cooldown_sec` | `40` | `40` | `init_cam.sh` 직후 재초기화 억제 |
| `disconnect_init_interval_sec` | `180` | `180` | disconnect 중 주기적 `init_cam.sh` 간격 |
| `disconnect_init_grace_sec` | `60` | `60` | disconnect 후 첫 `init_cam.sh` 전 유예 |
| `disconnect_max_sec` | 키 없음 | `0` | 선택적 장기 disconnect reboot. `0`이면 비활성 |

`update_ordvcmconf.sh`는 앞의 6개 패키지 키를 보강하지만
`disconnect_max_sec`는 추가하지 않는다. 이 키는 필요한 장비에서만 명시적으로
설정하는 opt-in 정책이다.

`file_check_reboot=false`는 retry 카운터를 무기한 유지한다는 뜻이 아니다.
kill/init 복구는 계속 수행하며 한계에 도달하면 일반 retry 카운터 또는
`final_stall_cnt`를 초기화하고 복구 사다리를 다시 시작한다. 현재 제어하는 5개
재부팅 분기와 정확한 임계값은
[`file_check_reboot-behavior.md`](./file_check_reboot-behavior.md)를 따른다.

`GetConfig_()`의 현재 ETC 관련 로딩 항목은 다음과 같다.

```bash
(.ETC.file_check_reboot // false)
(.ETC.file_check_delay // 10)
(.ETC.startup_grace_extra_sec // 10)
(.ETC.init_cooldown_sec // 40)
(.ETC.disconnect_init_interval_sec // 180)
(.ETC.disconnect_init_grace_sec // 60)
(.ETC.disconnect_max_sec // 0)
```

숫자 설정이 비어 있거나 숫자가 아니면 `_cfg_num()`이 선언된 fallback으로
되돌린다. 불리언 값이 비어 있으면 비활성으로 판정한다. 설정은
`chk_cam_operate.sh` 시작 시 읽으며 실행 중 JSON을 자동 reload하지 않는다.

## 5. `evt_copy_delay` 동작

ORD는 이벤트 복사 지연을 초 단위로 사용한다. 기본 식은 다음과 같다.

```text
초입/중간: recording_time*60 - diff + evt_copy_delay
말미:      recording_time*60*2 - diff + evt_copy_delay
```

`tmp_path`와 mount 경로가 다르면 로드 후
`(max_bps/1024) * recording_time`을 `evt_copy_delay`에 추가한다. 즉 JSON 값은
경로 간 복사 비용을 반영하기 전 기본 지연이다.

## 6. 설정 위치 주의

`ORD.event_auto_remove`는 `ord_vcm_conf.json`에서 파싱되지 않는다. 실제 ORD
디스크 자동 삭제와 복사 거절 로직은 `edgeconf_pim.json`의
`VHL_CAM.event_auto_remove`를 사용한다. 이 키를 바꾸려면 운영 edge 설정을
변경해야 한다.

`VCM.file_time_check`는 현재 분기 제어가 아니라 설정 로그에 사용된다. 동작을
바꾸는 핵심 스위치로 해석하지 않는다.

## 7. 변경 및 검증 절차

1. 운영 JSON을 백업하고 `jq -e .`로 문법을 확인한다.
2. 변경 키의 소비자가 ORD, VCM, 감시 셸 중 어디인지 확인한다.
3. 승인된 배포 절차로 설정을 반영한다.
4. 관련 프로세스를 재기동한다. 특히 `srt_enable`은 vcm과 gstApp을 함께
   재기동해야 세션 마커 계약이 일치한다.
5. 시작 로그의 실제 로드값과 운영 JSON을 대조한다.

```bash
jq '{ORD,VCM,ETC}' /root/shared_v/ord_vcm_conf.json
jq '.VCM.srt_enable, .ETC.file_check_reboot, .ETC.disconnect_max_sec' \
  /root/shared_v/ord_vcm_conf.json
```

FINAL STALL과 세션 마커 관련 영향은
[`session-lifecycle.md`](./session-lifecycle.md)와
[`runbook_final_stall.md`](./runbook_final_stall.md)를 함께 확인한다.
