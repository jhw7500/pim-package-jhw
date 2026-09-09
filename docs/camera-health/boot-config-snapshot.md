# Camera runtime configuration ownership

## 역할 분리

`pim-camera-config.service`는 `pim-config-guard.service` 뒤에서 실행되는 prerequisite
guard다. 다음 조건만 확인한다.

- `/root/shared_v` source directory가 읽기 가능하다.
- 고정 source `ord_vcm_conf.json`이 읽기 가능한 regular file이다.
- `python3`, `jq`, `flock`, `logger`, boot ID가 사용 가능하다.

이 unit은 camera runtime directory를 만들거나 설정을 선택·병합하지 않는다.
`cam-operate.service`가 이 guard를 `Requires`하고 그 뒤에 시작한다.

## 단일 runtime

cam-operate는 시작할 때 `/root/shared_v`의 최신 regular `edgeconf_*.json`과 고정
`ord_vcm_conf.json`을 다시 읽는다. ord document 전체를 유지하면서 `VHL_CAM`은 선택한
edgeconf 값으로 교체하고, `VHL_CAM`, `ORD`, `VCM` object를 검증한다. 검증된 결과는
다음 한 파일로 원자 교체한다.

```text
/run/pim-camera/config/pim_runtime.json
```

`edgeconf_pim.json`과 `ord_vcm_conf.json`은 모두 이 파일을 가리키는 상대 symlink다.
`cam-operate.service`의 `RuntimeDirectory=pim-camera`가 invocation의 runtime lifetime을
소유하며 restart 사이 보존에 의존하지 않는다.

## 생성과 재적용 경계

source 검색과 runtime 생성은 다음 두 경로에서만 일어난다.

1. 새 cam-operate invocation의 startup 또는 service restart
2. 현재 invocation의 `cam-recoveryctl apply-config`

자동 health recovery, dead-process restart, legacy wrapper는 현재 runtime만 사용하며
source를 다시 검색하지 않는다. service restart는 source로 runtime을 다시 만들고 consumer를
모두 다시 시작하며 최소 module reload를 수행한다. hardware projection 변경 또는 dirty
상태에서는 hard reset을 수행한다.

## 실패와 수동 시험

최신 edgeconf나 고정 ord source가 없거나 invalid이면 과거 파일 또는 기존 runtime으로
후퇴하지 않는다. startup은 consumer 시작 전 실패한다. `apply-config` validation 실패는
현재 runtime과 process를 유지한다.

수동 시험은 같은 directory의 candidate를 검증한 뒤
`pim_runtime.json`으로 atomic rename하고 선택한 app만 재시작하는 방식으로 허용한다.
다른 process가 이전 값을 memory에 유지하는 일시적 혼합 상태를 감수해야 한다. 다음 성공한
`apply-config` 또는 cam-operate restart가 source 값으로 다시 덮어쓴다. 상세 절차와
exit-code 계약은 [`cam-recovery-operations.md`](./cam-recovery-operations.md)를 따른다.

## 권한

- `/run/pim-camera`와 config directory: mode `0750`
- runtime JSON: mode `0640`
- `/var/lib/pim-camera`: 재시작과 package lifecycle을 넘어 유지되는 state/history
- service owner: target의 root cam-operate invocation
