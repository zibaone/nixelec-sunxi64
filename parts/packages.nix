{ inputs, ... }:
let
  # U-Boot de transport, paramétré par le délai d'attente à l'invite.
  #
  # `bootdelay` = 1 pour le service (ne pas rester suspendu quand le réseau ne
  # répond pas). La variante `diag` le passe à 20 pour travailler à l'invite :
  # mesuré qu'à 1 seconde, clé absente, la carte retombe sur l'Android de
  # l'eMMC en fastboot avant la première frappe, et on parle alors au mauvais
  # prompt.
  mkBenchUboot =
    { bootdelay, bootcommand }:
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
          ./../packages/uboot-usb-sr9700/0001-usb-eth-sr9700.patch
          # `usb info` n'affiche pas le VID/PID : on l'ajoute, c'est le
          # seul moyen de reconnaitre une puce sans son pilote.
          ./../packages/uboot-usb-sr9700/0002-usb-info-vid-pid.patch
          ./../packages/uboot-usb-sr9700/0003-diag-usb-match.patch
          # `board_usb_init()` sunxi : sans lui, `ums` répond
          # « Controller uninitialized » (le faible de common/usb.c rend 0).
          ./../packages/uboot-usb-ums/0001-sunxi-board-usb-init.patch
          # En périphérique, la PHY MUSB n'était jamais alimentée : aucun
          # pull-up D+, donc aucun gadget visible côté hôte.
          ./../packages/uboot-usb-ums/0002-musb-sunxi-power-on-phy.patch
          # Trace : `sunxi_musb_enable` est-il seulement appelé en gadget ?
          ./../packages/uboot-usb-ums/0003-musb-sunxi-trace-enable.patch
          # power_on remet ISCR à zéro : réarmer le pull-up D+ ensuite.
          ./../packages/uboot-usb-ums/0004-musb-sunxi-reassert-pullup.patch
        ];
        postPatch = (base.drvAttrs.postPatch or "") + ''
          cp ${./../packages/uboot-sunxi-gmac/sunxi_gmac.c} drivers/net/sunxi_gmac.c
          cp ${./../packages/uboot-usb-sr9700/sr9700.c} drivers/usb/eth/sr9700.c
        '';
        extraConfig = ''
          # `pxe` et non `dhcp` : la cible `dhcp` de distro_bootcmd source
          # le fichier rendu par l'option 67 (variable scriptaddr) et
          # échoue sur une entrée pxelinux, qui est du texte. La cible
          # `pxe` fait `dhcp; pxe get; pxe boot`, donc elle lit la même
          # entrée et en tire KERNEL/INITRD/FDT/APPEND.
          #
          # `initrd_high=~0` : bootm reloge le ramdisk hors de `bootm_size`
          # (23 Mio) vers le haut de la RAM ; une copie de 211 Mio arrive
          # corrompue (« Initramfs unpacking failed »), mesuré en FEL. En
          # 64 bits, seul `~0` coupe la relocation.
          CONFIG_BOOTCOMMAND="${bootcommand}"
          CONFIG_BOOTDELAY=${toString bootdelay}

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
          CONFIG_USB_ETHER_MCS7830=y
          CONFIG_USB_ETHER_LAN75XX=y
          CONFIG_USB_ETHER_LAN78XX=y
          # Les dongles 10/100M pleine vitesse (SR9700 et clones), portés
          # depuis le noyau : aucun pilote amont ne les couvre.
          CONFIG_USB_ETHER_SR9700=y
          # ──────────────────────────────────────────────────────────────
          #  Gadget USB : `ums` expose l'eMMC en stockage de masse
          #
          #  Chemin d'installation le plus court sur ce banc : le cable
          #  A-A sert d'abord au FEL, puis au gadget. L'eMMC apparait
          #  alors comme un disque sur le poste et s'écrit en `dd` a
          #  ~20 Mo/s — une quinzaine de secondes pour l'image, sans
          #  TFTP, sans dongle et sans PHY. Le port OTG est passe en
          #  peripherique dans le DT (`dr_mode`), comme le fait deja le
          #  BROM pour le FEL.
          # ──────────────────────────────────────────────────────────────
          CONFIG_USB_GADGET=y
          CONFIG_USB_MUSB_GADGET=y
          CONFIG_USB_MUSB_SUNXI=y
          # `ums` exige `USB_GADGET_DOWNLOAD` (le cadre g_dnl), pas
          # seulement `USB_GADGET` : sans lui la commande disparait
          # silencieusement du binaire — mesure : « Unknown command ums ».
          CONFIG_USB_GADGET_DOWNLOAD=y
          CONFIG_CMD_USB_MASS_STORAGE=y
          CONFIG_USB_FUNCTION_MASS_STORAGE=y

          # Non couverts par U-Boot mainline, à ce jour : SR9700,
          # DM9601, CH9200 — puces 10/100M pleine vitesse des dongles
          # bon marché. Mesuré le 2026-11-22 : un tel dongle s'énumère
          # en 12 Mb/s sous OHCI, aucun pilote ne s'y lie, et `dhcp`
          # répond « No ethernet found ». Utiliser un RTL8152/8153,
          # AX88772/88179 ou LAN95xx pour le chemin de secours.
        '';
      }
    );
in
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
      # Une seule image netboot pour TOUTE la famille sunxi64 : elle balaie le
      # MDIO, n'applique les quirks AC300 que si la PHY en est une, et rend
      # -ENODEV sinon pour laisser U-Boot passer au dongle USB-Ethernet.
      packages.uboot-sunxi64-netboot = mkBenchUboot {
        bootdelay = 1;
        bootcommand = "usb start; setenv initrd_high 0xffffffffffffffff; setenv fdt_high 0xffffffffffffffff; setenv boot_targets usb0 pxe; run distro_bootcmd";
      };
      packages.uboot-sunxi64-diag = mkBenchUboot {
        bootdelay = 20;
        bootcommand = "usb start; setenv initrd_high 0xffffffffffffffff; setenv fdt_high 0xffffffffffffffff; setenv boot_targets usb0 pxe; run distro_bootcmd";
      };
      # Variante « ums » : le `bootcmd` EST la mise en stockage de masse. Un
      # seul `sunxi-fel -p uboot <image>` pendant le MaskROM et l'eMMC de la
      # carte apparaît en `/dev/sdX` sur le poste — sans console série, sans
      # clé, sans réseau. Sert à installer et à débriquer quand le lien UART
      # du banc est intermittent (mesuré le 2026-11-25 : bursts de 1 Kio
      # perdus, 60 octets passent).
      packages.uboot-sunxi64-ums = mkBenchUboot {
        bootdelay = 0;
        bootcommand = "ums 0 mmc 1";
      };

    };
}
