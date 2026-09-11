# ord 프로젝트 가상 환경 검증 지침서

이 문서는 QEMU 에뮬레이터를 사용하여 `ord` 바이너리의 로직을 검증하기 위한 표준 절차를 정의합니다.

## 1. 개요
*   **목표**: 디스크 관리 로직, 시작 시 runtime 설정 로딩, TCP 명령 인터페이스 검증.
*   **환경**: QEMU User-mode (qemu-aarch64) + i.MX8 SDK Sysroot.

## 2. 검증 환경 구축
`ord`는 프로세스 시작 시 `/run/pim-camera/config/pim_runtime.json`을 한 번 읽고
설정값을 메모리에 보관합니다. QEMU에서도 프로세스가 보는 같은 경로에 병합된
runtime fixture를 준비해야 합니다. 루트와 `VHL_CAM`, `ORD`, `VCM`은 모두 JSON
object여야 합니다. 파일 누락, 읽기/파싱 실패, 필수 object 누락/타입 오류는 고정
경로를 로그에 남기고 설정 로딩을 실패시킵니다. 원본 검색이나 로컬 fallback은 없습니다.

설정 적용 경계는 다음과 같습니다. 자동 hot reload는 하지 않습니다.

| 변경 영역 | 새 값을 읽기 위해 필요한 재시작 |
| --- | --- |
| `ORD` | ORD |
| `VCM` | VCM |
| `VHL_CAM` | ORD와 VCM 모두 (관리 apply에서는 gstApp도 재시작) |

수동 runtime 편집은 JSON과 필수 object를 검증한 뒤 선택한 프로세스를 재시작해
시험할 수 있습니다. 이때 다른 프로세스가 이전 값을 사용하는 혼합 상태는 수동
시험에만 허용합니다. cam-operate 재시작 또는 성공한 `apply-config`는 원본에서
runtime을 다시 만들어 수동 편집을 덮어씁니다. 영구 변경은 원본 JSON에 적용합니다.

## 3. 자동 테스트 실행
`tests/ord_auto_test.py`를 통해 자동으로 검증을 수행합니다.
기존 QEMU 테스트의 원본 fixture 준비만으로는 runtime을 만들 수 없습니다.
해당 테스트를 사용할 때는 위 고정 경로에 병합 fixture를 준비하고 각 설정 변경 뒤
프로세스를 재시작해야 합니다. 보드 없이 실행하는 현재 경로/검증/해제 계약 검사는
저장소 루트에서 `python3 test/camera_health/native_runtime_config_test.py`로 실행합니다.
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
*   **Runtime Config**: 단일 runtime 문서의 필수 object를 검증하고 한 번 읽는지, 잘못된 입력이 설정 로딩 실패로 끝나는지 확인.
*   **Port Binding**: runtime의 `ORD.port_num`에 설정된 포트(10007 등)로 재시작한 서버가 정상 기동되는지 확인.
*   **TCP Interface**: `GET_CONFIG` 요청에 대해 올바른 시스템 상태 정보를 JSON으로 응답하는지 확인.

---
*마지막 업데이트: 2026-09-09*
