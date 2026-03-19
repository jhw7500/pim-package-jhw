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
    git \
    zip \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /workspace

# Default command
CMD ["/bin/bash"]
