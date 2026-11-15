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

        **16 caractères maximum** : c'est la limite du champ `s_volume_name`
        d'ext4. `e2label` tronque silencieusement au-delà (avertissement
        « label too long, truncating » puis un label qui ne correspond plus à
        `by-label/…` — la machine ne redémarre plus). Vérifier avec `blkid`
        après écriture, jamais avec `lsblk` seul, qui peut servir une valeur
        en cache.
      '';
      example = "nixelec-8k618";
    };
  };

  config = {
    fileSystems."/" = {
      device = "/dev/disk/by-label/${config.nixelec.emmc.rootLabel}";
      fsType = "ext4";
    };

    # La règle est vérifiée ici, une fois, plutôt que découverte sur la carte :
    # une étiquette trop longue est tronquée par e2label (ext4 limite le champ
    # à 16 octets) et la machine ne redémarre plus. Une étiquette « nixos »
    # réintroduirait l'ambiguïté avec les images du même nom.
    assertions = [
      {
        assertion = builtins.stringLength config.nixelec.emmc.rootLabel <= 16;
        message = ''
          nixelec.emmc.rootLabel fait ${toString (builtins.stringLength config.nixelec.emmc.rootLabel)} caractères : la limite ext4 est de 16.
          e2label tronquerait silencieusement l'étiquette et la machine ne
          retrouverait plus sa racine au démarrage.
        '';
      }
      {
        assertion = config.nixelec.emmc.rootLabel != "nixos";
        message = ''
          nixelec.emmc.rootLabel ne peut pas être « nixos » : c'est l'étiquette
          des images SD, et `root=LABEL=nixos` redeviendrait ambigu dès qu'un
          tel support est branché.
        '';
      }
    ];

    # Outils de banc (console UART, relevés) : fournis par le module d'image
    # pour les configurations SD ; repris ici puisqu'on ne l'importe pas.
    environment.systemPackages = [ (pkgs.callPackage ../../packages/bench { }) ];
  };
}
