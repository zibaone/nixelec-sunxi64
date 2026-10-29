# Exemple de base : une carte nue, sans lecteur.
#
# La couche `nixelec-sunxi64` ne porte plus le kiosque : le lecteur vit dans
# `nixelec-kiosk` et le câblage dans le profil de flotte. Cet exemple décrit
# donc ce que la carte publie et rien de plus — noyau nixbian, DTB, U-Boot,
# image SD, WiFi optionnel.
#
# Pour un kiosque, voir `nixelec-kiosk/examples/kiosk-gbm.nix` (plateforme
# imaginaire) ou le profil `kodi-standalone` de la flotte.
{ lib, ... }:

{
  networking.hostName = lib.mkDefault "nixelec-zero3";
  time.timeZone = lib.mkDefault "Europe/Paris";
  system.stateVersion = "26.05";

  # WiFi : le module est exposé par la couche carte (`nixosModules.wifi-uwe5622`)
  # mais n'est pas importé ici. Un PSK ne va pas dans le store.
  # nixelec.wifi.enable = true;
  # nixelec.wifi.ssid = "MyNetwork";
  # nixelec.wifi.pskFile = "/run/agenix/wifi-psk";

  services.openssh.enable = true;
  # Empty by default: add your SSH public key before flashing, otherwise the
  # image has no remote access.
  users.users.root.openssh.authorizedKeys.keys = [ ];

  # Appliance: no unnecessary redistributable firmware. The WiFi firmware is
  # provided by nixelec.wifi; DTB/U-Boot come from nixbian.
  hardware.enableRedistributableFirmware = lib.mkForce false;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
}
