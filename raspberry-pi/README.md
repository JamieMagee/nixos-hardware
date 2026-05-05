# Raspberry Pi

NixOS profiles and modules for Raspberry Pi boards.

## What's here

- `common/` has the shared bits: the `linux-rpi` kernel build (vendor defconfig, matching firmware), the `config.txt` generation module, and a pinned wireless firmware.
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

These profiles assume `generic-extlinux-compatible`, which is what aarch64 NixOS SD images use by default. U-Boot still has to land on the boot partition somehow. Either your image builder does it, or you do. Nothing in here writes to `/boot/firmware/`. See [Current limits](#current-limits).

## `config.txt`

Board profiles import `hardware.raspberry-pi.configtxt`, which renders `config.txt` from Nix options. The defaults track the Raspberry Pi OS pi-gen image: camera and display autodetect, KMS, audio on, `arm_boost`.

```nix
{
  hardware.raspberry-pi.configtxt.settings = {
    all = {
      dtparam = [ "audio=on" ];
      dtoverlay = [ "vc4-kms-v3d" ];
    };
    pi5.arm_freq = 2400;
    cm4.otg_mode = true;
  };
}
```

Top-level attrs are conditional sections (`all`, `pi4`, `pi5`, `cm4`, and so on). Nesting stacks filters. Lists become repeated keys, which is what you want for `dtparam` and `dtoverlay`. To drop a default, set the key to `null` with `mkForce`.

The rendered file is at `hardware.raspberry-pi.configtxt.file`. Right now nothing reads it on disk. That's the next missing piece.

## Current limits

- No firmware install: Nothing writes `start*.elf`, `bootcode.bin`, `fixup*.dat`, vendor DTBs, overlays, or `config.txt` to `/boot/firmware/`. You either rely on the SD-image populate step or stage those files yourself.
- No bootloader module: There's no `boot.loader.raspberry-pi` here. Boards rely on `generic-extlinux-compatible` plus U-Boot. Pi 5 boots from SD via U-Boot, but USB, PCIe, and the RP1 don't come up until Linux takes over. So a USB keyboard at the U-Boot prompt won't work on Pi 5 today.
- No Pi 0/02/1 profiles: The kernel build supports `rpiVersion = 1`, but no profile imports it yet.
