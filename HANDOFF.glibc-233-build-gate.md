# HANDOFF — GLIBC 2.33 빌드 게이트 (2026-09-03, 완료)

## 완료·검증
- 원인: Yocto SDK(glibc 2.33) 빌드 → 타깃 Ubuntu 20.04(2.31)에서 `stat@GLIBC_2.33` 로더 실패.
  2.33부터 stat 계열이 실제 export 심볼이 된 탓. 소스 문제 아님 → `./docker/build.sh` 로만 빌드.
- 보드(192.168.214.4) camera6 `.deb` 설치·검증 완료. ord/vcm/vsd sha256 `61e6d88f`/`666bc7ca`/`c2e88445`,
  전부 GLIBC_2.17. 4프로세스 가동, MAX9296 errno=0, 2채널 녹화 확인.
- 게이트 도입: `tools/check_glibc.sh` + build.sh `verify_glibc`(패키징 前) + docker/build.sh 실판정·strict.
  fail-open 6종 수정. 테스트 8→18케이스, `test/tools/run_all.sh` 등록(CI 실행 확인).
- PR #68·#69·#70 전부 머지 → master `654bce3`. 지적 10건 중 9건이 Codex 발견, 전부 재현 후 수정.

## 다음 액션 1개
GitLab 반영 여부 결정 — 정본을 어느 쪽으로 둘지 먼저 정해야 함(아래 제약).

## 제약
- **GitLab 미반영**(사용자 지시: 추후). GitLab master `f83be57`(`0.6.3.1`) vs master `654bce3`
  (`0.6.3+jhw.camera6`) — 각각 20커밋 이상 분기, 버전 라인 다름. 단순 push 불가.
- **설치 후 `systemctl start cam-operate` 필요** — 설치가 `cam_operate_stop.sh` 로 카메라 스택을
  내리고 자동 복귀하지 않음. (`/etc/defaultconf.json` 은 패키지 백업본이라 덮어쓰는 게 정상 —
  라이브 설정은 `/root/shared_v/edgeconf_pim.json` 이고 보존됨. 백업 절차 불필요.)
- 이 저장소 빌드는 ord/vsd/vcm 만 담김. 공유 시 `release/PIM_MP_release_*.zip` 단위로 전달.
- 미해결: build.sh 가 `test/` 를 통째로 `.deb` 에 넣어 테스트 스크립트가 기기 배포됨.

## 열린 것
PR 없음(3건 모두 머지). jhw7500/automation#83 — Codex 자동 리뷰 PR open 트리거 미발동(근거 추가함).
Notion 저장 완료: 1차 신규 4·보강 2, 2차 신규 1·보강 4(정정 1 포함).
