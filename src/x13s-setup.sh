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
    dnf -y install x13s pd-mapper bluez dracut dracut-live qcom-firmware
    dnf clean all

elif command -v apt-get &>/dev/null; then
    echo "--- Package manager: apt (Debian/Ubuntu) ---"
    # ubuntu-bootc is ostree-based: /var hierarchy is empty at build time
    mkdir -p \
        /var/lib/apt/lists/partial \
        /var/lib/dpkg/updates \
        /var/lib/dpkg/info \
        /var/lib/dpkg/alternatives \
        /var/cache/apt/archives/partial \
        /var/log/apt
    touch /var/lib/dpkg/status /var/lib/dpkg/available
    apt-get update -y
    apt-get install -y bluez dracut-core
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

# ── 4. Rebuild initramfs ──────────────────────────────────────────────────────
# Include dmsquash-live so this single image works both as a bootc target
# (bootc switch) and as input to make-systemd-boot-iso.sh for live ISO builds.
echo "--- Rebuilding initramfs (kernel ${KERNEL}) ---"
mkdir -p "$(realpath /root 2>/dev/null || echo /root)"
DRACUT_NO_XATTR=1 dracut --force --zstd --no-hostonly \
    --add "dmsquash-live" \
    "/usr/lib/modules/${KERNEL}/initramfs.img" "${KERNEL}" \
    || echo "WARNING: dracut rebuild failed — using existing initramfs"

echo "=== X13s setup complete ==="
