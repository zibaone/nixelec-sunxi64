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

  # WiFi BCM4334 (SDIO 0x02d0:0x4334). Le driver rapporte « BCM4334/3 » et
  # demande donc `brcm/brcmfmac4334-sdio`, pas `43340` : dans linux-firmware,
  # `brcmfmac43340-sdio.bin` est un lien vers le firmware **Cypress** tandis que
  # `brcmfmac4334-sdio.bin` est le binaire Broadcom (301 941 o) qui correspond à
  # ce chip. Trois pièces sont nécessaires :
  #   - `brcm/brcmfmac4334-sdio.bin` : fourni par linux-firmware ;
  #   - `brcm/brcmfmac4334-sdio.txt` : la NVRAM, propre à la carte, absente de
  #     linux-firmware. Elle vient de la partition `vendor` du dump Android
  #     (`nvram_ap6334.txt`, manfid 0x02d0 / boardtype 0x05c1 / boardnum 22) ;
  #   - `brcmfmac` chargé au boot (voir `sunxi64.nix`).
  #
  # brcmfmac tente d'abord un nom spécifique à la carte, dérivé du `compatible`
  # (`brcmfmac4334-sdio.transpeed,8k618-t.bin`), puis retombe sur le nom
  # générique : inutile de dupliquer les fichiers.
  #
  # On n'active volontairement PAS `enableRedistributableFirmware` : il embarque
  # les 826 Mo de linux-firmware et fait passer l'image de 590 Mo à 1,5 Go. On
  # ne copie que les fichiers utiles — c'est le module de carte
  # (`modules/boards/transpeed-8k618-t.nix`) qui les pose désormais, avec
  # `wireless-regdb` : une image qui n'hérite pas de ce bloc n'a aucun firmware.

  # WiFi : le PSK n'est jamais dans ce dépôt. Il est rendu au boot depuis un
  # fichier fourni par la couche de secrets — côté HavenOS, ragenix le dépose
  # dans /run/havenos/wifi-psk (même contrat que le kiosque Zero 3). Tant que
  # `ssid`/`pskFile` sont nuls, aucun supplicant ne démarre : l'image de
  # bring-up reste utilisable sans identifiants.
  nixelec.wifiClient = {
    enable = true;
    interface = "wlan0";
    ssid = null;
    pskFile = null;
  };

  # Nom d'interface stable : la règle `.link` est posée par le module de carte
  # (`modules/boards/transpeed-8k618-t.nix`), elle suit la carte et pas
  # l'exemple — voir le commentaire là-bas.

  # Firmware WiFi (4334 + NVRAM + wireless-regdb) : posé par le module de carte.


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
