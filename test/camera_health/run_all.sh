#!/bin/bash
# Camera health v1 contract tests. No camera board is required.
set -eu

cd "$(dirname "$0")"
python3 schema_test.py
python3 config_expectation_test.py
python3 capture_probe_test.py
python3 aggregator_test.py
python3 shadow_compare_test.py
bash config_bootstrap_test.sh
