# Base bootc image for the Lenovo ThinkPad X13s (aarch64, Qualcomm SC8280XP).
# This is the publishable image — users subscribe via: bootc switch ghcr.io/tuna-os/bonito-x13s:latest
# For building a live ISO, see Containerfile.iso which layers on top of this.

FROM ghcr.io/tuna-os/bonito:gnome

# Install ThinkPad X13s packages from the jlinton/x13s COPR
RUN dnf -y copr enable jlinton/x13s && \
    dnf -y install x13s pd-mapper bluez dracut qcom-firmware && \
    dnf clean all

# Configure dracut to include QCOM firmware blobs in the initrd,
# and exclude qcom_q6v5_pas — it must not load during initrd (ordering issue
# with power domains). It loads after boot via modules-load.d instead.
RUN echo 'install_items+=" /lib/firmware/qcom/sc8280xp/LENOVO/21BX/qcadsp8280.mbn.xz /lib/firmware/qcom/sc8280xp/LENOVO/21BX/qcdxkmsuc8280.mbn.xz /lib/firmware/qcom/sc8280xp/LENOVO/21BX/qccdsp8280.mbn.xz /lib/firmware/qcom/sc8280xp/LENOVO/21BX/qcslpi8280.mbn.xz "' > /etc/dracut.conf.d/x13s.conf && \
    echo 'omit_drivers+=" qcom_q6v5_pas "' >> /etc/dracut.conf.d/x13s.conf

# Load qcom_pd_mapper then qcom_q6v5_pas after boot (in order).
# pd_mapper must be up before q6v5_pas starts the DSPs (ADSP/CDSP/SLPI).
# This is what gives us working battery, audio, and camera.
RUN printf 'qcom_pd_mapper\nqcom_q6v5_pas\n' > /etc/modules-load.d/x13s.conf

# Rebuild the initramfs targeting the container's kernel (not the build host kernel).
# mkdir -p "$(realpath /root)" avoids dracut-install failure when /root is a symlink.
# DRACUT_NO_XATTR=1 avoids xattr errors in container builds.
RUN mkdir -p "$(realpath /root)" && \
    kernel=$(ls /usr/lib/modules/ | head -1) && \
    DRACUT_NO_XATTR=1 dracut --force --zstd --no-hostonly \
        "/usr/lib/modules/${kernel}/initramfs.img" "${kernel}" || true

# Kernel arguments required for X13s boot stability.
# Note: qcom_q6v5_pas is NOT blacklisted here — it's excluded from the
# initrd via dracut omit_drivers and loaded after boot via modules-load.d.
RUN mkdir -p /usr/lib/bootc/kargs.d && \
    echo 'kargs = ["arm64.nopauth", "clk_ignore_unused", "pd_ignore_unused", "efi=noruntime"]' \
    > /usr/lib/bootc/kargs.d/01-x13s.toml

# GRUB DTB hint (fallback for systems that don't parse bootc kargs)
RUN echo 'GRUB_DEFAULT_DTB="/dtb/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb"' >> /etc/default/grub
