#!/usr/bin/bash
# Build script for the bonito-x13s live ISO layer.
# This runs inside the container during `podman build` of Containerfile.iso.
# Modeled after bootc-isos/kinoite and bootc-isos/bluefin-lts build scripts.

set -exo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create the directory that /root is symlinked to (needed by some tools)
mkdir -p "$(realpath /root)"

# Install dracut-live and rebuild initramfs with live-boot support
dnf install -y dracut-live

# Determine the kernel version inside the container
kernel=$(ls /usr/lib/modules/ | head -1)

# Rebuild initramfs with dmsquash-live for squashfs-based live boot.
# DRACUT_NO_XATTR=1 avoids xattr issues in container builds.
# --no-hostonly ensures all drivers are included (not just detected hardware).
# The X13s firmware config (/etc/dracut.conf.d/x13s.conf) is picked up automatically.
DRACUT_NO_XATTR=1 dracut -v --force --zstd --reproducible --no-hostonly \
    --add "dmsquash-live dmsquash-live-autooverlay" \
    "/usr/lib/modules/${kernel}/initramfs.img" "${kernel}"

# Install livesys-scripts for automatic live user and session setup
dnf install -y livesys-scripts
sed -i "s/^livesys_session=.*/livesys_session=gnome/" /etc/sysconfig/livesys
systemctl enable livesys.service livesys-late.service

# EFI binaries required by image-builder for ISO creation.
# On aarch64, we need the aa64 variants (not x64).
dnf install -y grub2-efi-aa64-cdboot

# image-builder expects the EFI directory in /boot/efi
mkdir -p /boot/efi
cp -av /usr/lib/efi/*/*/EFI /boot/efi/ 2>/dev/null || true

# ISO build dependencies
dnf install -y xorriso isomd5sum squashfs-tools

# Copy the iso.yaml GRUB configuration for image-builder
mkdir -p /usr/lib/bootc-image-builder
cp "$SCRIPT_DIR/iso.yaml" /usr/lib/bootc-image-builder/iso.yaml

# Copy X13s DTB to a GRUB-accessible location in the ISO.
# GRUB runs before the squashfs is mounted, so the DTB must be in the ISO's
# raw filesystem. image-builder copies /boot/dtb/ into the ISO tree alongside
# the kernel, making it available to GRUB as /images/pxeboot/../dtb/...
# We place the DTB at /boot/dtb/qcom/ which lands at /dtb/qcom/ in the ISO.
kernel=$(ls /usr/lib/modules/ | head -1)
DTB_SRC="/usr/lib/modules/${kernel}/dtb/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb"
if [ -f "${DTB_SRC}" ]; then
    mkdir -p /boot/dtb/qcom
    cp "${DTB_SRC}" /boot/dtb/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb
    echo "DTB copied from kernel modules: ${DTB_SRC}"
else
    echo "ERROR: X13s DTB not found at ${DTB_SRC}"
    find /usr/lib/modules/${kernel}/dtb -name "*sc8280xp*" 2>/dev/null || true
fi

# Set timezone to UTC for the live session
rm -f /etc/localtime
systemd-firstboot --timezone UTC

# Live ISO root is an overlayfs backed by tmpfs under /run.
# Mount a larger tmpfs at /var/tmp so ostree and other tools have enough space.
rm -rf /var/tmp
mkdir /var/tmp
cat > /etc/systemd/system/var-tmp.mount << 'EOF'
[Unit]
Description=Larger tmpfs for /var/tmp on live system

[Mount]
What=tmpfs
Where=/var/tmp
Type=tmpfs
Options=size=50%%,nr_inodes=1m,x-systemd.graceful-option=usrquota

[Install]
WantedBy=local-fs.target
EOF
systemctl enable var-tmp.mount

# Clean up
dnf clean all
