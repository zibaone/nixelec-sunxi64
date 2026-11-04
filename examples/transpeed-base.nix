# Exemple de base : Transpeed 8K618-T nue, sans lecteur.
#
# Sert au bring-up (SD d'abord) : console ttyS0 à 115200, SSH avec la clé
# ajoutée avant flash. La couche kiosque vit dans `nixelec-kiosk`.
{ lib, pkgs, ... }:

{
  networking.hostName = lib.mkDefault "nixelec-transpeed";
  time.timeZone = lib.mkDefault "Europe/Paris";
  system.stateVersion = "26.05";

  services.openssh.enable = true;
  # Vide par défaut : ajouter la clé publique avant de flasher, sinon aucune
  # voie d'accès distante (l'UART reste la console de secours).
  users.users.root.openssh.authorizedKeys.keys = [ ];

  # Bring-up uniquement : sans réseau (pas de PHY Ethernet mainline, WiFi sans
  # NVRAM) et sans clé SSH, le seul accès est ttyS0 ou l'HDMI. Un compte root
  # sans mot de passe rend le prompt de connexion inutilisable ; ce mot de
  # passe connu doit disparaître de toute image déployée.
  users.users.root.initialPassword = lib.mkDefault "nixos";

  # WiFi BCM4334 (SDIO 0x02d0:0x4334, « AP6334 »). Trois pièces sont
  # nécessaires et une seule vient de linux-firmware :
  #   - `brcm/brcmfmac43340-sdio.bin` : fourni par linux-firmware, donc il faut
  #     autoriser les firmwares redistribuables (le `mkForce false` ci-dessus) ;
  #   - `brcm/brcmfmac43340-sdio.txt` : la NVRAM, propre à la carte, absente de
  #     linux-firmware. Elle vient de la partition `vendor` du dump Android
  #     (`nvram_ap6334.txt`, manfid 0x02d0 / boardtype 0x05c1 / boardnum 22),
  #     renommée au nom que brcmfmac dérive du chip ;
  #   - le module `brcmfmac`, chargé explicitement (voir `sunxi64.nix`).
  # La NVRAM fixe `macaddr=00:90:4c:c5:12:38` : plusieurs box partageraient la
  # même MAC, à remplacer par une adresse par appareil avant tout déploiement.
  hardware.enableRedistributableFirmware = lib.mkForce true;

  hardware.firmware = [
    (pkgs.runCommand "brcmfmac43340-nvram" { } ''
      mkdir -p $out/lib/firmware/brcm
      cp ${./transpeed-firmware/brcmfmac43340-sdio.txt} \
         $out/lib/firmware/brcm/brcmfmac43340-sdio.txt
    '')
  ];

  # Bring-up : accès root sans mot de passe au shell d'urgence de l'initrd.
  # Sans lui, un échec de montage de la racine laisse la box muette (« Cannot
  # open access to console, the root account is locked ») : c'est le seul moyen
  # d'inspecter un slot SD qui ne s'initialise pas. À retirer dès que la carte
  # démarre.
  boot.initrd.systemd.emergencyAccess = lib.mkDefault true;

  # Le governor cpufreq `ondemand` fait crasher le noyau 7.0.14 sur cette box :
  # od_dbs_update → dev_pm_opp_set_rate → clk_set_parent → clk_reparent, avec
  # des LIST_POISON (dead000000000100) dans la liste des enfants de l'horloge
  # CPU. Le reparentage laisse ensuite le cache de blocs incohérent (flood
  # __find_get_block_slow) et le montage de la racine devient inutilisable.
  # `performance` ne fait plus qu'un set_rate à l'init, comme au démarrage.
  boot.kernelParams = [ "cpufreq.default_governor=performance" ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
}
