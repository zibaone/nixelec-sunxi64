# Exemple de base : H96 Max H618 nue, sans lecteur — eMMC uniquement.
#
# Sert au bring-up (installation par FEL puis `dd` depuis une clé USB, voir
# `~/bench/h96-2026-11-12/HANDOFF-h96.md`) : console ttyS0 à 115200, SSH avec
# la clé ajoutée avant flash. La couche kiosque vit dans `nixelec-kiosk`.
{ lib, pkgs, ... }:

{
  networking.hostName = lib.mkDefault "nixelec-h96";
  time.timeZone = lib.mkDefault "Europe/Paris";
  system.stateVersion = "26.05";

  services.openssh.enable = true;
  # Vide par défaut : ajouter la clé publique avant de flasher, sinon aucune
  # voie d'accès distante (l'UART reste la console de secours).
  users.users.root.openssh.authorizedKeys.keys = [ ];

  # Bring-up uniquement. La carte n'a ni slot SD ni écran utilisable sans
  # réglage : le seul accès est ttyS0 (ou l'HDMI). Ce mot de passe connu doit
  # disparaître de toute image déployée.
  users.users.root.initialPassword = lib.mkDefault "nixos";

  # Le governor cpufreq `ondemand` fige le noyau 7.0.14 sur cette famille
  # (od_dbs_update → clk_set_parent, puis cache de blocs incohérent et montage
  # de la racine inutilisable). Mesuré sur cette carte : sans ce paramètre le
  # boot s'arrête à l'activation, avec lui il va jusqu'au login. `performance`
  # ne fait plus qu'un set_rate à l'init.
  boot.kernelParams = [ "cpufreq.default_governor=performance" ];

  # Série de l'Ethernet : le module vendor est posé par le module de carte
  # (`modules/boards/h96-max-h618.nix`). `ethtool`/`tcpdump` servent aux
  # essais : un lien qui monte ne prouve pas qu'il passe des trames.
  environment.systemPackages = with pkgs; [
    ethtool
    tcpdump
  ];

  # Accès root au shell d'urgence de l'initrd : sans lui, un échec de montage
  # de la racine laisse la box muette (« Cannot open access to console, the
  # root account is locked »). C'est le seul moyen d'inspecter une eMMC qui ne
  # s'initialise pas. À retirer dès que la carte démarre en production.
  boot.initrd.systemd.emergencyAccess = lib.mkDefault true;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
}
