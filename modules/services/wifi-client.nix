{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec.wifiClient;
in
{
  # Client WPA agnostique du pilote : il ne fournit ni pilote ni firmware, juste
  # wpa_supplicant et le rendu du PSK. Les couches carte (UWE5622, ou le
  # BCM4334 de la Transpeed via `hardware.firmware`) apportent le reste.
  #
  # Le PSK n'est jamais dans le store : il est lu au boot dans un fichier fourni
  # par la couche de secrets (ragenix/agenix côté HavenOS, typiquement
  # /run/havenos/wifi-psk), puis recopié dans /run/wpa_supplicant.conf.
  options.nixelec.wifiClient = {
    enable = lib.mkEnableOption "wpa_supplicant client (driver-agnostic)";

    interface = lib.mkOption {
      type = lib.types.str;
      default = "wlan0";
      description = "Wireless interface to drive.";
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
        /run/havenos/wifi-psk). Never put the PSK in the Nix store.
      '';
    };

    extraNetworks = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra `network={...}` blocks appended to the rendered config.";
    };
  };

  config = lib.mkIf cfg.enable {
    # iwd creates and destroys interfaces at startup. Vendors drivers such as
    # sprdwl (UWE5622) unregister the netdevice synchronously and deadlock
    # cfg80211; wpa_supplicant neither creates nor destroys an interface.
    networking.wireless.iwd.enable = lib.mkForce false;

    # `wpa_cli` et `iw` restent utiles au diagnostic sur une console série.
    environment.systemPackages = [
      pkgs.wpa_supplicant
      pkgs.iw
    ];

    systemd.services.wpa-psk = lib.mkIf (cfg.ssid != null && cfg.pskFile != null) {
      description = "Render /run/wpa_supplicant.conf from a secret file";
      wantedBy = [ "wpa-supplicant-${cfg.interface}.service" ];
      before = [ "wpa-supplicant-${cfg.interface}.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        umask 077
        {
          printf 'ctrl_interface=DIR=/run/wpa_supplicant GROUP=wheel\n'
          printf 'network={\n'
          printf '\tssid="%s"\n' "${cfg.ssid}"
          printf '\tpsk="%s"\n' "$(cat "${cfg.pskFile}")"
          printf '}\n'
          ${cfg.extraNetworks}
        } > /run/wpa_supplicant.conf
      '';
    };

    systemd.services."wpa-supplicant-${cfg.interface}" =
      lib.mkIf (cfg.ssid != null && cfg.pskFile != null)
        {
          description = "wpa_supplicant (${cfg.interface})";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network-pre.target"
            "wpa-psk.service"
          ];
          wants = [ "wpa-psk.service" ];
          before = [ "network.target" ];
          serviceConfig = {
            Type = "simple";
            ExecStart = "${pkgs.wpa_supplicant}/sbin/wpa_supplicant -c /run/wpa_supplicant.conf -i ${cfg.interface}";
            Restart = "on-failure";
            RestartSec = 5;
          };
        };
  };
}
