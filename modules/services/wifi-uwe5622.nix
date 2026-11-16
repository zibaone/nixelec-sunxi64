{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec.wifi;

  firmware = pkgs.callPackage ../../packages/uwe5622-firmware { };

  driver = pkgs.callPackage ../../packages/uwe5622 {
    kernel = config.boot.kernelPackages.kernel;
  };
in
{
  options.nixelec.wifi = {
    enable = lib.mkEnableOption "Unisoc UWE5622 (AW859A) WiFi";

    interface = lib.mkOption {
      type = lib.types.str;
      default = "wlan0";
      description = "WiFi interface created by the driver.";
    };

    ssid = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "SSID to associate with. If null, wpa_supplicant is not started.";
    };

    pskFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path to a file containing the PSK, read at boot (for example
        /run/agenix/wifi-psk). Never put the PSK in the Nix store. Used only
        when `networksFile` is null or unreadable.
      '';
    };

    networksFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path to a complete wpa_supplicant configuration, read at boot and used
        verbatim (`nixelec.wifiClient.networksFile`). Takes precedence over
        `ssid`/`pskFile`, which stay the fallback.
      '';
    };

    powerSaveOff = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Disable firmware power saving after association.";
    };
  };

  # Le pilote n'a de sens que sur une carte qui porte réellement l'UWE5622 :
  # la couche sunxi64 importe ce module pour toutes ses cartes, et la Transpeed
  # a un Broadcom SDIO. Le marqueur est posé par chaque module de carte.
  # Défaut `uwe5622` quand `nixelec.wifiHardware` n'existe pas (module importé
  # seul, sans la couche famille) : on conserve alors l'ancien comportement.
  config = lib.mkIf (cfg.enable && (config.nixelec.wifiHardware or "uwe5622") == "uwe5622") {
    # The driver is out of tree. sunxi_addr provides the MAC address and is
    # pruned from the module tree. `boot.kernelModules` puts it back into the
    # allowlist.
    boot.extraModulePackages = [ driver ];
    boot.kernelModules = [
      "sunxi_addr"
      "uwe5622_bsp_sdio"
      "sprdwl_ng"
    ];

    # The driver reads firmware and calibration through filp_open, not
    # request_firmware: it does not decompress hardware.firmware `.zst` files.
    # Expose both files uncompressed in /etc/uwe5622.
    environment.etc."uwe5622/wcnmodem.bin".source = "${firmware}/lib/firmware/uwe5622/wcnmodem.bin";
    environment.etc."uwe5622/wifi_2355b001_1ant.ini".source =
      "${firmware}/lib/firmware/uwe5622/wifi_2355b001_1ant.ini";

    # The kernel has no CONFIG_FW_LOADER_COMPRESS: keep regulatory.db
    # uncompressed so cfg80211 can load it (NixOS would zstd it otherwise).
    hardware.firmware = [
      (pkgs.wireless-regdb.overrideAttrs (_: {
        compressFirmware = false;
      }))
    ];

    # Le PSK et wpa_supplicant sont fournis par le module client générique :
    # même comportement qu'avant, mais réutilisable par une carte dont le pilote
    # WiFi n'est pas l'UWE5622 (Broadcom SDIO de la Transpeed par exemple).
    # `networksFile` est transmis tel quel : cette couche ne choisit pas la
    # source, elle laisse la priorité au fichier de réseaux.
    nixelec.wifiClient = lib.mkIf cfg.enable {
      enable = true;
      inherit (cfg)
        interface
        ssid
        pskFile
        networksFile
        powerSaveOff
        ;
    };
  };
}
