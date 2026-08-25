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

docker run --rm \
    --platform linux/arm64 \
    --memory=4g \
    --memory-swap=8g \
    -v ${PROJECT_ROOT}:/workspace \
    -w /workspace \
    -e MAKEFLAGS="-j1" \
    -e PIM_VERIFY_BINARIES="${PIM_VERIFY_BINARIES:-warn}" \
    ${IMAGE_NAME} \
    /bin/bash -c "${BUILD_CMD}"

if [ $? -eq 0 ]; then
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
    VERIFY_MODE=${PIM_VERIFY_BINARIES:-warn}
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
        glibc=$(readelf -V "$path" 2>/dev/null | grep GLIBC | awk '{print $NF}' | sort -uV | tail -1)
        [ -n "$glibc" ] && echo "  [${label}] max GLIBC: ${glibc}"
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
        for m in ord vsd vcm adab adab_ecat cism stm32update mcp_trust_test; do
            verify_binary "$m" "${MODULE_BIN[$m]}" || verify_failed=1
        done
        verify_directory "pim_gate" "$PIM_GATE_DIR" || verify_failed=1
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
    exit 1
fi
