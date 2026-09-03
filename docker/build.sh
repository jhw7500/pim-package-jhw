#!/bin/bash
#
# Build PIM package in Docker container
# Usage: ./docker/build.sh [MODULE|clean [MODULE]]
#   MODULE: ord, vsd, vcm, adab, adab_ecat, cism, stm32update, mcp_trust_test, pim_gate
#           If omitted, builds all modules (incremental).
#   clean:  Clean build directories
#           clean        - clean all modules
#           clean MODULE - clean specific module
#
# Examples:
#   ./docker/build.sh              # Build all modules (incremental)
#   ./docker/build.sh ord          # Build only ord module (incremental)
#   ./docker/build.sh clean        # Clean all modules
#   ./docker/build.sh clean ord    # Clean only ord module
#

# Docker image name
IMAGE_NAME="pim-builder-ubuntu20.04-arm64"

# Get project root directory (parent of docker/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Known modules (single source of truth for validation)
KNOWN_MODULES="ord vsd vcm adab adab_ecat cism stm32update mcp_trust_test pim_gate"

# Handle clean command
if [ "$1" = "clean" ]; then
    CLEAN_TARGET="$2"
    if [ -n "$CLEAN_TARGET" ]; then
        echo "Cleaning build cache for ${CLEAN_TARGET}..."
        case "$CLEAN_TARGET" in
            pim_gate)
                rm -rf ${PROJECT_ROOT}/pim_gate/cpp_source/build ${PROJECT_ROOT}/pim_gate/release
                ;;
            ord|vsd|vcm|adab|adab_ecat|cism|stm32update|mcp_trust_test)
                rm -rf ${PROJECT_ROOT}/${CLEAN_TARGET}/build
                ;;
            *)
                echo "ERROR: Unknown module: ${CLEAN_TARGET}"
                echo "Available modules: ${KNOWN_MODULES}"
                exit 1
                ;;
        esac
    else
        echo "Cleaning all build cache..."
        rm -rf ${PROJECT_ROOT}/ord/build ${PROJECT_ROOT}/vsd/build ${PROJECT_ROOT}/vcm/build
        rm -rf ${PROJECT_ROOT}/adab/build ${PROJECT_ROOT}/adab_ecat/build ${PROJECT_ROOT}/cism/build
        rm -rf ${PROJECT_ROOT}/stm32update/build ${PROJECT_ROOT}/mcp_trust_test/build
        rm -rf ${PROJECT_ROOT}/release ${PROJECT_ROOT}/pim_gate/cpp_source/build ${PROJECT_ROOT}/pim_gate/release
    fi
    echo "Clean completed."
    exit 0
fi

# Get submodule argument (if provided)
SUBMODULE="$1"

# Validate submodule name before spinning up Docker
if [ -n "$SUBMODULE" ]; then
    case "$SUBMODULE" in
        ord|vsd|vcm|adab|adab_ecat|cism|stm32update|mcp_trust_test|pim_gate)
            ;;
        *)
            echo "ERROR: Unknown module: ${SUBMODULE}"
            echo "Available modules: ${KNOWN_MODULES}"
            exit 1
            ;;
    esac
fi

echo "=========================================="
if [ -n "$SUBMODULE" ]; then
    echo "Compiling PIM submodule: ${SUBMODULE} (incremental)"
else
    echo "Compiling PIM package - all modules (incremental)"
fi
echo "=========================================="
echo "Project root: ${PROJECT_ROOT}"

# Check if Docker image exists
if ! docker image inspect ${IMAGE_NAME} &> /dev/null; then
    echo "ERROR: Docker image '${IMAGE_NAME}' not found"
    echo "Please run ./docker/build-image.sh first"
    exit 1
fi

# Run build in Docker container with limited parallelism to avoid QEMU crashes
echo "Starting Docker container..."
echo "WARNING: QEMU emulation is unstable and may crash during compilation"
echo "Consider building on target device instead for faster and stable builds"

# Prepare build command
if [ -n "$SUBMODULE" ]; then
    BUILD_CMD="echo 'Building submodule ${SUBMODULE} in Docker container...' && ./build.sh ${SUBMODULE}"
else
    BUILD_CMD="echo 'Building in Docker container (sequential build for stability)...' && ./build.sh"
fi

# 컨테이너는 root 로 실행되므로 빌드 산출물이 root 소유로 남는다. 그대로 두면 호스트에서
# './docker/build.sh clean <module>' 의 rm -rf 가 Permission denied 로 실패한다. 컨테이너
# 안에서(=root 권한으로) 호스트 사용자에게 되돌려 준다. 호스트 sudo 가 필요 없다.
# 빌드가 실패해도 수행하고, 원래 종료 코드는 그대로 돌려준다. chown -h 여야 한다 —
# -h 가 없으면 심링크를 따라가 대상만 바꾸고 링크 자체는 root 로 남는다.
HOST_UID=$(id -u)
HOST_GID=$(id -g)
RESTORE_OWNER="find /workspace -path /workspace/.git -prune -o -path /workspace/.worktrees -prune -o -user 0 -exec chown -h ${HOST_UID}:${HOST_GID} {} + 2>/dev/null || true"
CONTAINER_CMD="${BUILD_CMD}; build_rc=\$?; ${RESTORE_OWNER}; exit \$build_rc"

# PIM_GLIBC_GATE / PIM_MAX_GLIBC 는 값 없이 넘긴다 — 호스트에 설정된 경우에만 전달되어
# 컨테이너 안 tools/check_glibc.sh 의 기본값(strict / 2.31)을 덮는다. 여기서 기본값을
# 다시 적으면 정의가 두 곳으로 갈라진다.
docker run --rm \
    --platform linux/arm64 \
    --memory=4g \
    --memory-swap=8g \
    -v ${PROJECT_ROOT}:/workspace \
    -w /workspace \
    -e MAKEFLAGS="-j1" \
    -e PIM_VERIFY_BINARIES="${PIM_VERIFY_BINARIES:-warn}" \
    -e PIM_GLIBC_GATE \
    -e PIM_MAX_GLIBC \
    ${IMAGE_NAME} \
    /bin/bash -c "${CONTAINER_CMD}"
docker_rc=$?

if [ $docker_rc -eq 0 ]; then
    echo ""
    echo "=========================================="
    if [ -n "$SUBMODULE" ]; then
        echo "Build completed successfully for: ${SUBMODULE}"
    else
        echo "Build completed successfully!"
    fi
    echo "Binaries are in: release/pim/"
    echo "=========================================="
    echo ""
    # Verify built binaries: arch (ARM aarch64) + GLIBC version requirements.
    # build.sh already ran the manifest verifier; this checks release artifacts.
    # release 산출물 검사(존재/arch/GLIBC)는 기본으로 빌드를 세운다. 여기서 걸리는 것은
    # .deb 에 그대로 실릴 결함이지 중간 상태가 아니다. PIM_VERIFY_BINARIES=warn 으로 낮출 수 있다.
    # 컨테이너로 넘기는 값(위 -e)은 매니페스트 드리프트 검사용이라 warn 으로 남긴다 —
    # .github/binary-manifest.json 이 "불일치는 경고이지 실패가 아니다"라고 규정한다.
    VERIFY_MODE=${PIM_VERIFY_BINARIES:-strict}
    if [ "$VERIFY_MODE" = "off" ]; then
        echo "Release artifact verification disabled (PIM_VERIFY_BINARIES=off)"
        exit 0
    fi

    verify_binary() {
        local label="$1"
        local path="$2"
        if [ ! -f "$path" ]; then
            echo "  [${label}] MISSING: $path"
            return 1
        fi
        local info
        info=$(file "$path")
        if echo "$info" | grep -q "ARM aarch64"; then
            echo "  [${label}] OK arch: $(echo "$info" | sed 's|.*: ||')"
        else
            echo "  [${label}] WRONG ARCH: $info"
            return 1
        fi
        local glibc
        glibc=$(readelf -V "$path" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1)
        [ -n "$glibc" ] && echo "  [${label}] max GLIBC: ${glibc}"

        # 타깃 rootfs 가 제공하는 것보다 새 GLIBC 를 요구하면 실패로 처리한다. 표시만 하고
        # 넘어가면 Yocto SDK 로 만든 GLIBC_2.33 바이너리가 그대로 .deb 에 실린다.
        # 판정 기준(PIM_MAX_GLIBC 천장, PIM_GLIBC_GATE 모드)은 tools/check_glibc.sh 한 곳에 둔다.
        local glibc_out glibc_rc
        glibc_out=$(bash "${PROJECT_ROOT}/tools/check_glibc.sh" "$path" 2>&1)
        glibc_rc=$?
        if echo "$glibc_out" | grep -q "requires GLIBC_"; then
            echo "$glibc_out" | grep -v '^GLIBC check OK' | sed "s|^|  [${label}] |"
        fi
        [ "$glibc_rc" -eq 0 ] || return 1
        return 0
    }

    verify_directory() {
        local label="$1"
        local path="$2"
        if [ -d "$path" ]; then
            local count
            count=$(find "$path" -type f 2>/dev/null | wc -l)
            echo "  [${label}] OK: $count file(s) in $path"
            return 0
        else
            echo "  [${label}] MISSING dir: $path"
            return 1
        fi
    }

    # Module → built artifact path mapping
    declare -A MODULE_BIN=(
        [ord]="${PROJECT_ROOT}/release/pim/usr/local/bin/ord"
        [vsd]="${PROJECT_ROOT}/release/pim/usr/local/bin/vsd"
        [vcm]="${PROJECT_ROOT}/release/pim/usr/local/bin/vcm"
        [adab]="${PROJECT_ROOT}/release/pim/opt/cis/bin/adab_adc"
        [adab_ecat]="${PROJECT_ROOT}/release/pim/opt/cis/bin/adab_ecat"
        [cism]="${PROJECT_ROOT}/release/pim/opt/cis/bin/cism"
        [stm32update]="${PROJECT_ROOT}/release/pim/opt/cis/bin/stm32update"
        [mcp_trust_test]="${PROJECT_ROOT}/release/pim/opt/pim/bin/mcp_trust_test"
    )
    PIM_GATE_DIR="${PROJECT_ROOT}/release/pim/opt/pim_gate"

    echo ""
    echo "=========================================="
    echo "Verifying built artifacts..."
    echo "=========================================="

    verify_failed=0
    if [ -n "$SUBMODULE" ]; then
        if [ "$SUBMODULE" = "pim_gate" ]; then
            verify_directory "pim_gate" "$PIM_GATE_DIR" || verify_failed=1
        else
            verify_binary "$SUBMODULE" "${MODULE_BIN[$SUBMODULE]}" || verify_failed=1
        fi
    else
        # build.sh 가 소스 디렉터리 없는 모듈을 건너뛰므로 검증도 같이 건너뛴다.
        # 이 저장소의 .deb 는 ord/vsd/vcm 만 담는다 — 보드에 설치된 pim-mp 도
        # adab/adab_ecat/cism/stm32update/mcp_trust_test/pim_gate 를 소유하지 않는다
        # (dpkg -L pim-mp 로 확인). 건너뛰지 않으면 정상 빌드가 MISSING 으로 실패한다.
        for m in ord vsd vcm adab adab_ecat cism stm32update mcp_trust_test; do
            if [ ! -d "${PROJECT_ROOT}/${m}" ]; then
                echo "  [${m}] SKIP: no source directory"
                continue
            fi
            verify_binary "$m" "${MODULE_BIN[$m]}" || verify_failed=1
        done
        if [ -d "${PROJECT_ROOT}/pim_gate" ]; then
            verify_directory "pim_gate" "$PIM_GATE_DIR" || verify_failed=1
        else
            echo "  [pim_gate] SKIP: no source directory"
        fi
    fi
    echo "=========================================="

    if [ $verify_failed -ne 0 ]; then
        echo "WARNING: One or more artifacts failed verification"
        if [ "$VERIFY_MODE" = "strict" ]; then
            exit 2
        fi
    fi
else
    echo "ERROR: Build failed"
    # 실패 신호를 구분해 전달한다: 컴파일 실패는 1, 컨테이너 안 산출물/GLIBC 검증
    # 실패는 2. 여기서 뭉개면 CI·운영자가 원인을 좁힐 수 없다.
    [ $docker_rc -eq 2 ] && exit 2
    exit 1
fi
