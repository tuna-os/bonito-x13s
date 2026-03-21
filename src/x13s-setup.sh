#!/bin/bash
# X13s hardware support setup — works on any Linux distribution.
#
# Installs required packages via the detected package manager, then applies
# universal configuration (kernel args, module loading, dracut, bluetooth).
# Rebuilds the initramfs with dmsquash-live so the image can boot as a
# live ISO as well as a regular bootc image.
#
# Supported package managers: dnf (Fedora/RHEL), apt (Debian/Ubuntu),
#   zypper (openSUSE), pacman (Arch)

set -euo pipefail

KERNEL=$(ls /usr/lib/modules/ | sort -V | tail -1)
echo "=== X13s setup for kernel ${KERNEL} ==="

# ── 1. Distro-specific package installation ──────────────────────────────────

if command -v dnf &>/dev/null; then
    echo "--- Package manager: dnf (Fedora/RHEL) ---"
    dnf -y copr enable jlinton/x13s
    dnf -y install x13s pd-mapper bluez dracut dracut-live qcom-firmware systemd-ukify systemd-boot-unsigned
    dnf clean all

elif command -v apt-get &>/dev/null; then
    echo "--- Package manager: apt (Debian/Ubuntu) ---"
    # ubuntu-bootc has an incomplete dpkg database (ostree-based image).
    # Pre-stub base-files as "installed" so apt-get doesn't try to run its
    # postinst, which calls mkdir on directories that already exist.
    mkdir -p \
        /var/lib/apt/lists/partial \
        /var/lib/dpkg/updates \
        /var/lib/dpkg/info \
        /var/lib/dpkg/alternatives \
        /var/cache/apt/archives/partial \
        /var/log/apt
    touch /var/lib/dpkg/status /var/lib/dpkg/available
    if ! dpkg-query -W base-files >/dev/null 2>&1; then
        printf 'Package: base-files\nStatus: install ok installed\nVersion: 9999\nArchitecture: arm64\nDescription: stub\n\n' \
            >> /var/lib/dpkg/status
    fi
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::="--force-confold" \
        bluez dracut-core
    apt-get clean -y

    # Ubuntu's dracut lacks dmsquash-live — fetch just that module from upstream
    if [ ! -d /usr/lib/dracut/modules.d/90dmsquash-live ]; then
        echo "Fetching dmsquash-live from dracut-ng..."
        mkdir -p /var/lib/apt/lists/partial /var/cache/apt/archives/partial
        apt-get install -y git
        git clone --depth=1 --filter=blob:none --sparse \
            https://github.com/dracut-ng/dracut-ng.git /tmp/dracut-ng
        cd /tmp/dracut-ng
        git sparse-checkout set \
            modules.d/90dmsquash-live \
            modules.d/90dmsquash-live-autooverlay
        cp -r modules.d/90dmsquash-live /usr/lib/dracut/modules.d/
        cp -r modules.d/90dmsquash-live-autooverlay \
              /usr/lib/dracut/modules.d/ 2>/dev/null || true
        cd /
        rm -rf /tmp/dracut-ng
        apt-get purge -y git && apt-get autoremove -y && apt-get clean -y
    fi

elif command -v zypper &>/dev/null; then
    echo "--- Package manager: zypper (openSUSE) ---"
    zypper --non-interactive install bluez dracut
    zypper clean

elif command -v pacman &>/dev/null; then
    echo "--- Package manager: pacman (Arch) ---"
    pacman -Sy --noconfirm bluez dracut
    pacman -Sc --noconfirm

else
    echo "WARNING: No supported package manager found — skipping package install"
fi

# ── 2. Firmware check ────────────────────────────────────────────────────────
# These 4 blobs are required for battery/DSP (ADSP/CDSP/SLPI) to function.
# They ship as qcom-firmware (Fedora COPR) or linux-firmware (most distros).
FWDIR="/usr/lib/firmware/qcom/sc8280xp/LENOVO/21BX"
MISSING=0
for fw in qcadsp8280.mbn qccdsp8280.mbn qcslpi8280.mbn qcdxkmsuc8280.mbn; do
    if [ ! -f "${FWDIR}/${fw}.xz" ] && [ ! -f "${FWDIR}/${fw}" ]; then
        echo "WARNING: Missing firmware: ${fw}"
        MISSING=1
    fi
done
[ "$MISSING" = "1" ] && echo "WARNING: Battery/audio may not work without firmware"

# ── 3. Universal configuration ───────────────────────────────────────────────

# Kernel arguments (bootc format — applied on first boot via bootc)
mkdir -p /usr/lib/bootc/kargs.d
cat > /usr/lib/bootc/kargs.d/01-x13s.toml << 'EOF'
# Required for SC8280XP (Lenovo ThinkPad X13s) stability
kargs = ["arm64.nopauth", "clk_ignore_unused", "pd_ignore_unused", "efi=noruntime"]
EOF

# Module loading — order matters:
#   1. qcom_pd_mapper: registers protection domain service in-kernel
#   2. qcom_q6v5_pas: starts ADSP/CDSP/SLPI remotprocs (needs pd_mapper first)
# Without the DSPs running, battery, audio, and camera have no data.
printf 'qcom_pd_mapper\nqcom_q6v5_pas\n' > /etc/modules-load.d/x13s.conf

# Dracut: embed firmware blobs in initrd + exclude q6v5_pas from initrd
# (q6v5_pas cannot load during initrd — power domains not ready yet)
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/x13s.conf << 'EOF'
install_items+=" \
  /usr/lib/firmware/qcom/sc8280xp/LENOVO/21BX/qcadsp8280.mbn.xz \
  /usr/lib/firmware/qcom/sc8280xp/LENOVO/21BX/qcdxkmsuc8280.mbn.xz \
  /usr/lib/firmware/qcom/sc8280xp/LENOVO/21BX/qccdsp8280.mbn.xz \
  /usr/lib/firmware/qcom/sc8280xp/LENOVO/21BX/qcslpi8280.mbn.xz \
"
omit_drivers+=" qcom_q6v5_pas "
EOF

# Bluetooth: brief delay on start (X13s BT hardware enumeration quirk)
mkdir -p /etc/systemd/system/bluetooth.service.d
cat > /etc/systemd/system/bluetooth.service.d/x13s.conf << 'EOF'
[Service]
ExecStartPre=/bin/sleep 1
EOF

# ── 4. Composefs backend: remove bootupd, install systemd-boot ───────────────
# bootc auto-selects the composefs backend (systemd-boot + UKI) when:
#   1. /boot/EFI/BOOT/BOOTAA64.EFI is present in the image
#   2. A UKI exists at /boot/EFI/Linux/ (built in section 6 below)
#   3. bootupd is NOT installed
# With composefs, 'bootc install to-disk' sets up systemd-boot and
# auto-discovers the UKI — the DTB embedded in the UKI makes the X13s boot
# without any post-install BLS patching.
# Reference: https://bootc-dev.github.io/bootc/bootloaders.html

if command -v dnf &>/dev/null; then
    # Prefer dnf remove; fall back to rpm --nodeps if bootupd is protected
    dnf -y remove bootupd 2>/dev/null || \
        rpm -e --nodeps bootupd 2>/dev/null || \
        echo "WARNING: Could not remove bootupd — composefs backend may not activate"
fi

# Install systemd-boot EFI binary into the image
SDBOOT_SRC=$(find /usr/lib/systemd/boot/efi /usr/share/systemd-boot/efi \
    -name "systemd-bootaa64.efi" 2>/dev/null | head -1 || true)
if [ -n "$SDBOOT_SRC" ]; then
    mkdir -p /boot/EFI/BOOT /boot/EFI/systemd
    cp "$SDBOOT_SRC" /boot/EFI/BOOT/BOOTAA64.EFI
    cp "$SDBOOT_SRC" /boot/EFI/systemd/systemd-bootaa64.efi
    echo "systemd-boot installed at /boot/EFI/"
else
    echo "WARNING: systemd-bootaa64.efi not found — composefs/systemd-boot unavailable"
fi

mkdir -p /boot/loader
cat > /boot/loader/loader.conf << 'EOF'
timeout 5
EOF

# ── 5. Rebuild initramfs ──────────────────────────────────────────────────────
# Include dmsquash-live so this single image works both as a bootc target
# (bootc switch) and as input to make-systemd-boot-iso.sh for live ISO builds.
echo "--- Rebuilding initramfs (kernel ${KERNEL}) ---"
mkdir -p "$(realpath /root 2>/dev/null || echo /root)"
DRACUT_NO_XATTR=1 dracut --force --zstd --no-hostonly \
    --add "dmsquash-live" \
    "/usr/lib/modules/${KERNEL}/initramfs.img" "${KERNEL}" \
    || echo "WARNING: dracut rebuild failed — using existing initramfs"

# ── 6. Build UKI with embedded X13s DTB ──────────────────────────────────────
# The UKI at /boot/EFI/Linux/ is the third composefs condition (alongside
# systemd-boot and no bootupd). It embeds: kernel + initramfs + DTB + cmdline.
# systemd-boot auto-discovers it — no BLS 'devicetree' directive required.
# With composefs, plain 'bootc install to-disk /dev/nvme0n1' works on X13s.
echo "--- Building UKI with embedded DTB ---"
BOARD="sc8280xp-lenovo-thinkpad-x13s"
DTB_PATH=$(find \
    "/usr/lib/modules/${KERNEL}/dtb/qcom" \
    "/usr/lib/firmware/${KERNEL}/device-tree/qcom" \
    /usr/lib/firmware/qcom \
    -name "${BOARD}.dtb" 2>/dev/null | head -1 || true)
[ -z "$DTB_PATH" ] && \
    DTB_PATH=$(find /usr/lib -name "${BOARD}.dtb" 2>/dev/null | head -1 || true)

if [ -n "$DTB_PATH" ] && command -v ukify &>/dev/null; then
    mkdir -p /boot/EFI/Linux
    ukify build \
        --linux          "/usr/lib/modules/${KERNEL}/vmlinuz" \
        --initrd         "/usr/lib/modules/${KERNEL}/initramfs.img" \
        --devicetree     "$DTB_PATH" \
        --cmdline        "arm64.nopauth clk_ignore_unused pd_ignore_unused efi=noruntime rw" \
        --os-release     "@/etc/os-release" \
        --output         "/boot/EFI/Linux/x13s-${KERNEL}.efi"
    echo "UKI: $(ls -lh /boot/EFI/Linux/x13s-${KERNEL}.efi)"
    echo "composefs backend active — 'bootc install to-disk' will use systemd-boot"
else
    [ -z "$DTB_PATH" ] && echo "WARNING: X13s DTB not found — skipping UKI build"
    command -v ukify &>/dev/null || echo "WARNING: ukify not available — skipping UKI build"
fi

echo "=== X13s setup complete ==="
