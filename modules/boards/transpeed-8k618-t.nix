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

  # Pas de carte son HDMI ici non plus : `/proc/asound/cards` ne liste que
  # `sun4i-codec` (mesure du 2026-11-19) et le DTS amont ne declare pas la
  # carte son HDMI. Laisser le defaut de famille `hw:1,0` ferait pointer Kodi
  # sur un sink PipeWire inexistant et rendrait toutes les sorties muettes ;
  # l'analogique est active par l'hote.
  nixelec.platform.hdmiPcm = lib.mkForce null;

  # Ethernet : le noyau de famille (parts/modules.nix) porte les patches
  # AC300/EMAC1 et la configuration vendor. La carte ne garde ici que les
  # modules hors arbre et leur ordre : `pwm-sunxi-enhance` d'abord, puis le bus
  # MDIO, puis le MAC. Mesuré : dans le désordre, le PHY tombe sur `genphy`.

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

  # Radio mesurée le 2026-11-16 (gen 7pyxiyh) : `mmc1:0001:1` = 0x02d0:0x4334,
  # `brcmfmac` + `brcmfmac_wcc` chargés, `wlan0` portant la MAC OTP ci-dessus,
  # et `iw scan` qui remonte **les deux bandes** (2412/2437/2462 et
  # 5180/5240/5500/5640 MHz). L'intégration est donc complète : ce qui manque
  # n'est pas du code mais un usage (PSK de provisioning).
  #
  # Deux absences visibles dans dmesg, sans effet mesuré sur le scan :
  # le firmware board-specific (`brcm/brcmfmac4334-sdio.transpeed,8k618-t.bin`)
  # et le `clm_blob` — d'où « device may have limited channels available » et
  # `country 00`. Ne pas chasser ces blobs tant qu'un défaut de canal n'est pas
  # constaté : le générique + la NVRAM suffisent à associer.
}
