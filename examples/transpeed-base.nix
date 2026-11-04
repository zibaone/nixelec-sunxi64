# Exemple de base : Transpeed 8K618-T nue, sans lecteur.
#
# Sert au bring-up (SD d'abord) : console ttyS0 à 115200, SSH avec la clé
# ajoutée avant flash. La couche kiosque vit dans `nixelec-kiosk`.
{ lib, ... }:

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

  hardware.enableRedistributableFirmware = lib.mkForce false;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
}
