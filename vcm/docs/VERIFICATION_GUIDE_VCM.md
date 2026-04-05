# vcm 프로젝트 가상 환경 검증 지침서 (V1.0)

이 문서는 QEMU 에뮬레이터를 사용하여 `vcm` 바이너리의 로직과 안정성을 검증하기 위한 표준 절차를 정의합니다. 이 지침은 향후 `pim-package` 전체 통합 검증 체계로 확장될 예정입니다.

## 1. 개요
*   **목표**: 타겟 하드웨어(i.MX8MP) 없이 호스트 환경에서 `vcm`의 핵심 로직(비동기 I/O, 시간 동기화, 설정 로딩)을 검증.
*   **환경**: QEMU User-mode (qemu-aarch64) + i.MX8 SDK Sysroot.

## 2. 검증 환경 구축 (Environment Setup)

### 2.1 로컬 설정 디렉토리 준비
`vcm`은 `/root/shared_v`에 접근할 수 없는 경우 `./shared_v` (로컬) 경로를 자동으로 찾습니다.
```bash
mkdir -p shared_v
cp ../ref/*.json ./shared_v/
```

### 2.2 가상 루트 및 로그 경로
필요 시 가상 루트 구조를 생성하여 에뮬레이션 환경을 실제 보드와 유사하게 맞춥니다.
*   로그 경로: `/var/log/cantops` (호스트의 사용자 권한 필요)
*   임시 경로: `/tmp`

## 3. 지능형 경로 폴백 (Smart Path Fallback) 검증
`vcm`에 도입된 경로 자동 전환 로직이 정상 작동하는지 확인합니다.
1.  `/root/shared_v` 접근 실패 시 로그에 `[WARNING] Cannot access /root/shared_v...` 가 출력되는지 확인.
2.  이후 `Fallback path selected: ./shared_v` 로그와 함께 설정 로딩이 이어지는지 확인.

## 4. 실행 및 런타임 테스트

### 4.1 실행 명령어
```bash
qemu-aarch64 -L /shared/fsl-imx-xwayland/5.10-hardknott/sysroots/cortexa53-crypto-poky-linux ./vcm
```

### 4.2 주요 체크리스트
- [ ] **초기화**: `version : 4.3` 로그 출력 여부.
- [ ] **설정 로드**: JSON 파일 파싱 및 `TVhlConf` 구조체 초기화 성공 여부.
- [ ] **비동기 워커**: `file writer thread start` 로그와 함께 스레드 생성 확인.
- [ ] **네트워크**: 지정된 포트(10009) 수신 대기 상태 진입 확인.

## 5. 심화 기능 검증 (Advanced Testing)

### 5.1 TCP 인터페이스 테스트
`vcm`에 접속하여 JSON 명령어를 주고받으며 응답을 확인합니다.
*   **연결 테스트**: `nc localhost 10009`
*   **설정 조회**: `{"REQ":"GET_CONFIG"}` 입력 후 JSON 응답 확인.
*   **오버레이 제어**: `{"REQ":"SET_OVERLAY_START"}` 명령어 전송 후 데이터 스트림 수신 확인.

### 5.2 IPC 및 SRT 생성 테스트
제공된 `vcm_simulator.py`를 사용하여 `ord`의 신호를 시뮬레이션합니다.
*   **데이터 주입**: 시뮬레이터가 0x64 메시지 큐에 데이터를 밀어넣음.
*   **SRT 확인**: `/tmp/` 또는 설정된 임시 경로에 `*.srt.part` 파일이 실시간으로 생성되고 내용이 갱신되는지 확인.
*   **비동기 I/O 확인**: 디스크 쓰기 부하 상황에서도 `vcm` 메인 루프 지연 여부 체크.

### 5.3 Redis 및 OPS 데이터 연동 테스트
`vcm`이 Redis 서버에서 OPS 데이터를 가져와 처리하는지 검증합니다.
*   **사전 준비**: 호스트에서 Redis 서버 실행 (`redis-server`).
*   **데이터 주입**: `python3 vcm_simulator.py redis` 실행.
*   **검증 내용**: 
    *   `vcm` 로그에 `[RDS] tag : ..., offset : ...` 정보가 출력되는지 확인.
    *   SRT 파일 및 TCP 오버레이 스트림에 해당 OPS 정보(태그와 오프셋)가 실시간 반영되는지 확인.

## 6. 자동화된 통합 테스트 (Automated Testing)
`tests/vcm_auto_test.py`를 사용하여 설정값 변경부터 런타임 검증까지 자동으로 수행합니다.

### 6.1 실행 방법
*   **기본 테스트 (빠름)**: 포트 바인딩 및 기본 실행 상태만 검증 (약 5초 소요)
    ```bash
    python3 projects/pim-package/vcm/tests/vcm_auto_test.py
    ```
*   **심화 테스트 (권장)**: 실제 SRT 파일 생성 여부까지 완벽하게 검증 (약 80초 소요)
    ```bash
    python3 projects/pim-package/vcm/tests/vcm_auto_test.py --deep
    ```

### 6.2 자동 검증 항목
*   **Dynamic Port Binding**: `ord_vcm_conf.json`의 `port_num` 변경 시 해당 포트가 정상적으로 열리는지 확인.
*   **VHL Name Sync**: `edgeconf_pim.json`의 `vhl_name` 변경 시 생성되는 SRT 파일명이 올바르게 바뀌는지 확인.
*   **Runtime Stability**: 여러 테스트 케이스를 연속 실행할 때 프로세스 충돌이나 자원 누수가 없는지 확인.

## 7. 향후 확장 계획
*   **ord 검증**: `vcm`과 `ord` 간의 Message Queue(IPC) 연동 테스트 추가.
*   **gstApp 연동**: 실제 GStreamer 라이브러리 의존성 해결 및 파이프라인 제어 로직 검증.
*   **통합 검증**: `pim-package` 내의 모든 바이너리를 가상 네트워크로 연결하여 시뮬레이션.

---
*마지막 업데이트: 2026-02-06*
