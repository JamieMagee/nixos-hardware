# Raspberry Pi

NixOS profiles and modules for Raspberry Pi boards.

## What's here

- `common/` has the shared bits: the `linux-rpi` kernel build (vendor defconfig, matching firmware), the `config.txt` generation module, a pinned wireless firmware, and the firmware-partition install module.
- `2/`, `3/`, `4/`, `5/` are the board profiles. Each one picks the right kernel and kernel params. Pi 4 and 5 also set DT filters and the initrd modules they need.
- The extra files under `4/` are opt-in toggles for Pi 4 hardware: audio, dwc2, GPIO, I2C, LEDs, the PoE HATs, touchscreens, and so on.

## Using a board profile

```nix
{
  imports = [
    <nixos-hardware/raspberry-pi/4>
  ];
}
```

These profiles assume the `generic-extlinux-compatible` bootloader (the NixOS module that writes an `extlinux.conf` for U-Boot to read), which is what aarch64 NixOS SD images use by default. There is no `boot.loader.raspberry-pi` module here. U-Boot and the GPU boot code still have to land on the firmware partition somehow: either your image builder does it, or you use the firmware install module below.

## Firmware install

`hardware.raspberry-pi.firmware` builds the files the Pi needs before Linux starts and installs them on the firmware partition (default `/boot/firmware`). The payload contains GPU boot code (`bootcode.bin`, `start*.elf`, `fixup*.dat`), raw device trees and overlays from the selected kernel, the rendered `config.txt`, and optionally U-Boot. It is not a new boot method. It supplies the files used by the existing `generic-extlinux-compatible` and U-Boot path.

Device trees come from `${config.boot.kernelPackages.kernel}/dtbs` by default, so the firmware uses DTBs and overlays built with the selected kernel. The module adds the matching overlay `README` from the kernel source when the kernel output omits it. Set `hardware.raspberry-pi.firmware.deviceTree.source` if a custom kernel keeps its raw device trees elsewhere. An overridden source must contain base DTBs and a complete `overlays/` directory, including `README`, `overlay_map.dtb`, and `hat_map.dtb`.

When you build an SD image, the module sets `sdImage.populateFirmwareCommands` itself, so the firmware partition is populated at build time with no extra configuration. Managed U-Boot defaults on for aarch64 images, matching the standard NixOS image path. It remains opt-in on running systems and 32-bit images.

For a running system, set `hardware.raspberry-pi.firmware.enable = true`. An activation script then repopulates the firmware partition on every `nixos-rebuild switch`. It is off by default.

Both paths install the same immutable payload. The installer records its files in `.nixos-hardware-raspberry-pi.manifest` and only removes files owned by the previous manifest. The first managed install claims files from the payload but leaves other files alone. Later installs also preserve unmanaged files. They adopt byte-identical files, but stop before making changes if a new payload path would overwrite different unmanaged content.

To chainload U-Boot from the firmware, enable `uboot.enable`. It copies `u-boot.bin` to the firmware partition and sets `config.txt`'s `kernel` line for you:

```nix
{
  hardware.raspberry-pi.firmware = {
    enable = true;
    uboot.enable = true;
  };
}
```

`uboot.package` defaults to a nixpkgs U-Boot build using the upstream `rpi_arm64_defconfig`, which covers every 64-bit board (Pi 3/4/5). For a 32-bit board, override it with the matching U-Boot build. On the Pi 5 this boots from SD, but U-Boot can't drive USB/PCIe/RP1 yet, so USB boot, NVMe boot, and a USB keyboard at the U-Boot prompt don't work until Linux takes over.

## `config.txt`

Board profiles import `hardware.raspberry-pi.configtxt`, which renders `config.txt` from Nix options. The defaults track the Raspberry Pi OS pi-gen image: camera and display autodetect, KMS, audio on, `arm_boost`.

```nix
{
  hardware.raspberry-pi.configtxt.settings = {
    all = {
      dtparam = [ "audio=on" ];
      dtoverlay = [
        "vc4-kms-v3d"
        "disable-bt"
      ];
    };
    pi5.arm_freq = 2400;
    cm4.otg_mode = true;
  };
}
```

List values become repeated keys in the rendered file, so the `dtoverlay` above expands to:

```ini
dtoverlay=vc4-kms-v3d
dtoverlay=disable-bt
```

Top-level attrs are conditional sections (`all`, `pi4`, `pi5`, `cm4`, and so on). Nesting stacks filters. To drop a default, set the key to `null` with `mkForce`.

Use `configtxt.overlays` when order or parameter scope matters:

```nix
{
  hardware.raspberry-pi.configtxt.overlays = [
    {
      name = "dwc2";
      filters = [ "pi4" ];
      params = [ "dr_mode=host" ];
    }
  ];
}
```

`configtxt.settings` is rendered first. Each entry writes its filters, overlay, and parameters in order, then resets the overlay scope.

An entry with no source uses a stock overlay from the selected kernel. For a custom overlay, set one of `dtsText`, `dtsFile`, or `dtboFile`:

```nix
{
  hardware.raspberry-pi.configtxt.overlays = [
    {
      name = "my-device";
      dtsFile = ./my-device-overlay.dts;
      params = [ "speed=12000000" ];
    }
  ];
}
```

DTS sources are compiled on the build platform and installed as `overlays/<name>.dtbo`. Only one entry for a given name may provide a source, but later source-free entries can apply the same overlay again. A custom source cannot replace a stock overlay with the same name. If the overlay already comes with the selected kernel, use its name without copying its DTS into the configuration.

With managed U-Boot, the Raspberry Pi firmware selects the base DTB and applies these overlays before starting U-Boot. U-Boot must pass that FDT to Linux unchanged, so the module disables generation device trees in `extlinux.conf`. Build-time `hardware.deviceTree.overlays` do not affect this boot path.

## Current limits

- No bootloader module: There's no `boot.loader.raspberry-pi` here. Boards rely on `generic-extlinux-compatible` plus U-Boot. Raspberry Pi OS has the GPU firmware load the kernel directly; we go through U-Boot so it reads `extlinux.conf`, which is what gives you the NixOS boot-generation menu and rollbacks. The firmware install module just stages the boot code and (optionally) U-Boot; it doesn't add a firmware-level direct-boot path. Pi 5 boots from SD via U-Boot, but USB, PCIe, and the RP1 don't come up until Linux takes over, so a USB keyboard at the U-Boot prompt won't work on Pi 5 today.
- Shared firmware device tree: An extlinux rollback selects an older kernel and initrd, but it still uses the current DTB, overlays, and `config.txt` from the shared firmware partition. Generation-specific device-tree rollback needs a firmware-level bootloader and is outside this module.
- Single pinned kernel: `common/kernel.nix` pins one `linux-rpi` version rather than matching each kernel to its firmware release.
- No Pi 0/02/1 board profiles: `common/kernel.nix` accepts `rpiVersion = 1`, but there's no `0/`, `02/`, or `1/` directory wiring that kernel up into a profile you can import via `<nixos-hardware/raspberry-pi/...>`.
