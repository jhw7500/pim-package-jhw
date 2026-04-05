# ord 프로젝트 가상 환경 검증 지침서

이 문서는 QEMU 에뮬레이터를 사용하여 `ord` 바이너리의 로직을 검증하기 위한 표준 절차를 정의합니다.

## 1. 개요
*   **목표**: 디스크 관리 로직, 설정 동적 로딩, TCP 명령 인터페이스 검증.
*   **환경**: QEMU User-mode (qemu-aarch64) + i.MX8 SDK Sysroot.

## 2. 검증 환경 구축
`ord`는 가상 환경 대응을 위해 `/tmp/shared_v` 경로를 Fallback으로 사용합니다.
```bash
mkdir -p /tmp/shared_v
cp ref/*.json /tmp/shared_v/
```

## 3. 자동 테스트 실행
`tests/ord_auto_test.py`를 통해 자동으로 검증을 수행합니다.
```bash
python3 projects/pim-package/ord/tests/ord_auto_test.py
```

## 3.1 OHT 시뮬레이터 기반 자동 테스트
실제 OHT 장비/시뮬레이터가 없는 환경에서는 `tests/oht_simulator.py`를 함께 사용하여
`GET_CONFIG` 요청/응답을 자동으로 검증할 수 있습니다.

```bash
python3 projects/pim-package/ord/tests/ord_auto_test.py
```

참고: `ord_auto_test.py`는 기본 테스트 케이스에서 OHT 시뮬레이터를 자동으로 실행합니다.

## 4. 주요 검증 항목
*   **Config Fallback**: `/root/shared_v` 접근 실패 시 `/tmp/shared_v`에서 설정을 정상적으로 읽어오는지 확인.
*   **Port Binding**: `ord_vcm_conf.json`에 설정된 포트(10007 등)로 서버가 정상 기동되는지 확인.
*   **TCP Interface**: `GET_CONFIG` 요청에 대해 올바른 시스템 상태 정보를 JSON으로 응답하는지 확인.

---
*마지막 업데이트: 2026-02-06*
