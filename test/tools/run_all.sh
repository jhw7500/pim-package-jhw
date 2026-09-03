#!/bin/bash
# tools/ 스크립트의 계약 테스트. 보드도, 바이너리 재빌드도 필요 없다.
# 실제 매니페스트와 dist/ 바이너리는 읽기만 하고 사본에서만 조작한다.
set -eu

cd "$(dirname "$0")"
python3 verify_binaries_test.py
bash run_binary_verification_test.sh
bash check_glibc_test.sh
