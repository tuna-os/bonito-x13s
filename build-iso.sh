#!/bin/bash
# Build a bootable live ISO for the ThinkPad X13s from the bonito-x13s bootc image.
# This script handles the full pipeline: base image → ISO installer image → ISO file.
#
# Requirements: podman, just, golang (just and golang installed automatically if missing)
# On x86_64 hosts: qemu-user-static must be installed for cross-arch builds.
set -euo pipefail

BASE_IMAGE="localhost/bonito-x13s:latest"
ISO_IMAGE="localhost/bonito-x13s-installer:latest"
BOOTC_ISOS_DIR="bootc-isos"

# Detect if we need cross-arch build
ARCH=$(uname -m)
PLATFORM_FLAG=""
if [ "$ARCH" != "aarch64" ]; then
    echo "Detected $ARCH host — will cross-build for aarch64 (requires qemu-user-static)."
    PLATFORM_FLAG="--platform linux/arm64"
fi

echo "=== Step 1: Building base bootc image: ${BASE_IMAGE} ==="
sudo podman build $PLATFORM_FLAG -t "${BASE_IMAGE}" -f Containerfile .

echo "=== Step 2: Building ISO installer image: ${ISO_IMAGE} ==="
sudo podman build $PLATFORM_FLAG \
    --cap-add sys_admin --security-opt label=disable \
    -t "${ISO_IMAGE}" -f Containerfile.iso .

echo "=== Step 3: Building ISO via bootc-isos ==="

# Clone bootc-isos if not already present
if [ ! -d "${BOOTC_ISOS_DIR}" ]; then
    echo "Cloning ondrejbudai/bootc-isos..."
    git clone https://github.com/ondrejbudai/bootc-isos "${BOOTC_ISOS_DIR}"
fi

cd "${BOOTC_ISOS_DIR}"

# Ensure just and golang are available
if ! command -v just &> /dev/null || ! command -v go &> /dev/null; then
    echo "Installing just and golang..."
    sudo dnf install -y just golang
fi

# Build the patched image-builder (required for bootc-generic-iso support)
JUST_PATH=$(which just)
sudo "$JUST_PATH" build-image-builder

# Build the ISO using the containerized image-builder
echo "Building ISO from ${ISO_IMAGE}..."
sudo "$JUST_PATH" iso-in-container "${ISO_IMAGE}"

echo ""
echo "=== ISO build complete ==="
echo "Output: ${BOOTC_ISOS_DIR}/output/"
ls -lh output/*.iso 2>/dev/null || echo "(check output/ for results)"
