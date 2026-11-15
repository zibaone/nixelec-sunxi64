# Racine sur eMMC — machine installée, pas une image.
#
# Les configurations de bring-up importent `sd-image`, qui est le module qui
# déclare `fileSystems."/"` et qui étiquette le système `sd-card-…`. Une
# machine installée sur sa eMMC n'est pas une image SD : elle a besoin d'une
# racine déclarée explicitement et d'une étiquette qui lui soit propre.
#
# L'étiquette unique n'est pas cosmétique. `root=LABEL=nixos` est ambigu dès
# qu'un autre support NixOS est présent (carte SD, clé USB portant une image) :
# l'initrd monte le mauvais support et le boot échoue sur « Failed to start
# Find NixOS closure » — vécu sur la Transpeed le 2026-11-15, avec la fermeture
# pourtant bien installée.
{ config, lib, pkgs, ... }:

{
  options.nixelec.emmc = {
    rootLabel = lib.mkOption {
      type = lib.types.str;
      description = ''
        Étiquette de la partition racine de la eMMC. Doit être unique parmi les
        supports que la machine peut voir : c'est elle que le noyau reçoit dans
        `root=` et qu'aucun autre support ne doit porter.
      '';
      example = "nixelec-transpeed";
    };
  };

  config = {
    fileSystems."/" = {
      device = "/dev/disk/by-label/${config.nixelec.emmc.rootLabel}";
      fsType = "ext4";
    };

    # Outils de banc (console UART, relevés) : fournis par le module d'image
    # pour les configurations SD ; repris ici puisqu'on ne l'importe pas.
    environment.systemPackages = [ (pkgs.callPackage ../../packages/bench { }) ];
  };
}
