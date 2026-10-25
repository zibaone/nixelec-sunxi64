{
  config,
  lib,
  modulesPath,
  ...
}:

{
  imports = [ (modulesPath + "/installer/sd-card/sd-image.nix") ];

  image.fileName = lib.mkDefault "nixelec-sunxi64-${config.hardware.nixbian.board}.img";

  sdImage = {
    compressImage = lib.mkDefault true;

    # Nothing in the firmware partition: U-Boot is written raw at offset 8 KiB
    # and the DTB goes to /boot through extlinux.
    populateFirmwareCommands = "";

    populateRootCommands = ''
      mkdir -p ./files/boot
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} \
        -c ${config.system.build.toplevel} -d ./files/boot
    '';

    # Allwinner: the SoC ROM looks for the SPL at offset 8 KiB. The nixpkgs
    # aarch64 profile does not do this (it only knows about Raspberry Pi).
    postBuildCommands = ''
      UBOOT="${config.hardware.nixbian.uBoot.package}"
      if [ -f "$UBOOT/u-boot-sunxi-with-spl.bin" ]; then
        dd if="$UBOOT/u-boot-sunxi-with-spl.bin" \
           of=$img bs=1024 seek=8 conv=notrunc status=none
      elif [ -f "$UBOOT/u-boot.bin" ]; then
        dd if="$UBOOT/u-boot.bin" \
           of=$img bs=1024 seek=8 conv=notrunc status=none
      else
        echo "U-Boot not found in $UBOOT" >&2
        exit 1
      fi
    '';
  };
}
