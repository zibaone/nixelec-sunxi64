{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      formatter = pkgs.nixfmt;

      packages.uwe5622-firmware = pkgs.callPackage ../packages/uwe5622-firmware { };
      packages.aic8800-firmware = pkgs.callPackage ../packages/aic8800-firmware { };
      packages.bench = pkgs.callPackage ../packages/bench { };
      packages.fd6xx = inputs.nixelec-common.packages.${pkgs.stdenv.hostPlatform.system}.fd6xx;

      # ── U-Boot de transport : variante netboot ──────────────────────────
      #
      # Le FEL plafonne à ~316 Ko/s (mesuré) : les 247 Mio du payload, c'est
      # 13 minutes par carte. Cette variante inverse l'ordre de démarrage
      # (`boot_targets=dhcp`) pour que le même payload arrive par le réseau, à
      # la vitesse du LAN. Elle se construit sur l'U-Boot de la carte avec un
      # `extraConfig` : rien d'autre ne change, et `bootdelay=1` évite de
      # rester suspendu à une invite si le réseau ne répond pas.
      #
      # Elle vit ici, et pas dans HavenOS, pour que la CI aarch64 de ce dépôt
      # la construise et la pousse au cache : un utilisateur public ne doit pas
      # compiler U-Boot pour installer une carte.
      packages.uboot-h96-max-h618-netboot =
        let
          pkgsAarch64 = inputs.nixpkgs.legacyPackages.aarch64-linux;
          base = inputs.nixbian.packages.aarch64-linux.uboot-transpeed-8k618-t-edge;
        in
        pkgsAarch64.buildUBoot (
          base.drvAttrs
          // {
            extraConfig = ''
              CONFIG_BOOTCOMMAND="setenv boot_targets dhcp; run distro_bootcmd"
              CONFIG_BOOTDELAY=1
            '';
          }
        );
    };
}
