# Camera block health fault matrix

보드가 사용 가능해지면 한 행마다 raw artifact와 판정 결과를 함께 저장한다.
자동 복구 enable 전 필수 입력 문서다.

## 공통 메타데이터

- 시험 ID / 일시 / 작업자
- 보드 HW revision, image/package version, kernel, boot ID
- edgeconf/ord_vcm_conf SHA-256
- single/independent/dual-wide mode와 configured mask
- 카메라 serial/물리 channel/link/CSI/video-node mapping
- 시험 전 `cam_fps_stack.sh` 결과
- 시험 전 PID/PPID/cgroup/V4L2 FD snapshot

## 시험표

| ID | 주입 | 필수 raw evidence | 기대 root block | recovery 허용 | 결과/첨부 |
|---|---|---|---|---|---|
| B01 | 정상 전체 연결 | DES ID, RX3, SER/AP1302/AR0234, HINF, CSI2, capture | none | none | TBD |
| B02 | dual ch0 케이블 제거 | 최초 RX3 edge, pair RX3, HINF, CSI2/ISI/GST | gmsl_link(ch0) | camera-domain | TBD |
| B03 | dual ch1 케이블 제거 | B02와 동일 | gmsl_link(ch1) | camera-domain | TBD |
| B04 | 같은 pair 양쪽 제거 | RX3 raw와 origin confidence | gmsl_link(pair) | camera-domain | TBD |
| B05 | 케이블 재연결, reset 전 | RX3 up edge, default/remapped SER ACK, AP1302 ACK | PRESENT_UNINITIALIZED 여부 | bounded init only | TBD |
| B06 | MAX9296 local I2C 실패 | DES ID + 독립 CSI/capture evidence | deserializer(control) | module/hard | TBD |
| B07 | DES MIPI config 실패 | CTRL3/MIPI readback + CSI2 | deserializer(dataplane) | module/hard | TBD |
| B08 | RX3 up, 모든 remote NAK | SER/AP1302/AR0234 transaction 결과 | ambiguous GMSL/SER | no immediate destructive | TBD |
| B09 | AP1302 ACK, SER ID만 실패 | 두 병렬 branch 결과 | serializer | camera-module/domain | TBD |
| B10 | SER 정상, AP1302 NAK | SER ID/config + AP1302 result | isp | camera-module/domain | TBD |
| B11 | HINF 정지, sensor static 정상 | HINF windows + static readback | ambiguous sensor/ISP | no immediate destructive | TBD |
| B12 | HINF 증가, CSI2 IRQ 정지 | HINF/DES MIPI/CSI IRQ | csi2 | capture-domain hard reset | TBD |
| B13 | CSI2 증가, v4l2src 없음 | IRQ + quiesced STREAMON/DQBUF | capture or gstreamer | identification first | TBD |
| B14 | source 증가, encoder 정지 | pad counters/bus error | gstreamer | app restart | TBD |
| B15 | SD read-only/full/unmounted | fragment/source/storage errno | recording | no camera reset | TBD |
| B16 | module reload 100회 | refcount, sysfs worker, nodes, frame progress | none | test only | TBD |
| B17 | hard reset 100회 | cam MainPID/counter + HINF/CSI/GST | none | test only | TBD |

## 재연결 trigger 결정란

| evidence | detach | reconnect/reset 전 | 안정 반복 횟수 | trigger 사용 여부 |
|---|---:|---:|---:|---|
| RX3 link-specific transition | TBD | TBD | TBD | TBD |
| CTRL3 aggregate lock | TBD | TBD | context only | no |
| MAX9295 default address ACK | TBD | TBD | TBD | TBD |
| MAX9295 remapped address ACK | TBD | TBD | TBD | TBD |
| AP1302 ACK | TBD | TBD | TBD | TBD |

passive evidence가 하나도 없을 때만 bounded initialization probe의 초기 간격,
지수 backoff, disconnect epoch당 최대 횟수와 operator reset 조건을 별도 승인한다.
