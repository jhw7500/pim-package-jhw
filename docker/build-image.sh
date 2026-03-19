#!/bin/bash

# Docker image name
IMAGE_NAME="pim-builder-ubuntu20.04-arm64"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "Building Docker image for PIM compilation"
echo "=========================================="

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker is not installed"
    exit 1
fi

# Enable QEMU for ARM64 emulation (if on x86_64 host)
HOST_ARCH=$(uname -m)
if [ "$HOST_ARCH" = "x86_64" ]; then
    echo "Setting up QEMU for ARM64 emulation..."
    docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
fi

# Build Docker image with ARM64 platform
echo "Building Docker image: ${IMAGE_NAME}"
cd "${SCRIPT_DIR}"
docker build --platform linux/arm64 -t ${IMAGE_NAME} .

if [ $? -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "Docker image built successfully!"
    echo "Image name: ${IMAGE_NAME}"
    echo "=========================================="
    echo ""
    echo "Next step: Run ./docker/build.sh to compile"
else
    echo "ERROR: Docker image build failed"
    exit 1
fi
