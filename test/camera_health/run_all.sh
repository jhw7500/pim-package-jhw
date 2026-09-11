#!/bin/bash
# Camera health v1 contract tests. No camera board is required.
set -eu

cd "$(dirname "$0")"
python3 schema_test.py
python3 max9296_package_config_test.py
python3 max9296_config_migration_test.py
python3 max9296_package_tools_test.py
python3 pim_guardian_startup_grace_test.py
python3 runtime_consumer_path_test.py
python3 runtime_script_consumers_test.py
python3 native_runtime_config_test.py
python3 ord_startup_failure_test.py
python3 config_expectation_test.py
python3 runtime_config_test.py
bash recovery_protocol_test.sh
bash ord_single_owner_test.sh
bash cam_operate_control_test.sh
bash cam_liveness_test.sh
bash cam_stop_order_test.sh
python3 capture_probe_test.py
python3 max9296_producer_test.py
bash cam_fps_stack_cli_test.sh
python3 systemd_recovery_contract_test.py
python3 package_executable_test.py
python3 aggregator_test.py
python3 shadow_compare_test.py
bash config_bootstrap_test.sh
