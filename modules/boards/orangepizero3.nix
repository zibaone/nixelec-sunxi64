{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec.orangepizero3;

  # The SD card is the only block device whose MMC type is "SD"; the WiFi
  # SDIO device reports "SDIO". The MMC numbering is unstable on this DTB
  # (no aliases), so find the device by type instead of hardcoding mmcblk0.
  findSdDevice = ''
    for dev in /dev/mmcblk*; do
      [ -e "$dev" ] || continue
      type="$(cat "/sys/block/$(basename "$dev")/device/type" 2>/dev/null || true)"
      [ "$type" = "SD" ] || continue
      echo "$dev"
      exit 0
    done
    exit 1
  '';
in
{
  options.nixelec.orangepizero3 = {
    softResetOnShutdown = lib.mkEnableOption ''
      Send CMD0 to the SD card from the systemd shutdown ramfs before a
      reboot. This leaves the card in idle state so the BootROM can
      re-initialize it after a warm reset without a power cycle.
    '';

    spiFallback = {
      enable = lib.mkEnableOption ''
        Install `flash-spi-uboot`, which writes the mainline U-Boot fallback
        to the SPI NOR after backing up the current content.
      '';

      device = lib.mkOption {
        type = lib.types.str;
        default = "/dev/mtd0";
        description = "MTD device for the SPI NOR.";
      };
    };
  };

  config = lib.mkMerge [
    {
      # Orange Pi Zero 3 — Allwinner H618, 1/2/4 GB RAM.
      # The `edge` kernel (nixbian) carries the media and audio patches.
      hardware.nixbian.board = lib.mkDefault "orangepizero3";
      hardware.nixbian.kernelVendor = lib.mkDefault "edge";

      # The VPU and display need a large enough contiguous allocation. Measured
      # on the board: CmaFree dropped to 2 MB of 128 while Kodi played a film and
      # a 765-page allocation failed with -16. 256M is the working value.
      boot.kernelParams = [ "cma=256M" ];
    }

    (lib.mkIf cfg.softResetOnShutdown {
      systemd.shutdownRamfs.contents."/lib/systemd/system-shutdown/mmc-softreset".source =
        pkgs.writeShellScript "mmc-softreset" ''
          #!/bin/sh
          [ "$1" = "reboot" ] || exit 0
          dev="$(${findSdDevice})" || exit 0
          ${pkgs.mmc-utils}/bin/mmc softreset "$dev" || true
        '';
      systemd.shutdownRamfs.storePaths = [ pkgs.mmc-utils ];
    })

    (lib.mkIf cfg.spiFallback.enable {
      environment.systemPackages = [
        (pkgs.writeShellApplication {
          name = "flash-spi-uboot";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.mtdutils
          ];
          text = ''
            set -euo pipefail

            img="''${1:-${config.hardware.nixbian.uBoot.package}/u-boot-sunxi-with-spl.bin}"
            dev="''${2:-${cfg.spiFallback.device}}"
            backup_dir="''${BACKUP_DIR:-/var/lib/havenos/spi-backup}"

            if [ "$(id -u)" -ne 0 ]; then
              echo "run as root" >&2
              exit 1
            fi
            if [ ! -e "$dev" ]; then
              echo "missing MTD device: $dev" >&2
              exit 1
            fi
            if [ ! -e "$img" ]; then
              echo "missing U-Boot image: $img" >&2
              exit 1
            fi
            magic="$(dd if="$img" bs=1 skip=4 count=8 status=none)"
            if [ "$magic" != "eGON.BT0" ]; then
              echo "not a sunxi U-Boot image: $img" >&2
              exit 1
            fi

            mkdir -p "$backup_dir"
            backup="$backup_dir/spi-$(date +%Y%m%d-%H%M%S).bin"
            echo "backup: $backup"
            dd if="$dev" of="$backup" bs=1M count=16 status=progress
            sha256sum "$backup"

            echo "writing $img to $dev"
            flashcp -v "$img" "$dev"
            sync

            echo "verify"
            size="$(stat -c%s "$img")"
            dd if="$dev" of=/tmp/spi-readback.bin bs=1 count="$size" status=none
            cmp "$img" /tmp/spi-readback.bin
            rm -f /tmp/spi-readback.bin

            echo "done. Cold boot, check the U-Boot banner on ttyS0, then test a warm reboot."
            echo "restore: flashcp -v $backup $dev"
          '';
        })
      ];
    })
  ];
}
