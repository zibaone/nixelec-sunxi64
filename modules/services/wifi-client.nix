{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec.wifiClient;

  # Deux sources possibles pour /run/wpa_supplicant.conf :
  #  - `networksFile` : la donnée (secret M2) rendue au boot, un fichier
  #    wpa_supplicant complet — plus aucun SSID ni PSK dans la configuration ;
  #  - `ssid` + `pskFile` : le couple historique, gardé pour les images de
  #    secours et comme repli pendant une migration.
  # Les deux unités doivent exister dès qu'une source est déclarée, sinon une
  # carte en config-as-data n'aurait ni wpa-psk ni wpa_supplicant.
  hasSsid = cfg.ssid != null && cfg.pskFile != null;
  hasNetworks = cfg.networksFile != null;
  hasSource = hasSsid || hasNetworks;
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
      description = ''
        SSID to associate with. Ignored when `networksFile` is readable; with
        neither source declared, wpa_supplicant is not started.
      '';
    };

    pskFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path to a file containing the PSK, read at boot (for example
        /run/havenos/wifi-psk). Never put the PSK in the Nix store. Used only
        when `networksFile` is null or unreadable.
      '';
    };

    networksFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path to a complete wpa_supplicant configuration (one or more
        `network={…}` blocks), read at boot. When the file is readable it takes
        precedence over `ssid`/`pskFile`: the card then carries **no** WiFi
        identity in its Nix configuration, only the path of a data file
        rendered by the provisioning layer (config-as-data). The file is used
        verbatim, so it must be complete (`ctrl_interface` included if `wpa_cli`
        is wanted) and is expected under `/run`: the clear-text never touches
        the disk. Never pass a store path here.
      '';
    };

    extraNetworks = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Extra `network={...}` blocks appended to the rendered config. Not used
        when `networksFile` supplies the whole configuration.
      '';
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

    systemd.services.wpa-psk = lib.mkIf hasSource {
      description = "Render /run/wpa_supplicant.conf from a secret file";
      wantedBy = [ "wpa-supplicant-${cfg.interface}.service" ];
      before = [ "wpa-supplicant-${cfg.interface}.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        umask 077
      ''
      + lib.optionalString hasNetworks ''
        # La donnée prime : fichier wpa_supplicant complet, rendu au boot par
        # la couche de secrets. Rien à parser, rien à cuire — le module ne
        # connaît ni SSID ni PSK. Illisible, on laisse le repli ci-dessous (ou
        # l'échec plus bas) décider.
        if [ -r ${lib.escapeShellArg cfg.networksFile} ]; then
          cat ${lib.escapeShellArg cfg.networksFile} > /run/wpa_supplicant.conf
          exit 0
        fi
      ''
      + lib.optionalString hasSsid ''
        # Repli : couple ssid + PSK (image de secours, migration en cours).
        # Un PSK absent ne doit pas produire `psk=""` : wpa_supplicant sort
        # alors en 255 et systemd le relance à l'infini (mesuré sur une carte
        # HavenOS : 49 redémarrages, boucle qui masque la vraie panne). On
        # échoue ici, bruyamment, et on retire un conf périmé pour que
        # wpa-supplicant-* soit sauté proprement (ConditionPathExists).
        psk=$(cat ${lib.escapeShellArg cfg.pskFile} 2>/dev/null || true)
        if [ -z "$psk" ]; then
          rm -f /run/wpa_supplicant.conf
          echo "wpa-psk: ${cfg.pskFile} absent ou vide — secrets non provisionnés (havenos provision)" >&2
          exit 1
        fi
        {
          printf 'ctrl_interface=DIR=/run/wpa_supplicant GROUP=wheel\n'
          printf 'network={\n'
          printf '\tssid="%s"\n' ${lib.escapeShellArg cfg.ssid}
          printf '\tpsk="%s"\n' "$psk"
          printf '}\n'
          ${cfg.extraNetworks}
        } > /run/wpa_supplicant.conf
        exit 0
      ''
      + lib.optionalString (!hasSsid) ''
        # `networksFile` seul, mais absent ou illisible : échec visible plutôt
        # qu'un conf vide que wpa_supplicant refuserait en boucle (mesuré sur
        # la Zero 3 : 49 redémarrages, boucle qui masquait la vraie panne).
        rm -f /run/wpa_supplicant.conf
        echo "wpa-psk: ${cfg.networksFile} illisible — carte non provisionnée (havenos provision)" >&2
        exit 1
      '';
    };

    systemd.services."wpa-supplicant-${cfg.interface}" = lib.mkIf hasSource {
      description = "wpa_supplicant (${cfg.interface})";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-pre.target"
        "wpa-psk.service"
      ];
      wants = [ "wpa-psk.service" ];
      before = [ "network.target" ];
      # Sans conf rendue, wpa_supplicant sortirait en 255 et bouclerait :
      # on saute l'unité (état « skipped », pas « failed »), et
      # `havenos provision` la relance explicitement après le PSK. Le fichier
      # est le conf rendu, quelle que soit la source (networksFile ou repli).
      unitConfig.ConditionPathExists = "/run/wpa_supplicant.conf";
      # Filet de sécurité : conf présente mais wpa_supplicant qui refuse
      # quand même de démarrer — 5 essais, puis on s'arrête.
      startLimitIntervalSec = 300;
      startLimitBurst = 5;
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.wpa_supplicant}/sbin/wpa_supplicant -c /run/wpa_supplicant.conf -i ${cfg.interface}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
