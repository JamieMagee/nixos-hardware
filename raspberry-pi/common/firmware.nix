# Firmware-partition install for Raspberry Pi.
#
# Stages the files the Pi needs before Linux starts onto the firmware partition
# (default /boot/firmware): GPU boot code (bootcode.bin, start*.elf, fixup*.dat),
# kernel-matched device trees and overlays, the rendered config.txt, and
# optionally U-Boot. Not a new boot method: boards still use
# boot.loader.generic-extlinux-compatible (U-Boot reads extlinux.conf); this just
# provides the files that path needs, either at SD-image build time
# (sdImage.populateFirmwareCommands, wired automatically) or on a running system
# (the opt-in activation script).
#
# DTB/overlay copy adapted from nvmd/nixos-raspberrypi (MIT).

{
  lib,
  config,
  options,
  pkgs,
  ...
}:

let
  cfg = config.hardware.raspberry-pi.firmware;
  configTxtCfg = config.hardware.raspberry-pi.configtxt;
  kernel = config.boot.kernelPackages.kernel;
  defaultDeviceTreeSource = "${kernel}/dtbs";
  defaultUboot = pkgs.buildUBoot {
    defconfig = "rpi_arm64_defconfig";
    extraMeta.platforms = [ "aarch64-linux" ];
    filesToInstall = [ "u-boot.bin" ];
  };
  kernelOverlayReadme =
    if toString cfg.deviceTree.source == defaultDeviceTreeSource && kernel ? src then
      "${kernel.src}/arch/arm/boot/dts/overlays/README"
    else
      null;

  hasSource = overlay: overlay.dtsText != null || overlay.dtsFile != null || overlay.dtboFile != null;

  compileOverlay =
    overlay:
    if overlay.dtboFile != null then
      overlay.dtboFile
    else
      pkgs.buildPackages.deviceTree.compileDTS {
        name = "${overlay.name}-dtbo";
        dtsFile =
          if overlay.dtsFile != null then
            overlay.dtsFile
          else
            pkgs.buildPackages.writeText "${overlay.name}.dts" overlay.dtsText;
        includePaths = [
          "${lib.getDev kernel}/lib/modules/${kernel.modDirVersion}/source/scripts/dtc/include-prefixes"
        ]
        ++ config.hardware.deviceTree.dtboBuildExtraIncludePaths;
        extraPreprocessorFlags = config.hardware.deviceTree.dtboBuildExtraPreprocessorFlags;
      };

  customOverlays = map (overlay: {
    inherit (overlay) name;
    file = compileOverlay overlay;
  }) (lib.filter hasSource configTxtCfg.overlays);

  firmwareBundle =
    pkgs.buildPackages.runCommand "raspberry-pi-firmware"
      {
        nativeBuildInputs = [ pkgs.buildPackages.dtc ];
      }
      ''
        export LC_ALL=C
        shopt -s nullglob
        mkdir -p "$out/files/overlays"
        declare -A bundlePaths
        declare -A mappedOverlayNames
        declare -A stockOverlayNames

        copyUnique() {
          local src="$1"
          local dst="$2"
          local path
          local key

          path="''${dst#"$out/files/"}"
          key="''${path,,}"
          if [ -n "''${bundlePaths[$key]+x}" ]; then
            echo "rpi-firmware: bundle path collision: $path" >&2
            exit 1
          fi

          mkdir -p "$(dirname "$dst")"
          cp -- "$src" "$dst"
          bundlePaths["$key"]="$path"
        }

        dtbSource=${lib.escapeShellArg (toString cfg.deviceTree.source)}
        dtbCount=0
        for src in "$dtbSource"/*.dtb "$dtbSource"/broadcom/*.dtb; do
          copyUnique "$src" "$out/files/$(basename "$src")"
          dtbCount=$((dtbCount + 1))
        done

        if [ "$dtbCount" -eq 0 ]; then
          echo "rpi-firmware: no base DTBs found in $dtbSource" >&2
          exit 1
        fi

        if [ -d "$dtbSource/overlays" ]; then
          for src in "$dtbSource"/overlays/*; do
            [ -f "$src" ] || continue
            copyUnique "$src" "$out/files/overlays/$(basename "$src")"
          done
        fi

        if [ ! -f "$out/files/overlays/README" ]; then
          ${
            if kernelOverlayReadme != null then
              ''
                if [ ! -f ${lib.escapeShellArg kernelOverlayReadme} ]; then
                  echo "rpi-firmware: overlay README not found" >&2
                  exit 1
                fi
                copyUnique ${lib.escapeShellArg kernelOverlayReadme} "$out/files/overlays/README"
              ''
            else
              ''
                echo "rpi-firmware: overlay README not found in the device-tree source" >&2
                exit 1
              ''
          }
        fi

        for path in overlays/README overlays/overlay_map.dtb overlays/hat_map.dtb; do
          if [ ! -f "$out/files/$path" ]; then
            echo "rpi-firmware: required device-tree file not found: $path" >&2
            exit 1
          fi
        done

        for src in "$out/files/overlays"/*.dtbo; do
          name="$(basename "$src" .dtbo)"
          stockOverlayNames["''${name,,}"]="$name"
        done
        mapNames="$TMPDIR/overlay-map-names"
        if ! fdtget -l "$out/files/overlays/overlay_map.dtb" / > "$mapNames"; then
          echo "rpi-firmware: failed to read overlays/overlay_map.dtb" >&2
          exit 1
        fi
        while IFS= read -r name; do
          [ -n "$name" ] || continue
          mappedOverlayNames["$name"]=1
          stockOverlayNames["''${name,,}"]="$name"
        done < "$mapNames"

        copyCustomOverlay() {
          local name="$1"
          local src="$2"
          local key="''${name,,}"

          if [ -n "''${stockOverlayNames[$key]+x}" ]; then
            echo "rpi-firmware: custom overlay conflicts with stock overlay: $name" >&2
            exit 1
          fi
          copyUnique "$src" "$out/files/overlays/$name.dtbo"
        }

        ${lib.concatMapStringsSep "\n" (overlay: ''
          copyCustomOverlay ${lib.escapeShellArg overlay.name} ${lib.escapeShellArg (toString overlay.file)}
        '') customOverlays}

        firmwareBoot=${lib.escapeShellArg "${cfg.package}/share/raspberrypi/boot"}
        startFiles=("$firmwareBoot"/start*.elf)
        fixupFiles=("$firmwareBoot"/fixup*.dat)
        if [ ! -f "$firmwareBoot/bootcode.bin" ] || [ "''${#startFiles[@]}" -eq 0 ] || [ "''${#fixupFiles[@]}" -eq 0 ]; then
          echo "rpi-firmware: firmware package is missing bootcode.bin, start*.elf, or fixup*.dat" >&2
          exit 1
        fi
        for src in "''${startFiles[@]}"; do
          suffix="$(basename "$src")"
          suffix="''${suffix#start}"
          suffix="''${suffix%.elf}"
          if [ ! -f "$firmwareBoot/fixup$suffix.dat" ]; then
            echo "rpi-firmware: firmware package has no fixup$suffix.dat for $(basename "$src")" >&2
            exit 1
          fi
        done
        for src in "''${fixupFiles[@]}"; do
          suffix="$(basename "$src")"
          suffix="''${suffix#fixup}"
          suffix="''${suffix%.dat}"
          if [ ! -f "$firmwareBoot/start$suffix.elf" ]; then
            echo "rpi-firmware: firmware package has no start$suffix.elf for $(basename "$src")" >&2
            exit 1
          fi
        done
        for src in "$firmwareBoot/bootcode.bin" "''${startFiles[@]}" "''${fixupFiles[@]}"; do
          copyUnique "$src" "$out/files/$(basename "$src")"
        done

        ${lib.optionalString cfg.uboot.enable ''
          copyUnique ${lib.escapeShellArg "${cfg.uboot.package}/u-boot.bin"} "$out/files/u-boot.bin"
        ''}

        copyUnique ${lib.escapeShellArg (toString configTxtCfg.file)} "$out/files/config.txt"

        while IFS= read -r overlay; do
          [ -n "$overlay" ] || continue
          path="overlays/$overlay.dtbo"
          key="''${path,,}"
          if [ -z "''${bundlePaths[$key]+x}" ] && [ -z "''${mappedOverlayNames[$overlay]+x}" ]; then
            echo "rpi-firmware: config.txt references missing overlay: $overlay" >&2
            exit 1
          fi
        done < <(sed -nE 's/^[[:space:]]*(dtoverlay|device_tree_overlay)[[:space:]]*=[[:space:]]*([^,[:space:]#]*).*/\2/p' "$out/files/config.txt")

        (cd "$out/files" && find . -type f -printf '%P\n' | LC_ALL=C sort) > "$out/manifest"
      '';

  # install-rpi-firmware <bundle> <target-dir>
  installScriptArgs = {
    name = "install-rpi-firmware";
    text = ''
      export LC_ALL=C
      bundle="$1"
      logicalTarget="$(realpath -sm -- "$2")"
      resolvedTarget="$(realpath -m -- "$2")"
      if [ "$logicalTarget" != "$resolvedTarget" ]; then
        echo "rpi-firmware: target path must not contain symbolic links: $2" >&2
        exit 1
      fi
      target="$logicalTarget"
      files="$bundle/files"
      newManifest="$bundle/manifest"
      targetManifest="$target/.nixos-hardware-raspberry-pi.manifest"

      declare -A oldPaths
      declare -A newPaths

      validatePath() {
        local path="$1"
        local part
        local -a parts

        [ -n "$path" ] && [[ "$path" != /* ]] && [[ "$path" != *$'\r'* ]] || return 1
        IFS=/ read -ra parts <<< "$path"
        for part in "''${parts[@]}"; do
          [ -n "$part" ] && [ "$part" != . ] && [ "$part" != .. ] || return 1
        done
      }

      loadManifest() {
        local manifest="$1"
        local requireFiles="$2"
        local path
        local key
        local -n paths="$3"

        while IFS= read -r path || [ -n "$path" ]; do
          if ! validatePath "$path"; then
            echo "rpi-firmware: invalid manifest path: $path" >&2
            exit 1
          fi
          if [ "$requireFiles" = 1 ] && [ ! -f "$files/$path" ]; then
            echo "rpi-firmware: bundle file missing: $path" >&2
            exit 1
          fi
          key="''${path,,}"
          if [ -n "''${paths[$key]+x}" ]; then
            echo "rpi-firmware: case-insensitive manifest path collision: $path" >&2
            exit 1
          fi
          # Assigned through a nameref and read by the caller.
          # shellcheck disable=SC2034
          paths["$key"]="$path"
        done < "$manifest"
      }

      copyForced() {
        local src="$1"
        local dst="$2"
        local dir
        local base
        local tmp

        dir="$(dirname "$dst")"
        base="$(basename "$dst")"
        mkdir -p "$dir"
        tmp="$(mktemp "$dir/.$base.nixos-hardware.XXXXXX")"
        if ! cp -- "$src" "$tmp"; then
          rm -f -- "$tmp"
          return 1
        fi
        mv -- "$tmp" "$dst"
      }

      checkParents() {
        local path="$1"
        local parent

        parent="$(dirname "$path")"
        while [ "$parent" != . ]; do
          if [ -L "$target/$parent" ] || { [ -e "$target/$parent" ] && [ ! -d "$target/$parent" ]; }; then
            echo "rpi-firmware: parent path is not a directory: $parent" >&2
            exit 1
          fi
          parent="$(dirname "$parent")"
        done
      }

      loadManifest "$newManifest" 1 newPaths

      hadOldManifest=false
      if [ -L "$targetManifest" ] || { [ -e "$targetManifest" ] && [ ! -f "$targetManifest" ]; }; then
        echo "rpi-firmware: target manifest is not a regular file" >&2
        exit 1
      elif [ -f "$targetManifest" ]; then
        hadOldManifest=true
        loadManifest "$targetManifest" 0 oldPaths
      else
        echo "rpi-firmware: no previous manifest; unmanaged files will be kept" >&2
      fi

      # Check every collision and parent directory before changing the target.
      while IFS= read -r path || [ -n "$path" ]; do
        dst="$target/$path"
        key="''${path,,}"
        checkParents "$path"

        if [ -L "$dst" ] || { [ -e "$dst" ] && [ ! -f "$dst" ]; }; then
          echo "rpi-firmware: target path is not a regular file: $path" >&2
          exit 1
        fi

        if [ "$hadOldManifest" = true ] && [ -n "''${oldPaths[$key]+x}" ] && [ "''${oldPaths[$key]}" != "$path" ]; then
          echo "rpi-firmware: case-only path change is not supported: ''${oldPaths[$key]} -> $path" >&2
          exit 1
        fi

        if [ -e "$dst" ] && [ "$hadOldManifest" = true ] && [ -z "''${oldPaths[$key]+x}" ]; then
          if [ ! -f "$dst" ] || ! cmp -s "$files/$path" "$dst"; then
            echo "rpi-firmware: unmanaged path collision: $path" >&2
            exit 1
          fi
        fi
      done < "$newManifest"

      if [ "$hadOldManifest" = true ]; then
        while IFS= read -r path || [ -n "$path" ]; do
          key="''${path,,}"
          if [ -z "''${newPaths[$key]+x}" ]; then
            checkParents "$path"
            if [ -L "$target/$path" ] || { [ -e "$target/$path" ] && [ ! -f "$target/$path" ]; }; then
              echo "rpi-firmware: stale target path is not a regular file: $path" >&2
              exit 1
            fi
          fi
        done < "$targetManifest"
      fi

      mkdir -p "$target"
      while IFS= read -r path || [ -n "$path" ]; do
        [ "$path" = config.txt ] || copyForced "$files/$path" "$target/$path"
      done < "$newManifest"

      if [ -n "''${newPaths[config.txt]+x}" ]; then
        copyForced "$files/config.txt" "$target/config.txt"
      fi

      if [ "$hadOldManifest" = true ]; then
        while IFS= read -r path || [ -n "$path" ]; do
          key="''${path,,}"
          if [ -z "''${newPaths[$key]+x}" ]; then
            rm -f -- "$target/$path"
          fi
        done < "$targetManifest"
      fi

      copyForced "$newManifest" "$targetManifest"
      echo "rpi-firmware: done ($target)"
    '';
  };

  mkInstallScript =
    scriptPkgs:
    scriptPkgs.writeShellApplication (
      installScriptArgs
      // {
        runtimeInputs = [
          scriptPkgs.coreutils
          scriptPkgs.diffutils
        ];
      }
    );

  # Target tools for activation, build tools for images.
  installScript = mkInstallScript pkgs;
  imageInstallScript = mkInstallScript pkgs.buildPackages;
in
{
  options.hardware.raspberry-pi.firmware = {
    enable = lib.mkEnableOption ''
      installation of the Raspberry Pi firmware partition on a running system.

      An activation script repopulates {option}`hardware.raspberry-pi.firmware.path`
      on every system switch
    '';

    path = lib.mkOption {
      type = lib.types.str;
      default = "/boot/firmware";
      description = ''
        Mount point of the Raspberry Pi firmware (FAT) partition.

        `/boot/firmware` matches the NixOS aarch64 SD-image layout, and most
        configurations should leave it there. The activation script writes here
        only when it is a mounted partition (checked with `mountpoint`);
        otherwise it logs a warning and skips.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.raspberrypifw;
      defaultText = lib.literalExpression "pkgs.raspberrypifw";
      description = ''
        Package providing Raspberry Pi GPU boot code under
        `''${package}/share/raspberrypi/boot`.
      '';
    };

    deviceTree.source = lib.mkOption {
      type = lib.types.path;
      default = defaultDeviceTreeSource;
      defaultText = lib.literalExpression ''"''${config.boot.kernelPackages.kernel}/dtbs"'';
      description = ''
        Raw device trees and overlays to install on the firmware partition.

        The directory must contain base DTBs at its root or under `broadcom/`,
        plus an `overlays/` directory containing compiled overlays and
        `README`, `overlay_map.dtb`, and `hat_map.dtb`.
      '';
    };

    uboot = {
      enable = lib.mkEnableOption ''
        chainloading U-Boot from the Raspberry Pi firmware.

        Copies `u-boot.bin` from
        {option}`hardware.raspberry-pi.firmware.uboot.package` to the firmware
        partition and points `config.txt`'s `kernel` at it, so the GPU firmware
        loads U-Boot, which then reads `extlinux.conf`
      '';

      package = lib.mkOption {
        type = lib.types.package;
        default = defaultUboot;
        defaultText = lib.literalExpression ''
          pkgs.buildUBoot {
            defconfig = "rpi_arm64_defconfig";
            extraMeta.platforms = [ "aarch64-linux" ];
            filesToInstall = [ "u-boot.bin" ];
          }
        '';
        description = ''
          U-Boot package whose `u-boot.bin` is copied to the firmware
          partition when {option}`hardware.raspberry-pi.firmware.uboot.enable`
          is enabled.

          The default uses nixpkgs' `rpi_arm64_defconfig`, which covers the
          64-bit boards (Pi 3/4/5). For a 32-bit board, override this with the
          matching U-Boot package.
        '';
      };
    };

  };

  config = lib.mkMerge [
    {
      system.build.raspberryPiFirmware = firmwareBundle;
    }
    (lib.mkIf cfg.uboot.enable {
      # Chainload U-Boot: the GPU firmware loads u-boot.bin, which then reads
      # extlinux.conf. mkDefault so an explicit kernel setting still wins.
      hardware.raspberry-pi.configtxt.settings.all = {
        kernel = lib.mkDefault "u-boot.bin";
        # Default U-Boot is 64-bit, but the firmware loads kernel= in 32-bit
        # mode unless arm_64bit=1.
        arm_64bit = lib.mkDefault pkgs.stdenv.hostPlatform.isAarch64;
      };

      # The GPU firmware merges config.txt dtoverlays into the DTB it hands to
      # U-Boot. The default (true) adds an FDTDIR line to extlinux.conf, so
      # U-Boot reloads bare dtbs and drops the overlays.
      boot.loader.generic-extlinux-compatible.useGenerationDeviceTree = lib.mkDefault false;

      assertions = [
        {
          assertion = config.boot.loader.generic-extlinux-compatible.enable;
          message = "Raspberry Pi managed U-Boot requires generic-extlinux-compatible.";
        }
        {
          assertion = !config.boot.loader.generic-extlinux-compatible.useGenerationDeviceTree;
          message = "Raspberry Pi managed U-Boot must preserve the firmware device tree.";
        }
      ];

      warnings =
        lib.optional
          (
            !config.boot.loader.generic-extlinux-compatible.useGenerationDeviceTree
            && config.hardware.deviceTree.overlays != [ ]
          )
          ''
            Raspberry Pi build-time device-tree overlays are ignored when U-Boot
            preserves the firmware device tree. Use hardware.raspberry-pi.configtxt.overlays instead.
          '';
    })
    # Stage the firmware partition at SD-image build time, only when an
    # sd-image module is imported. mkForce so we override (not merge with)
    # sd-image-aarch64.nix, which also sets this and would clobber config.txt.
    (lib.optionalAttrs (options ? sdImage) {
      sdImage.populateFirmwareCommands = lib.mkForce "${lib.getExe imageInstallScript} ${firmwareBundle} ./firmware\n";
      hardware.raspberry-pi.firmware.uboot.enable = lib.mkDefault pkgs.stdenv.hostPlatform.isAarch64;
    })
    (lib.mkIf cfg.enable {
      system.activationScripts.raspberry-pi-firmware = lib.stringAfter [ "specialfs" ] ''
        if mountpoint -q ${lib.escapeShellArg cfg.path}; then
          ${lib.getExe installScript} ${firmwareBundle} ${lib.escapeShellArg cfg.path}
        else
          echo "rpi-firmware: ${cfg.path} is not a mounted partition, skipping firmware install" >&2
        fi
      '';
    })
  ];
}
