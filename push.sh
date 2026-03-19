#!/bin/bash
# Build and push the bonito-x13s bootc image to a container registry.
# Users can then subscribe with: sudo bootc switch ghcr.io/hanthor/bonito-x13s:latest
#
# Usage:
#   ./push.sh                                    # push to default registry
#   REGISTRY=ghcr.io/youruser ./push.sh            # push to a custom registry
#   REGISTRY=ghcr.io/youruser TAG=v1.0 ./push.sh   # push with a specific tag
set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io/hanthor}"
IMAGE_NAME="bonito-x13s"
TAG="${TAG:-latest}"
FULL_REF="${REGISTRY}/${IMAGE_NAME}:${TAG}"

# Detect if we need cross-arch build
ARCH=$(uname -m)
PLATFORM_FLAG=""
if [ "$ARCH" != "aarch64" ]; then
    echo "Detected $ARCH host — will cross-build for aarch64 (requires qemu-user-static)."
    PLATFORM_FLAG="--platform linux/arm64"
fi

echo "=== Building base bootc image ==="
sudo podman build $PLATFORM_FLAG -t "localhost/${IMAGE_NAME}:${TAG}" -f Containerfile .

echo "=== Tagging as ${FULL_REF} ==="
sudo podman tag "localhost/${IMAGE_NAME}:${TAG}" "${FULL_REF}"

echo "=== Pushing to registry ==="
sudo podman push "${FULL_REF}"

echo ""
echo "=== Published: ${FULL_REF} ==="
echo ""
echo "Users can subscribe with:"
echo "  sudo bootc switch ${FULL_REF}"
echo ""
echo "Existing subscribers update with:"
echo "  sudo bootc upgrade"
