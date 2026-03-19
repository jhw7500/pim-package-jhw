#!/bin/bash
#
# Build PIM package in Docker container
# Usage: ./docker/build.sh [MODULE|clean [MODULE]]
#   MODULE: ord, vsd, vcm, adab, adab_ecat, cism, stm32update, pim_gate
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

# Handle clean command
if [ "$1" = "clean" ]; then
    CLEAN_TARGET="$2"
    if [ -n "$CLEAN_TARGET" ]; then
        echo "Cleaning build cache for ${CLEAN_TARGET}..."
        if [ "$CLEAN_TARGET" = "pim_gate" ]; then
            rm -rf ${PROJECT_ROOT}/pim_gate/cpp_source/build ${PROJECT_ROOT}/pim_gate/release
        else
            rm -rf ${PROJECT_ROOT}/${CLEAN_TARGET}/build
        fi
    else
        echo "Cleaning all build cache..."
        rm -rf ${PROJECT_ROOT}/*/build ${PROJECT_ROOT}/release ${PROJECT_ROOT}/pim_gate/cpp_source/build ${PROJECT_ROOT}/pim_gate/release
    fi
    echo "Clean completed."
    exit 0
fi

# Get submodule argument (if provided)
SUBMODULE="$1"

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
    if [ -z "$SUBMODULE" ] || [ "$SUBMODULE" = "ord" ] || [ "$SUBMODULE" = "all" ]; then
        echo "Checking binary compatibility..."
        if [ -f "${PROJECT_ROOT}/release/pim/usr/local/bin/ord" ]; then
            file ${PROJECT_ROOT}/release/pim/usr/local/bin/ord
            echo ""
            echo "Checking GLIBC version requirements..."
            readelf -V ${PROJECT_ROOT}/release/pim/usr/local/bin/ord | grep GLIBC | sort -u | head -10
        fi
        if [ -f "${PROJECT_ROOT}/release/pim/usr/local/bin/vcm" ]; then
            file ${PROJECT_ROOT}/release/pim/usr/local/bin/vcm
        fi
    fi
else
    echo "ERROR: Build failed"
    exit 1
fi
