# Ubuntu 20.04 ARM64 base image (using multi-arch image)
FROM ubuntu:20.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install build tools and dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    pkg-config \
    libjson-c-dev \
    libhiredis-dev \
    libyaml-dev \
    libjsoncpp-dev \
    python3 \
    git \
    zip \
    && rm -rf /var/lib/apt/lists/*

# The repository is bind-mounted from the host and is therefore owned by a
# different UID than the container's root user. Limit the Git exception to the
# fixed workspace mount used by docker/build.sh.
RUN git config --system --add safe.directory /workspace

# Set working directory
WORKDIR /workspace

# Default command
CMD ["/bin/bash"]
