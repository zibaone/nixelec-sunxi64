{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:

{
  imports = [ (modulesPath + "/installer/sd-card/sd-image.nix") ];

  # Banc d'essai : installe un noyau de test dans /boot/test et l'arme dans
  # l'extlinux que U-Boot lit réellement (mesuré : il ne scanne pas p1).
  environment.systemPackages = [ (pkgs.callPackage ../../packages/bench { }) ];

  image.fileName = lib.mkDefault "nixelec-sunxi64-${config.hardware.nixbian.board}.img";

  sdImage = {
    compressImage = lib.mkDefault true;

    # nixbian ajoute `root=LABEL=nixos` à la ligne de commande, alors que
    # nixpkgs' sd-image étiquette la partition racine `NIXOS_SD`
    # (`sdImage.rootVolumeLabel` par défaut). Une seule étiquette : sans ça, le
    # `root=` du noyau et le système de fichiers réel se contredisent — sans
    # effet avec l'initrd systemd (qui monte depuis la fstab), mais fatal avec
    # l'initrd classique.
    rootVolumeLabel = lib.mkDefault "nixos";

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

  # nixpkgs déduit le numéro de partition de `lsblk -o MAJ:MIN`, ce qui ne vaut
  # que quand la racine est sur le premier disque mmc (mmcblk0pN → mineur N).
  # Dès qu'elle est sur mmcblk1p2 ou mmcblk2p2, le mineur ne correspond plus au
  # numéro et `sfdisk -N` échoue : la partition n'est jamais agrandie. On lit le
  # numéro dans sysfs, qui est toujours exact.
  systemd.services.expand-root-partition.script = lib.mkForce ''
    rootPart=$(${lib.getExe' pkgs.util-linux "findmnt"} -n -o SOURCE /)
    bootDevice=$(${lib.getExe' pkgs.util-linux "lsblk"} -npo PKNAME "$rootPart")
    partNum=$(${lib.getExe' pkgs.coreutils "cat"} "/sys/class/block/${"$"}{rootPart##*/}/partition")
    echo ",+," | ${lib.getExe' pkgs.util-linux "sfdisk"} -N"$partNum" --no-reread "$bootDevice"
    ${lib.getExe' pkgs.parted "partprobe"}
    ${lib.getExe' pkgs.e2fsprogs "resize2fs"} "$rootPart"
  '';
}
