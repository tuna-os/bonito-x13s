# X13s layer — adds Lenovo ThinkPad X13s hardware support to any bootc base.
#
# Usage:
#   podman build -t x13s .
#   podman build --build-arg BASE_IMAGE=ghcr.io/bootcrew/ubuntu-bootc:latest -t x13s-ubuntu .
#
# Requirements: aarch64 base image with SC8280XP-capable kernel (mainline 6.3+).
# Supported bases: any bootc image with dnf, apt, zypper, or pacman.

ARG BASE_IMAGE=ghcr.io/tuna-os/bonito:gnome
FROM ${BASE_IMAGE}

COPY src/x13s-setup.sh /x13s-setup.sh
RUN chmod +x /x13s-setup.sh && /x13s-setup.sh && rm /x13s-setup.sh
