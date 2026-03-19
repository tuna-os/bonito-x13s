# Copilot Instructions

## What This Repo Does

This repo builds a [bootc](https://containers.github.io/bootc/) container image for the **Lenovo ThinkPad X13s** (Qualcomm SC8280XP, aarch64), layered on top of [`ghcr.io/tuna-os/bonito:gnome`](https://github.com/tuna-os/bonito) (a Fedora Atomic GNOME base). The image is published to a container registry for users to subscribe to via `bootc switch`, and can also be converted into a bootable live ISO.

## Build Commands

**Build the base bootc image:**
```bash
sudo podman build -t localhost/bonito-x13s:latest -f Containerfile .
```

**Build the ISO installer layer:**
```bash
sudo podman build --cap-add sys_admin --security-opt label=disable \
    -t localhost/bonito-x13s-installer:latest -f Containerfile.iso .
```

**Build the full ISO (end-to-end):**
```bash
./build-iso.sh
```

**Push the bootc image to a registry:**
```bash
./push.sh                                     # default registry
REGISTRY=ghcr.io/myuser TAG=v1.0 ./push.sh   # custom
```

**Cross-architecture build** (x86_64 host → aarch64 image):
Requires `qemu-user-static`. The build scripts auto-detect and add `--platform linux/arm64`.

## Architecture

```
Containerfile             ← Base bootc image (publishable, no ISO tooling)
Containerfile.iso         ← ISO installer layer (dracut-live, EFI, GRUB config)
src/
  build.sh                ← ISO layer build script (runs inside container)
  iso.yaml                ← GRUB2 menu configuration for the live ISO
build-iso.sh              ← End-to-end ISO build orchestration
push.sh                   ← Build and push bootc image to registry
x13s_repo/                ← Source files for the x13s RPM (COPR: jlinton/x13s)
  x13s.spec               ← RPM spec
  x13s.conf               ← dracut config (firmware in initrd)
  override.conf            ← Bluetooth systemd override
  75-x13s.preset           ← systemd preset enabling pd-mapper
bootc-isos/               ← Cloned subproject (ondrejbudai/bootc-isos)
  justfile                 ← just recipes for container/ISO builds
```

**Two-stage design:**
- `Containerfile` produces the base bootc image that gets published to the registry. Users subscribe to this. Contains X13s packages, kargs, firmware config — but NOT live-ISO tooling.
- `Containerfile.iso` layers live-ISO requirements (dracut-live, dmsquash-live, EFI binaries, iso.yaml) on top. This is consumed by image-builder to produce the ISO.

## Key X13s Constraints

**Required kernel arguments** (set in `/usr/lib/bootc/kargs.d/01-x13s.toml`):
- `arm64.nopauth` — disables pointer authentication (required for stability)
- `clk_ignore_unused`, `pd_ignore_unused` — prevent clock/power domain gating lockups
- `modprobe.blacklist=qcom_q6v5_pas` — must be blacklisted at boot (breaks power management if loaded in initrd)
- `devicetree=/dtb/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb` — X13s device tree

**Firmware in initrd** (set in `/etc/dracut.conf.d/x13s.conf`):
These four blobs must be in the initrd for the battery monitor to work:
`qcadsp8280.mbn.xz`, `qcdxkmsuc8280.mbn.xz`, `qccdsp8280.mbn.xz`, `qcslpi8280.mbn.xz`

**pd-mapper**: Must be enabled and running for Qualcomm power domain management.

**Bluetooth MAC**: The X13s has no persistent Bluetooth address. The `x13s` package randomizes a MAC at first boot.

## bootc-isos Contract

The ISO is built using `ondrejbudai/bootc-isos` and the `bootc-generic-iso` image type. The `image-builder` used is a patched fork (built by `just build-image-builder`). Key contract requirements:
- Kernel at `/usr/lib/modules/*/vmlinuz`
- Initramfs at same path as `initramfs.img`
- `/etc/os-release` must contain `VERSION_ID`
- EFI binaries in `/boot/efi/EFI/<vendor>/`

The `src/iso.yaml` configures GRUB2 menu entries with X13s kernel args and DTB for live boot.

## COPR Package

The `x13s_repo/` directory contains the source for the `x13s` COPR package (`jlinton/x13s`). Changes to dracut config, bluetooth override, or systemd presets belong in those source files and the spec.
