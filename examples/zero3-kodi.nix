{ lib, ... }:

{
  networking.hostName = lib.mkDefault "nixelec-zero3";
  time.timeZone = lib.mkDefault "Europe/Paris";
  system.stateVersion = "26.05";

  nixelec.kodi = {
    enable = true;
    extraKernelParams = [
      "video=HDMI-A-1:1920x1080@60"
      "cfg80211.ieee80211_regdom=FR"
    ];

    # Appliance defaults: no UI sounds, and hide the Estuary menus a TV box
    # does not use.
    uiSounds = true;
    homeMenu.hidden = [
      "music"
      "weather"
      "musicvideos"
      "radio"
      "pictures"
      "games"
    ];

    # HDMI-CEC: keep the appliance running when the TV goes to standby. The
    # boot reprobe covers an invalid physical address after a failed EDID read.
    # The hotplug recovery restarts Kodi and is opt-in.
    cec = {
      enable = true;
      standbyPcOnTvStandby = "ignore";
      reprobeOnBoot = true;
      hotplugRecovery = false;
    };
  };

  # WiFi: enable and provide a PSK file outside the store (agenix, tmpfs...).
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
