# imx-vpu 바이너리 기준

## 결론

`pim-package-jhw`의 활성 VPU 바이너리 두 개는 원본 GitHub `imx-vpu`의
`5b9573c39c9b566a9e17174b812a87f355214afa`를 기준으로 빌드한 한 세트다.
실제 제품 소스 변경은 두 번째 부모 `130651746c8ff4b768e210dbeee23753fbedfd68`에서
완성됐다. 확인일은 **2026-08-26**이다.

정리된 GitLab 이력에서는 다음 커밋이 같은 역할을 한다.

| 의미 | GitHub 원본 | GitLab 정리 이력 |
|---|---|---|
| 빌드 기준 병합 | `5b9573c` | `7014cfa` |
| 실제 소스 완성 | `1306517` | `e848481` |

## 활성 패키지 파일

| 항목 | `libgstvpu.so` | `libfslvpuwrap.so.3.0.0` |
|---|---|---|
| 패키지 경로 | `dist/pim/usr/lib/gstreamer-1.0/libgstvpu.so` | `dist/pim/usr/lib/libfslvpuwrap.so.3.0.0` |
| SHA-256 | `d83594447b7dac184c019371c0c296b72345585913ed03adf6e0a56f60a38b27` | `03980af335703b0352a9a43f2dff62657671db5aaf822e476a415d5e762a4927` |
| 크기 | `111720` bytes | `58576` bytes |
| GNU Build ID | `0d13ca40d28a8f21c54d30f4a5f1032debac9f5b` | `1c5740bed9d68420fc690f8fa86724eae03b8a4c` |
| Build ID 제거 후 재현 SHA-256 | `e57a8655cf829dfe5874d1f812d815ba488d7fcce0e9cc6f7ae17db20355eb2f` | `3256a7d4ab7c56020e7c7a4a4a490e1dddffe1748993afb7ef8a3aae7c12e8f7` |

두 파일은 `VpuEncOpenParamSimp` ABI를 공유하므로 반드시 함께 빌드·배포한다.
`dist/pim/usr/lib/libfslvpuwrap.so.3`는 wrapper 실파일을 가리키는 심볼릭 링크다.

`dist/pim/opt/pim/lib/` 아래 동명 파일은 백포트 전 stock 백업본이며 런타임
로드 대상이 아니다. 이 문서와 바이너리 매니페스트는 `/usr/lib` 아래 활성 파일만
검증한다.

## 정합성 근거

두 활성 파일은 `pim-package-jhw` 커밋 `8328eea`에서 처음 반영된 뒤 변경되지
않았다. 원본 빌드 시각을 맞춘 SDK 재빌드와 비교했을 때 각 ELF의
`.note.gnu.build-id` 20바이트만 달랐고, 해당 section을 제거하면 위 표의
재현 SHA-256으로 일치했다.

플러그인에는 `qp-min`, `qp-max`, `H264 profile`, `H264 level` 속성이 있고,
wrapper에는 H.264/HEVC profile·level 검증 경로가 포함된다. 이 문자열 계약과
파일 SHA·크기·아키텍처는 `.github/binary-manifest.json`에서 함께 검사한다.

## 빌드와 개인 패키지 반영

```bash
cd ~/ai/opencode/projects/imx-vpu
./setup-deps.sh
./build.sh reconf

# SDK strip 적용 후 두 파일을 반드시 함께 반영
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
