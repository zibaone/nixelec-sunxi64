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
  imports = [ ./wifi-client.nix ];
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
        /run/agenix/wifi-psk). Never put the PSK in the Nix store.
      '';
    };

    powerSaveOff = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Disable firmware power saving after association.";
    };
  };

  config = lib.mkIf cfg.enable {
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
    nixelec.wifiClient = lib.mkIf cfg.enable {
      enable = true;
      inherit (cfg) interface ssid pskFile;
    };

    systemd.services.wlan-ps-off = lib.mkIf cfg.powerSaveOff {
      description = "Disable WiFi firmware power saving (UWE5622)";
      wantedBy = [ "multi-user.target" ];
      after = [ "wpa-supplicant-${cfg.interface}.service" ];
      serviceConfig = {
        # Type=simple: the script waits for the IPv4 address and then toggles
        # the firmware. With oneshot, multi-user.target would wait for this
        # loop (up to 2 min) and delay boot by as much.
        Type = "simple";
      };
      script = ''
        # cfg80211 already reports power_save=off by default, so setting only
        # `off` is a no-op: nl80211 sees no change and never calls
        # set_power_mgmt. Toggle on then off to force the firmware call; the
        # measured RTT drops to about 7 ms.
        #
        # Wait for association, not just for the netdevice: the driver resets
        # the power-save setting when wpa_supplicant associates, so toggling
        # before that is lost.
        for _ in $(seq 1 120); do
          # The IPv4 address only appears after association and DHCP.
          # Do not test `iw link`: on the UWE5622 it can stay silent for
          # several minutes while power saving is active, which is exactly
          # what prevents disabling it early enough.
          if ${pkgs.iproute2}/bin/ip -4 addr show dev ${cfg.interface} 2>/dev/null | grep -q 'inet '; then
            sleep 1
            ${pkgs.iw}/bin/iw dev ${cfg.interface} set power_save on 2>/dev/null
            sleep 1
            ${pkgs.iw}/bin/iw dev ${cfg.interface} set power_save off 2>/dev/null && exit 0
          fi
          sleep 1
        done
        echo "${cfg.interface}: not associated after 120s; power save left unchanged" >&2
        exit 0
      '';
    };
  };
}
