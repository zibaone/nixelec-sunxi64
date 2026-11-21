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
            # ──────────────────────────────────────────────────────────────
            #  Pilote Ethernet H616 (portage U-Boot du vendor sunxi-gmac)
            #
            #  U-Boot 2025.04 n'a aucun pilote pour l'EMAC du H616 : la table
            #  de compatibles de `sun8i_emac.c` s'arrête à A83T/H3/R40/V3S.
            #  Le portage vit dans `packages/uboot-sunxi-gmac/` : le fichier
            #  est copié dans `drivers/net/`, et le patch ajoute l'entrée
            #  Kconfig, la règle Makefile et le nœud `emac1` du DTS.
            # ──────────────────────────────────────────────────────────────
            patches = (base.drvAttrs.patches or [ ]) ++ [
              ./../packages/uboot-sunxi-gmac/0001-net-sunxi-gmac.patch
            ];
            postPatch = (base.drvAttrs.postPatch or "") + ''
              cp ${./../packages/uboot-sunxi-gmac/sunxi_gmac.c} drivers/net/sunxi_gmac.c
            '';
            extraConfig = ''
              CONFIG_BOOTCOMMAND="usb start; setenv boot_targets usb0 dhcp; run distro_bootcmd"
              CONFIG_BOOTDELAY=1

              # Pilote GMAC vendor porté (EMAC1 + PHY AC300 en RMII).
              CONFIG_SUNXI_GMAC=y
              CONFIG_PHYLIB=y
              # Le pilote dérive la MAC de la SID par SHA-256 (même calcul
              # que nixelec.macFromSid côté noyau).
              CONFIG_SHA256=y

              # ──────────────────────────────────────────────────────────────
              #  Ethernet par dongle USB — filet de sécurité
              #
              #  Tant que le portage n'est pas validé sur la carte, le dongle
              #  USB reste le chemin sûr : l'hôte USB fonctionne déjà (le
              #  defconfig transpeed a `USB_EHCI_HCD` et `USB_OHCI_HCD`, et
              #  U-Boot énumère 4 bus), et ces pilotes rendent `dhcp`/`tftp`
              #  disponibles sans une ligne de code. Le payload de 247 Mio
              #  arrive alors en ~25 s au lieu de 13 min de FEL.
              # ──────────────────────────────────────────────────────────────
              CONFIG_USB_HOST_ETHER=y
              CONFIG_USB_ETHER_ASIX=y
              CONFIG_USB_ETHER_ASIX88179=y
              CONFIG_USB_ETHER_SMSC95XX=y
              CONFIG_USB_ETHER_RTL8152=y
            '';
          }
        );
    };
}
