# Camera health v1 deployment compatibility

세 저장소를 동시에 교체할 수 없으므로 producer capability와 legacy fallback을 명시한다.

## capability

| component | v1 capability | rollout 동안 유지할 legacy surface |
|---|---|---|
| max9296 | read-only health snapshot/sysfs, sequence | 기존 `link_status` |
| gstApp | atomic health JSON, source/encoder/recording counters | 기존 `/tmp` marker와 error flag |
| pim-package | v1 parser/aggregator/shadow compare | 기존 channel bit와 retry ladder |

consumer는 v1 파일이 없거나 schema/boot ID/TTL 검증에 실패하면 legacy 값을 v1 정상
evidence로 위조하지 않는다. shadow 상태를 `UNKNOWN/legacy-only`로 기록하고 실제 운용은
rollback 기간 동안 legacy owner가 계속 담당한다.

## 허용 조합

| max9296 | gstApp | PIM | 허용 동작 |
|---|---|---|---|
| legacy | legacy | legacy | 현재 동작 |
| v1+legacy | legacy | legacy | health ABI 미사용, 현재 동작 |
| legacy | v1+legacy | legacy | health JSON 미사용, 현재 동작 |
| v1+legacy | v1+legacy | PIM shadow | 상세 상태 비교만, legacy가 판정/복구 소유 |
| v1+legacy | v1+legacy | PIM v1 recovery | fault matrix/soak 통과 뒤에만 허용 |

PIM v1 recovery와 legacy-only max9296 또는 gstApp 조합은 production에서 허용하지 않는다.
package dependency/capability gate가 recovery enable을 거부해야 한다.

## 배포 순서

1. PIM boot config producer를 additive 배포하고 `/tmp/config/READY`만 검증한다.
2. max9296 v1 관측 ABI를 배포하되 legacy `link_status`를 유지한다.
3. gstApp v1 producer를 배포하되 legacy marker를 유지한다.
4. PIM shadow consumer와 legacy/v1 comparator를 비활성 상태로 배포한다.
5. 7일 soak 또는 fault matrix 100회 후 판정권을 전환한다.
6. recovery는 gstApp→module→hard-reset 순서로 별도 enable한다.
7. 한 릴리스 rollback 기간 뒤에만 legacy surface 제거를 검토한다.

## rollback gate

- v1 recovery flag off는 legacy retry owner가 아직 남아 있을 때만 즉시 rollback이다.
- `/tmp/config` 고정 consumer를 legacy shared reader로 되돌리는 것은 다음 boot에서만 한다.
- max9296/gstApp producer downgrade 시 PIM recovery capability를 자동 disable한다.
- rollback 성공은 PID/cgroup, config source, legacy flag owner를 검사해 판정한다.
