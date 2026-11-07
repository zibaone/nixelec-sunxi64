{
  config,
  pkgs,
  lib,
  ...
}:

{
  # Transpeed 8K618-T — TV box Allwinner H618 (DDR3-1333 4 Go, eMMC 64 Go).
  #
  # La carte n'existe pas dans Armbian : son entrée vient de
  # `nixbian/src/armbian_extractor/local_boards/transpeed-8k618-t.csc`
  # (defconfig U-Boot `transpeed-8k618-t_defconfig`, DTB mainline).
  #
  # Mesuré au boot0 UART : PMIC AXP1530 (= AXP313a), DDR3 @648 MHz, eMMC
  # 59 640 Mo sur mmc2 (8 bits), vendor U-Boot 2018.07.
  hardware.nixbian.board = lib.mkDefault "transpeed-8k618-t";
  hardware.nixbian.kernelVendor = lib.mkDefault "edge";

  # Ethernet : le RJ45 est sur EMAC1, relié au PHY AC200/AC300 co-packagé
  # (MDIO addr 0). Rien de tout cela n'est dans l'arbre 7.0.14 — mesures et
  # contrat DT complets dans la skill `sunxi-h618-board-bringup`.
  #
  # Posé ici et pas dans `family/sunxi64.nix` : `extraPatches` et
  # `extraConfig` changent l'entrée du noyau, donc son hash. Au niveau
  # famille, la Zero3 et les autres cartes H616 reconstruiraient leur noyau
  # pour rien (parité de cache). La carte porte ses propres faits.
  #
  # `CONFIG_AC300_PHY=y` : le driver PHY doit être enregistré avant le probe
  # du MAC, sinon `genphy` s'attache au PHY et n'en décroche plus.
  # `CONFIG_AW_GMAC=m` + `CONFIG_AW_GMAC_MDIO=m` + `CONFIG_AW_EPHY=m` : le
  # pilote Ethernet retenu est celui du vendor, hors arbre
  # (`packages/sunxi-gmac`). La variante mainline ne reçoit **aucune** trame
  # ici (MAC/DMA/ring prouvés sains par loopback, PHY configuré, `rx_packets`
  # reste à 0), donc `CONFIG_DWMAC_SUN8I` est désactivé sur cette carte.
  # Les .ko restent des modules : un rebuild noyau aarch64 coûte ~45 min,
  # contre ~2 min pour recompiler et transférer un module par UART.
  hardware.nixbian.extraPatches = [
    ../../patches/kernel/0001-net-phy-add-ac300-ephy.patch
    ../../patches/kernel/0002-arm64-dts-h616-emac1-ac300.patch
    ../../patches/kernel/0003-net-stmmac-sun8i-h616-emac1.patch
    ../../patches/kernel/0004-arm64-dts-h616-transpeed-sunxi-gmac.patch
  ];
  hardware.nixbian.extraConfig = lib.mkAfter ''
    CONFIG_AC300_PHY=y
    CONFIG_AW_GMAC=m
    CONFIG_AW_GMAC_MDIO=m
    CONFIG_AW_EPHY=m
    CONFIG_DWMAC_SUN8I=n
    # Le 24 MHz du PHY AC300 est fabriqué par le canal 5 du PWM : le PWM
    # mainline (`sun4i`) ne gère pas H616, c'est le driver vendor qui prend
    # le nœud. Sans lui, pas de `pwm-clock`, donc pas de REF_CLK RMII et le
    # reset du MAC rend `-110`.
    CONFIG_PWM_SUNXI_ENHANCE=m
  '';

  # Ethernet : deux modules hors arbre, chargés dans cet ordre.
  # `pwm-sunxi-enhance` d'abord (il fabrique le 24 MHz du PHY via `pwm-clock`),
  # puis le bus MDIO, puis le MAC. Mesuré : dans le désordre, le PHY tombe sur
  # `genphy` et n'en décroche plus.
  boot.extraModulePackages = [
    (pkgs.callPackage ../../packages/sunxi-gmac {
      kernel = config.boot.kernelPackages.kernel;
    })
  ];
  boot.kernelModules = [
    "pwm-sunxi-enhance"
    "clk-pwm"
    "sunxi-mdio"
    "sunxi-gmac"
    # Dongle USB-Ethernet de secours (CoreChip SR9700, 0fe6:9700). Le pruning
    # des modules ne garde que ce qui est listé dans `boot.kernelModules`, donc
    # sans ces trois lignes `sr9700.ko` disparaît de l'image.
    "usbnet"
    "mii"
    "sr9700"
  ];

  # Broadcom BCM4334 (SDIO 0x02d0:0x4334, module AP6334). Le pilote est
  # `brcmfmac`, dans le noyau : contrairement à l'UWE5622 il n'y a pas de
  # module hors arbre à construire. Le marqueur évite que `nixelec.wifi`
  # (importé pour toute la couche sunxi64) ne compile et ne charge le pilote
  # UWE5622 sur cette carte.
  nixelec.wifiHardware = lib.mkDefault "brcmfmac";

  # Le VE et l'affichage n'ont pas d'IOMMU : tout passe par CMA. 256M est la
  # valeur mesurée sur la Zero 3 ; la box a 4 Go, il n'y a pas à la réduire.
  boot.kernelParams = [ "cma=256M" ];

  # Interface WiFi au nom stable.
  #
  # brcmfmac est un pilote **SDIO** : systemd ne peut pas dériver de nom de bus
  # et renomme le `wlan0` du noyau en `wld1` ("wireless, no bus id"). Un
  # supplicant configuré sur wlan0 échoue alors sur « Interface wlan0 does not
  # exist » — invisible avec `loglevel=3`, et le symptôme se confond avec un
  # problème de PSK. On fige le nom ici plutôt que chez chaque consommateur :
  # la règle suit la carte, pas le profil.
  systemd.network.links."10-brcmfmac-wlan0" = {
    matchConfig.Driver = "brcmfmac";
    linkConfig.Name = "wlan0";
  };

  # Firmware WiFi : trois pièces, toutes indispensables.
  #
  #   - `brcmfmac4334-sdio.bin` (linux-firmware) : le noyau réclame le firmware
  #     du chip *rapporté*, `BCM4334/3` — pas `brcmfmac43340-sdio.bin`, qui est
  #     le nom du module Cypress ;
  #   - `brcmfmac4334-sdio.txt` : la NVRAM, extraite de la partition `vendor` du
  #     dump Android (`nvram_ap6334.txt`, manfid 0x02d0, boardtype 0x05c1). Sans
  #     elle, le firmware se charge mais l'initialisation de la radio échoue ;
  #   - `wireless-regdb` : sans `regulatory.db`, cfg80211 reste sans domaine et
  #     l'association est refusée.
  #
  # Posé ici et non dans l'exemple : une image qui n'hérite pas de ce bloc n'a
  # aucun firmware (`hardware.firmware` ne contient alors que `lib/`), brcmfmac
  # ne crée aucune interface et tout échec en aval (wpa_supplicant sur wlan0)
  # masque la cause réelle.
  hardware.enableRedistributableFirmware = lib.mkForce false;
  hardware.firmware = [
    (pkgs.runCommand "brcmfmac4334-firmware" { } ''
      mkdir -p $out/lib/firmware/brcm
      # Le paquet peut exposer `...-sdio.bin` ou `...-sdio.bin.zst` selon la
      # variante de linux-firmware (compressée ou non) ; le kernel gère les deux.
      for f in ${pkgs.linux-firmware}/lib/firmware/brcm/brcmfmac4334-sdio.bin*; do
        cp -L "$f" $out/lib/firmware/brcm/
      done
      cp ${./firmware/brcmfmac4334-sdio.txt} \
         $out/lib/firmware/brcm/brcmfmac4334-sdio.txt
    '')
    pkgs.wireless-regdb
  ];
  # La NVRAM vendor contient `macaddr=00:90:4c:c5:12:38` (adresse Broadcom de
  # remplissage), mais le firmware utilise la MAC gravée dans l'OTP du chip :
  # l'interface est apparue avec 60:21:c0:b1:2d:be. Pas de collision entre box.
}
