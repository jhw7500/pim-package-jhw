# Boot camera configuration snapshot

## 목적

`pim-camera-config.service`는 `pim-config-guard.service`가 검증·복구한 다음
canonical 설정 두 개를 boot당 한 번 `/tmp/config`에 publish한다.

- source: `/root/shared_v/edgeconf_pim.json`
- source: `/root/shared_v/ord_vcm_conf.json`
- destination: `/tmp/config/`
- commit marker: `/tmp/config/READY`
- diagnostic import record: `/tmp/config/boot_manifest.json`

Phase 0.5에서는 producer만 additive하게 배포한다. 기존 runtime consumer는 아직 shared
경로를 사용할 수 있으며, 각 consumer를 `/tmp/config`로 바꾸는 PR에서
`Requires/After=pim-camera-config.service`를 함께 추가한다.

비활성 shadow unit인 `camera-capture-probe.service`만 이 snapshot으로부터
`/run/pim-camera/config-expectation.json`을 먼저 생성한다. 이 경로는 IRQ 관측 범위를
정할 뿐 기존 camera start/stop/recovery에는 연결되지 않는다.

## transaction

1. boot ID와 canonical 두 JSON을 검증한다.
2. `/tmp/config/.staging-$boot_id.*`에 두 파일을 복사하고 다시 parse한다.
3. SHA-256 manifest와 READY 후보를 staging에 작성한다.
4. 이전 boot의 READY를 제거한다.
5. 두 JSON과 manifest를 rename한다.
6. READY를 마지막에 rename한다.

READY가 없거나 boot ID가 다르면 consumer는 snapshot을 사용하면 안 된다. 두 파일 publish
사이에 crash하면 READY가 없으므로 다음 bootstrap 실행이 전체 generation을 다시
publish한다.

## 같은 boot에서의 runtime override

현재 boot ID의 READY가 있으면 shared를 다시 읽지 않는다. `/tmp/config` JSON 자체가
유효하면 READY에 기록된 import hash와 현재 hash가 달라도 성공/no-op한다. 따라서
엔지니어의 atomic runtime 수정은 개별 app restart에서 사용할 수 있다.

현재 boot의 runtime JSON이 손상되면 shared에서 몰래 복구하지 않고 service가 실패한다.
전체 설정을 다시 일치시키려면 파일을 정상화한 뒤 명시적으로 cam-operate를 restart한다.
다음 boot에서는 config guard 이후 shared canonical 파일을 새로 import한다.

## 권한과 실패 처리

- directory mode: `0750`
- JSON/READY/manifest mode: `0640`
- target에서는 root service가 실행하므로 owner는 root다.
- `jq`, `sha256sum`, `flock`, boot ID 또는 canonical JSON이 없으면 non-zero 종료한다.
- service는 `Type=oneshot`, `RemainAfterExit=yes`다.
- Phase 0.5에서는 bootstrap 실패가 기존 shared reader를 차단하지 않는다. consumer 전환
  단계부터 해당 unit에 `Requires/After`를 추가하여 fail-closed로 바꾼다.
