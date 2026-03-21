#!/bin/bash
# Build a live ISO using systemd-boot, mimicking ironrobin/archiso-x13s.
# Works with any bootc container that has kernel, initramfs, and X13s DTB.
#
# Usage: sudo ./make-systemd-boot-iso.sh <container-image> [output.iso]

set -euxo pipefail

IMAGE="${1:?Usage: $0 <container-image> [output.iso]}"
OUTPUT="${2:-bonito-x13s-latest.iso}"
LABEL="${3:-Bonito-X13s-Live}"
TITLE="${LABEL//-/ }"
WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

echo "=== Building systemd-boot ISO from $IMAGE ==="

# --- 1. Extract boot files from container ---

KERNEL=$(podman run --rm "$IMAGE" sh -c 'ls /usr/lib/modules/ | sort -V | tail -1')
echo "Kernel version: $KERNEL"

mkdir -p "$WORKDIR/boot"
podman run --rm "$IMAGE" cat "/usr/lib/modules/${KERNEL}/vmlinuz" \
    > "$WORKDIR/boot/vmlinuz"
podman run --rm "$IMAGE" cat "/usr/lib/modules/${KERNEL}/initramfs.img" \
    > "$WORKDIR/boot/initramfs.img"

# Find DTB — paths differ between Fedora and Ubuntu
DTB_PATH=$(podman run --rm "$IMAGE" sh -c '
    for d in \
        "/usr/lib/modules/$(ls /usr/lib/modules/ | sort -V | tail -1)/dtb/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb" \
        "/usr/lib/firmware/$(ls /usr/lib/modules/ | sort -V | tail -1)/device-tree/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb" \
        ; do
        [ -f "$d" ] && echo "$d" && exit 0
    done
    find / -name "sc8280xp-lenovo-thinkpad-x13s.dtb" -print -quit 2>/dev/null
')
if [ -z "$DTB_PATH" ]; then
    echo "ERROR: X13s DTB not found in container"
    podman run --rm "$IMAGE" find / -name "*sc8280xp*" 2>/dev/null || true
    exit 1
fi
echo "DTB path: $DTB_PATH"
podman run --rm "$IMAGE" cat "$DTB_PATH" > "$WORKDIR/boot/x13s.dtb"

# Find systemd-boot EFI binary (try host first, then container)
SDBOOT=""
for p in /usr/lib/systemd/boot/efi/systemd-bootaa64.efi \
         /usr/share/systemd-boot/efi/systemd-bootaa64.efi; do
    [ -f "$p" ] && SDBOOT="$p" && break
done
if [ -z "$SDBOOT" ]; then
    echo "systemd-boot not on host, extracting from container..."
    SDBOOT_PATH=$(podman run --rm "$IMAGE" \
        find /usr/lib/systemd/boot/efi -name "systemd-bootaa64.efi" 2>/dev/null || true)
    if [ -n "$SDBOOT_PATH" ]; then
        podman run --rm "$IMAGE" cat "$SDBOOT_PATH" > "$WORKDIR/boot/systemd-bootaa64.efi"
        SDBOOT="$WORKDIR/boot/systemd-bootaa64.efi"
    fi
fi
# Last resort: pull ubuntu-bootc arm64 for systemd-boot
if [ -z "$SDBOOT" ]; then
    echo "Pulling ubuntu-bootc for systemd-boot binary..."
    podman run --rm --platform linux/arm64 ghcr.io/bootcrew/ubuntu-bootc:latest \
        cat /usr/lib/systemd/boot/efi/systemd-bootaa64.efi \
        > "$WORKDIR/boot/systemd-bootaa64.efi"
    SDBOOT="$WORKDIR/boot/systemd-bootaa64.efi"
fi
[ -f "$SDBOOT" ] || { echo "FATAL: cannot find systemd-bootaa64.efi"; exit 1; }

echo "Boot files:"
ls -lh "$WORKDIR/boot/"

# --- 2. Export container rootfs and create squashfs ---

echo "=== Creating squashfs from container rootfs ==="
# Use podman mount for direct overlay access — avoids pipe-induced corruption
# from 'podman export | tar'. Use lz4 compression for reliability and fast
# live-boot decompression.
mkdir -p "$WORKDIR/iso/LiveOS"
CONTAINER=$(podman create "$IMAGE" /bin/sh)
ROOTFS_MOUNT=$(podman mount "$CONTAINER")
echo "=== Creating squashfs (this takes a few minutes) ==="
mksquashfs "$ROOTFS_MOUNT" "$WORKDIR/iso/LiveOS/squashfs.img" \
    -comp lz4 -b 131072 -no-progress \
    -e proc -e sys -e dev -e run -e tmp
podman umount "$CONTAINER"
podman rm "$CONTAINER"
echo "Squashfs: $(ls -lh "$WORKDIR/iso/LiveOS/squashfs.img")"

echo "=== Verifying squashfs integrity ==="
VERDIR=$(mktemp -d)
unsquashfs -no-progress -n -d "$VERDIR" \
    "$WORKDIR/iso/LiveOS/squashfs.img" \
    'usr/bin/bash' 'usr/bin/sh' 'usr/lib/systemd/systemd' 2>&1 | tail -5
rm -rf "$VERDIR"
echo "Squashfs verification: OK"

# --- 3. Create ISO directory structure ---

# Boot files on ISO root (for CD boot where ISO9660 is accessible)
mkdir -p "$WORKDIR/iso/boot/aarch64"
cp "$WORKDIR/boot/vmlinuz"      "$WORKDIR/iso/boot/aarch64/"
cp "$WORKDIR/boot/initramfs.img" "$WORKDIR/iso/boot/aarch64/"
cp "$WORKDIR/boot/x13s.dtb"     "$WORKDIR/iso/boot/aarch64/"

# systemd-boot on ISO root
mkdir -p "$WORKDIR/iso/EFI/BOOT"
cp "$SDBOOT" "$WORKDIR/iso/EFI/BOOT/BOOTAA64.EFI"

# Loader configuration (matches ironrobin/archiso-x13s pattern)
mkdir -p "$WORKDIR/iso/loader/entries"

cat > "$WORKDIR/iso/loader/loader.conf" << 'EOF'
timeout 15
default bonito-x13s.conf
beep on
EOF

cat > "$WORKDIR/iso/loader/entries/bonito-x13s.conf" << EOF
title      $TITLE
sort-key   01
linux      /boot/aarch64/vmlinuz
initrd     /boot/aarch64/initramfs.img
devicetree /boot/aarch64/x13s.dtb
options    root=live:CDLABEL=$LABEL rd.live.image rd.live.overlay.thin efi=noruntime arm64.nopauth clk_ignore_unused pd_ignore_unused enforcing=0 quiet
EOF

cat > "$WORKDIR/iso/loader/entries/bonito-x13s-troubleshoot.conf" << EOF
title      $TITLE (troubleshooting)
sort-key   02
linux      /boot/aarch64/vmlinuz
initrd     /boot/aarch64/initramfs.img
devicetree /boot/aarch64/x13s.dtb
options    root=live:CDLABEL=$LABEL rd.live.image efi=noruntime arm64.nopauth clk_ignore_unused pd_ignore_unused enforcing=0 rd.shell
EOF

# --- 4. Create EFI boot image (FAT) ---
# This FAT image is what UEFI firmware reads when booting from USB.
# It must contain systemd-boot, loader config, AND all boot files
# (kernel, initramfs, DTB) because UEFI can only read FAT partitions.

echo "=== Creating EFI boot image ==="

EFI_STAGING="$WORKDIR/efi-staging"
mkdir -p "$EFI_STAGING"
cp -a "$WORKDIR/iso/EFI"    "$EFI_STAGING/"
cp -a "$WORKDIR/iso/loader"  "$EFI_STAGING/"
cp -a "$WORKDIR/iso/boot"    "$EFI_STAGING/"

# Calculate FAT image size (need enough for kernel + initramfs + overhead)
EFI_SIZE_MB=$(du -sm "$EFI_STAGING" | awk '{print int($1 * 1.1 + 4)}')
echo "EFI partition size: ${EFI_SIZE_MB}MB"

EFI_IMG="$WORKDIR/iso/images/efiboot.img"
mkdir -p "$(dirname "$EFI_IMG")"
dd if=/dev/zero of="$EFI_IMG" bs=1M count="$EFI_SIZE_MB" status=none
mkfs.vfat -n "EFIBOOT" "$EFI_IMG"

# Populate FAT image with mtools (mcopy -s for recursive copy)
mcopy -s -i "$EFI_IMG" "$EFI_STAGING/EFI"    ::
mcopy -s -i "$EFI_IMG" "$EFI_STAGING/loader"  ::
mcopy -s -i "$EFI_IMG" "$EFI_STAGING/boot"    ::

rm -rf "$EFI_STAGING"

echo "EFI boot image contents:"
mdir -i "$EFI_IMG" -/ ::

# --- 5. Assemble final ISO ---

echo "=== Assembling ISO ==="
xorriso -as mkisofs \
    -o "$OUTPUT" \
    -R -J \
    -V "$LABEL" \
    -e images/efiboot.img \
    -no-emul-boot \
    -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$EFI_IMG" \
    -appended_part_as_gpt \
    "$WORKDIR/iso"

echo "=== Done ==="
echo "ISO: $(ls -lh "$OUTPUT")"
echo "Label: $LABEL"
echo "Boot: systemd-boot + devicetree"
