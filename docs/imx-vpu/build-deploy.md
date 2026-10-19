# imx-vpu 바이너리 기준

## 결론

`pim-package-jhw`의 활성 VPU 바이너리 두 개는 원본 GitHub `imx-vpu`에서 빌드한다.
지금 플러그인 `libgstvpu.so`는 `d61eaf9`(PR #48, upstream `85acd07` 백포트) 빌드이고,
wrapper `libfslvpuwrap.so.3.0.0`은 `1f55ed4` 빌드다. 두 기준 모두
`5b9573c39c9b566a9e17174b812a87f355214afa`의 후손이다. 실제 제품 소스 변경은
`5b9573c`의 두 번째 부모 `130651746c8ff4b768e210dbeee23753fbedfd68`에서
완성됐다(확인일 **2026-08-26**).

정리된 GitLab 이력에서는 다음 커밋이 같은 역할을 한다.

| 의미 | GitHub 원본 | GitLab 정리 이력 |
|---|---|---|
| 빌드 기준 병합 | `5b9573c` | `7014cfa` |
| 실제 소스 완성 | `1306517` | `e848481` |

## 활성 패키지 파일

| 항목 | `libgstvpu.so` | `libfslvpuwrap.so.3.0.0` |
|---|---|---|
| 패키지 경로 | `dist/pim/usr/lib/gstreamer-1.0/libgstvpu.so` | `dist/pim/usr/lib/libfslvpuwrap.so.3.0.0` |
| imx-vpu 소스 커밋 | `d61eaf9` | `1f55ed4` |
| SHA-256 | `a121fe07253e2ecba495dadc21bce7eda8c51a40772dc96658308f7da6b08b56` | `acfec82c89ee84c9009d4ea3c31b20cdf892010481a27c20d18fbfdd5c8a3384` |
| 크기 | `111720` bytes | `58576` bytes |
| GNU Build ID | `e513579f1e5c38e730b46f4b276672f60d3e5733` | `6763edf6d1503098638e399f071591b6e555986b` |
| 패키지 반영 커밋 | `ad9ffd9` (camera15) | `758b3b1` |

식별값의 정본은 `.github/binary-manifest.json`이고, `tools/verify_binaries.py --strict`가
SHA·크기·모드·아키텍처·문자열을 검사한다. 위 표는 사람이 보드 파일과 대조할 때 쓰는 사본이다.

두 파일은 `VpuEncOpenParamSimp` ABI를 공유한다. 그래서 wrapper 소스(공유 헤더 포함)가
바뀌면 두 파일을 함께 빌드·배포한다. wrapper 소스가 바뀌지 않았으면 플러그인만 바꿀 수
있다. camera15는 `1f55ed4..d61eaf9`에서 바뀐 소스가
`imx-gst1.0-plugin/plugins/vpu/gstvpu.c`와
`imx-gst1.0-plugin/plugins/fbdevsink/gstimxfbdevsink.c` 둘뿐이어서 플러그인만 교체했다.
`dist/pim/usr/lib/libfslvpuwrap.so.3`는 wrapper 실파일을 가리키는 심볼릭 링크다.

`dist/pim/opt/pim/lib/` 아래 동명 파일은 백포트 전 stock 백업본이며 런타임
로드 대상이 아니다. 이 문서와 바이너리 매니페스트는 `/usr/lib` 아래 활성 파일만
검증한다.

## 반영 이력과 정합성 근거

| 패키지 커밋 | 내용 | `libgstvpu.so` SHA-256 | `libfslvpuwrap.so.3.0.0` SHA-256 |
|---|---|---|---|
| `8328eea` | 첫 반영(소스 기준 `5b9573c`) | `d83594447b7d…` | `03980af33570…` |
| `758b3b1` | `1f55ed4`(libtool 부재 시 configure 재실행)로 두 파일 재빌드 | `d509fb1b98d7…` | `acfec82c89ee…` |
| `ad9ffd9` | 플러그인만 `d61eaf9`(PR #48)로 교체 | `a121fe07253e…` | 그대로 |

- `8328eea` 세트는 원본 빌드 시각을 맞춘 SDK 재빌드와 비교했다. 각 ELF의
  `.note.gnu.build-id` 20바이트만 달랐다. 해당 section을 제거하면 SHA-256이
  `e57a8655cf829dfe5874d1f812d815ba488d7fcce0e9cc6f7ae17db20355eb2f`(플러그인),
  `3256a7d4ab7c56020e7c7a4a4a490e1dddffe1748993afb7ef8a3aae7c12e8f7`(wrapper)로 일치했다.
- `758b3b1`은 코드가 바뀌지 않았다. 커밋 메시지에 따르면 이전 바이너리와
  `.text/.data/.dynsym/.dynstr`가 같고, `.rodata`의 `__DATE__`/`__TIME__`만 다르다.
- `ad9ffd9`는 재현 빌드 비교를 하지 않았다. 동작은 보드에서 `GST_DEBUG=5` 대조로
  확인했다(이전 플러그인은 vpuenc 시작 때 SIGSEGV, 새 플러그인은 정상 종료).

플러그인에는 `qp-min`, `qp-max`, `H264 profile`, `H264 level` 속성이 있고,
wrapper에는 H.264/HEVC profile·level 검증 경로가 포함된다. 이 문자열 계약과
파일 SHA·크기·아키텍처는 `.github/binary-manifest.json`에서 함께 검사한다.

## 빌드와 개인 패키지 반영

```bash
cd ~/ai/opencode/projects/imx-vpu
./setup-deps.sh
./build.sh reconf

# SDK strip 적용 후 반영(wrapper 소스가 그대로면 플러그인만)
cp imx-gst1.0-plugin/build/plugins/vpu/libgstvpu.so \
  ../pim-package-jhw/dist/pim/usr/lib/gstreamer-1.0/
cp staging/usr/lib/libfslvpuwrap.so.3.0.0 \
  ../pim-package-jhw/dist/pim/usr/lib/

cd ../pim-package-jhw
python3 tools/verify_binaries.py --strict
```

현재 작업 디렉터리의 미-strip 산출물과 패키지의 strip 완료 파일은 원본 SHA가
다르다. 재빌드 정합성을 확인할 때는 동일 SDK strip과 빌드 시각을 적용한 뒤
Build ID를 제외해 비교한다.

## 회사 패키지 반영

현재 회사 `pim-package/master`에는 이 활성 VPU 세트가 아직 없다. GitHub
`pim-package-jhw/master`에서 전체 검증을 마치고 push 승인을 받아 반영한 다음,
회사 GitLab feature 브랜치로 동기화하고 다시 별도 push 승인을 받는다.

패키지 저장소 HEAD는 계속 바뀌므로 문서 기준으로 고정하지 않는다. VPU 소스
기준이 바뀔 때만 소스 커밋과 바이너리 식별값을 함께 갱신한다.
