# imx-hantro VPU 인코더 드라이버 모듈

## 결론

`dist/pim/opt/pim/driver/hantro_vc8000e_ext.ko` 는 [jhw7500/imx-hantro](https://github.com/jhw7500/imx-hantro) 에서 빌드한
VC8000E 인코더 드라이버의 수정 모듈이다. 보드 커널에 내장된 같은 드라이버(`mxc_hantro_vc8000e`)는 코어 예약을
스레드 id 로 해제한다. 그래서 예약하지 않은 스레드가 마지막 close 를 하면 예약이 영구히 남고, 재부팅 전까지 모든
인코딩이 멈춘다(#191). 수정 모듈은 열린 파일로 해제한다(imx-hantro `9af5230`).

부팅 때 `pim-vpu-driver.service` 가 cam-operate 보다 먼저 VPU 장치를 내장 드라이버에서 이 모듈로 옮긴다(#194).

## 빌드와 반영

```bash
cd ~/ai/opencode/projects/imx-hantro
./make-for-imx8 clean && ./make-for-imx8   # vc8000e/hantro_vc8000e_ext.ko
./update_bin.sh                            # dist 로 복사 + 매니페스트 sha256/size/source.commit 갱신

cd ../pim-package-jhw
git add dist/pim/opt/pim/driver/hantro_vc8000e_ext.ko   # LFS
python3 tools/verify_binaries.py --strict
```

이 모듈은 kernel.release(`5.10.35-lts-5.10.y+g2fce14defc04`)에 묶인다. 매니페스트의 `required_strings` 가 vermagic 을
확인한다. 커널 이미지가 바뀌면 그 커널 트리로 다시 빌드한다. `owner_filp` 는 디버그 정보에 남은 수정 필드
이름으로, 원본 빌드에는 없다. 그래서 strip 하지 않는다.

## 부팅 때 전환

`/opt/pim/bin/vpu_driver_swap.sh` 가 한 번 돈다(`pim-vpu-driver.service`, `Before=cam-operate.service`). 순서는 이렇다.

1. 장치 `38320000.vpu_vc8000e` 가 내장 드라이버에 붙어 있고, `/dev/mxc_hantro_vc8000e` 를 연 프로세스가 없는지 확인한다.
2. `insmod /opt/pim/driver/hantro_vc8000e_ext.ko` 를 한다.
3. 내장 드라이버에서 unbind 한다.
4. `driver_override` 를 `mxc_hantro_vc8000e_ext` 로 쓴다.
5. 모듈 드라이버에 bind 한다.

옮기지 못하면 내장 드라이버로 남긴다.

- insmod 실패, 장치 사용 중, 모듈 없음 → 아무것도 바꾸지 않는다.
- cam-operate 가 이미 돌고 있음 → 건너뛴다. gstApp 이 언제든 장치를 열 수 있어 보유자 검사와 unbind 사이가 안전하지 않기 때문이다. 부팅 때는 `Before=` 순서 덕분에 cam-operate 가 아직 기동 전이다.
- insmod 를 하는 동안 누가 장치를 열었는지, unbind 바로 앞에서 보유자를 한 번 더 확인한다.
- 모듈 bind 실패 → `driver_override` 를 비우고 내장 드라이버에 다시 bind 한다.
- 스크립트는 항상 0 으로 끝나고, cam-operate 는 이 유닛을 Requires 하지 않는다. 그래서 전환이 실패해도 녹화는 평소대로 기동한다.

`.ko` 는 `/lib/modules` 에 넣지 않는다. compatible 이 내장 드라이버와 같아 udev 가 자동 적재하면 수동 전환과 겹치기 때문이다.

**첫 설치:** postinst 는 유닛을 enable 만 한다(`customctl enable pim-vpu-driver`, `--now` 없음). 그래서 전환은 설치 뒤
**다음 부팅부터** 일어난다. 재부팅 전까지는 내장 드라이버를 쓴다. 바인딩은 재부팅 전까지 유지되므로 cam-operate 를
재시작할 때마다 다시 옮길 필요는 없다.

## 확인과 되돌리기

```bash
basename "$(readlink /sys/bus/platform/devices/38320000.vpu_vc8000e/driver)"   # mxc_hantro_vc8000e_ext 이면 전환됨
grep -a 'VPU-DRV' /var/log/cantops/local0.log | tail                          # 결과 ([VPU-DRV][vpu_driver_swap.sh])
journalctl -u pim-vpu-driver -b                                               # 경고·오류는 journal 에도 남는다
```

local0.log 에는 rsyslog 설정(`local0.notice`)상 notice 이상만 남는다. 전환 성공·이미 전환됨은 notice, 건너뜀·복귀는 warning, 복귀 실패는 err 다. warning·err 는 journal 에도 `<4>`/`<3>` 우선순위로 남는다. 다만 eMMC 모드가 journald `MaxLevelStore` 를 낮추면 journal 사본은 빠질 수 있다.

수동으로 다시 돌리려면 `systemctl stop cam-operate` 로 녹화를 멈춘 뒤 `systemctl restart pim-vpu-driver` 를 하고, 다시 `systemctl start cam-operate` 를 한다. cam-operate 가 돌고 있으면 스크립트가 건너뛴다.

되돌리려면 `systemctl disable pim-vpu-driver` 를 하고 재부팅한다. 재부팅하면 내장 드라이버로 돌아간다. 단 패키지를 업그레이드하면 postinst(`customctl enable pim-vpu-driver`)가 다시 enable 하므로, 계속 끄려면 업그레이드 뒤에 다시 disable 한다.
재부팅 없이 바로 되돌리려면 `systemctl stop cam-operate` 로 녹화를 멈춘다. gstApp 만 멈추면 cam-operate 가 곧 다시 띄워 장치를 연다. 그다음 `/proc/*/fd` 에 `/dev/mxc_hantro_vc8000e` 를 연 프로세스가 없는지 확인하고 아래를 실행한 뒤, `systemctl start cam-operate` 를 한다.

```bash
echo 38320000.vpu_vc8000e > /sys/bus/platform/drivers/mxc_hantro_vc8000e_ext/unbind
echo > /sys/bus/platform/devices/38320000.vpu_vc8000e/driver_override
echo 38320000.vpu_vc8000e > /sys/bus/platform/drivers/mxc_hantro_vc8000e/bind
```

장치를 연 프로세스가 있을 때는 unbind 하지 않는다. 드라이버 cleanup 이, 열린 fd 의 `private_data` 가 가리키는 메모리를 해제하기 때문이다.
