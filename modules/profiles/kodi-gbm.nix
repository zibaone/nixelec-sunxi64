{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec.kodi;

  # Estuary stores these booleans in addon_data/skin.estuary/settings.xml.
  homeMenuSettings = {
    movies = "homemenunomoviebutton";
    tvshows = "homemenunotvshowbutton";
    music = "homemenunomusicbutton";
    musicvideos = "homemenunomusicvideobutton";
    livetv = "homemenunotvbutton";
    radio = "homemenunoradiobutton";
    games = "homemenunogamesbutton";
    programs = "homemenunoprogramsbutton";
    pictures = "homemenunopicturesbutton";
    videos = "homemenunovideosbutton";
    favourites = "homemenunofavbutton";
    weather = "homemenunoweatherbutton";
  };

  # Kodi CEC adapter values: 13011 follows the TV, 36028 keeps the appliance
  # running.
  cecStandbyValues = {
    default = "13011";
    ignore = "36028";
  };
  cecStandbyValue = cecStandbyValues.${cfg.cec.standbyPcOnTvStandby};

  # `addons = null` must leave the package untouched so the default store
  # paths and the published cache stay valid.
  kodiPackage = if cfg.addons == null then cfg.package else cfg.package.withPackages cfg.addons;
in
{
  options.nixelec.kodi = {
    enable = lib.mkEnableOption "Kodi GBM kiosk, without a compositor";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.kodi-gbm;
      description = "Kodi package to launch (kodi-gbm, or kodi-kiosk from the v4l2-request flake).";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "kodi";
      description = "User that runs Kodi.";
    };

    home = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/kodi";
      description = "Kodi user home directory.";
    };

    extraGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "video"
        "audio"
        "input"
        "render"
        "tty"
      ];
      description = "Additional groups for the Kodi user.";
    };

    extraKernelParams = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra kernel parameters (for example video=HDMI-A-1:1920x1080@60).";
    };

    addons = lib.mkOption {
      type = lib.types.nullOr (lib.types.functionTo (lib.types.listOf lib.types.package));
      default = null;
      description = ''
        Function that receives the Kodi package set and returns extra add-ons,
        for example `kodi: with kodi; [ inputstream-adaptive ]`.
        When null, `package` is used unchanged.
      '';
    };

    autoEnableAddons = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Add-on IDs to enable at boot through the local Kodi JSON-RPC socket.
        Kodi leaves add-ons installed by Nix disabled until an install event
        occurs, so the generic workaround is an explicit SetAddonEnabled call.
      '';
    };

    webServer = {
      enable = lib.mkEnableOption "Kodi web server (HTTP Basic, LAN)";

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Runtime path to a file containing the Kodi web server password.
          Required when the web server is enabled; the file is read by a
          root oneshot and never copied into the Nix store.
        '';
      };

      username = lib.mkOption {
        type = lib.types.str;
        default = "kodi";
        description = "Kodi web server username.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "Kodi web server TCP port.";
      };
    };

    uiSounds = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable Kodi UI sounds (guisoundmode=0, empty soundskin).";
    };

    homeMenu.hidden = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (builtins.attrNames homeMenuSettings));
      default = [ ];
      description = "Estuary home menu items to hide.";
    };

    cec = {
      enable = lib.mkEnableOption "HDMI-CEC support for the Kodi appliance";

      device = lib.mkOption {
        type = lib.types.str;
        default = "/dev/cec0";
        description = "CEC device used by the helper services.";
      };

      connector = lib.mkOption {
        type = lib.types.str;
        default = "card0-HDMI-A-1";
        description = "DRM connector checked before restarting Kodi after a hotplug.";
      };

      standbyPcOnTvStandby = lib.mkOption {
        type = lib.types.enum [
          "default"
          "ignore"
        ];
        default = "ignore";
        description = ''
          Kodi CEC policy when the TV goes to standby. `ignore` keeps the
          appliance running; `default` leaves Kodi's default behaviour.
        '';
      };

      manageAdapterSettings = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create or update the Kodi CEC adapter settings before Kodi starts.";
      };

      reprobeOnBoot = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Reload dw-hdmi-cec at boot when the CEC physical address is invalid.";
      };

      hotplugRecovery = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Restart Kodi after an HDMI hotplug when the CEC physical address is
          invalid. This is a workaround for a kernel-level CEC issue; enable it
          only when the TV actually loses CEC after standby.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          !cfg.webServer.enable || (cfg.webServer.passwordFile != null && cfg.webServer.passwordFile != "");
        message = "nixelec.kodi.webServer.passwordFile must be set when the web server is enabled.";
      }
    ];

    systemd.services.kodi-gbm = {
      description = "Kodi (direct GBM, no compositor)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "systemd-user-sessions.service"
        "sound.target"
      ];
      conflicts = [ "getty@tty1.service" ];
      # Restarting a `Restart = "always"` service during `switch` can fail and
      # makes `nixos-rebuild switch` return 4. A changed Kodi unit takes
      # effect on the next boot instead.
      restartIfChanged = false;
      serviceConfig = {
        User = cfg.user;
        Group = "users";
        PAMName = "login";
        TTYPath = "/dev/tty1";
        TTYReset = "yes";
        TTYVHangup = "yes";
        StandardInput = "tty";
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        ExecStart = "${kodiPackage}/bin/kodi --standalone --windowing=gbm";
        Restart = "always";
      };
    };

    # Kodi rewrites guisettings.xml on shutdown, so the managed settings
    # must be applied before every start, not shipped as a static file.
    systemd.services.kodi-settings =
      lib.mkIf (cfg.webServer.enable || cfg.uiSounds || cfg.homeMenu.hidden != [ ])
        {
          description = "Apply Kodi settings before Kodi starts";
          after = [ "local-fs.target" ];
          before = [ "kodi-gbm.service" ];
          requiredBy = [ "kodi-gbm.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            set -euo pipefail

            settings="${cfg.home}/.kodi/userdata/guisettings.xml"
            skin_settings="${cfg.home}/.kodi/userdata/addon_data/skin.estuary/settings.xml"
            ${lib.optionalString cfg.webServer.enable ''
              password_file="${cfg.webServer.passwordFile}"
              if [ ! -s "$password_file" ]; then
                echo "kodi-settings: missing or empty password file: $password_file" >&2
                exit 1
              fi
              password="$(${pkgs.coreutils}/bin/cat "$password_file")"
              if [ -z "$password" ]; then
                echo "kodi-settings: empty password in $password_file" >&2
                exit 1
              fi
            ''}

            ${pkgs.coreutils}/bin/install -d -o ${cfg.user} -g users -m 0700 "${cfg.home}/.kodi/userdata"
            ${pkgs.coreutils}/bin/install -d -o ${cfg.user} -g users -m 0755 "${cfg.home}/.kodi/userdata/addon_data/skin.estuary"
            if [ ! -e "$settings" ]; then
              ${pkgs.coreutils}/bin/printf '%s\n' \
                '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>' \
                '<settings version="2">' \
                '    <setting id="services.webserver" default="true">false</setting>' \
                '    <setting id="services.esallinterfaces" default="true">false</setting>' \
                '    <setting id="services.webserverauthentication" default="true">true</setting>' \
                '    <setting id="services.webserverusername" default="true">kodi</setting>' \
                '    <setting id="services.webserverpassword" default="true" />' \
                '    <setting id="services.webserverport" default="true">8080</setting>' \
                '    <setting id="services.webserverssl" default="true">false</setting>' \
                '    <setting id="services.zeroconf" default="true">true</setting>' \
                '    <setting id="audiooutput.guisoundmode" default="true">1</setting>' \
                '    <setting id="lookandfeel.soundskin" default="true">resource.uisounds.kodi</setting>' \
                '</settings>' > "$settings"
            fi

            # Kodi marks default values with default="true" and ignores the text
            # in that case; non-default values must drop the attribute.
            #
            # UI sounds: guisoundmode=0 disables them; soundskin must be empty,
            # not "OFF" (Kodi logs "Unknown sounds addon 'OFF'").
            args=(
              ${lib.optionalString cfg.webServer.enable ''
                -u "//setting[@id='services.webserver']" -v true
                -u "//setting[@id='services.esallinterfaces']" -v true
                -u "//setting[@id='services.webserverauthentication']" -v true
                -u "//setting[@id='services.webserverusername']" -v "${cfg.webServer.username}"
                -u "//setting[@id='services.webserverpassword']" -v "$password"
                -u "//setting[@id='services.webserverport']" -v "${toString cfg.webServer.port}"
                -u "//setting[@id='services.webserverssl']" -v false
                -u "//setting[@id='services.zeroconf']" -v true
                -d "//setting[@id='services.webserver']/@default"
                -d "//setting[@id='services.esallinterfaces']/@default"
                -d "//setting[@id='services.webserverpassword']/@default"
              ''}
              ${lib.optionalString cfg.uiSounds ''
                -u "//setting[@id='audiooutput.guisoundmode']" -v 0
                -u "//setting[@id='lookandfeel.soundskin']" -v ""
                -d "//setting[@id='audiooutput.guisoundmode']/@default"
                -d "//setting[@id='lookandfeel.soundskin']/@default"
              ''}
            )
            if [ "''${#args[@]}" -gt 0 ]; then
              ${pkgs.xmlstarlet}/bin/xmlstarlet ed -L "''${args[@]}" "$settings"
            fi

            ${pkgs.coreutils}/bin/chown ${cfg.user}:users "$settings"
            ${pkgs.coreutils}/bin/chmod 0600 "$settings"

            ${lib.optionalString (cfg.homeMenu.hidden != [ ]) ''
              if [ ! -e "$skin_settings" ]; then
                ${pkgs.coreutils}/bin/printf '%s\n' \
                  '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>' \
                  '<settings>' \
                  '</settings>' > "$skin_settings"
              fi
              ${lib.concatStrings (
                map (item: ''
                  id="${homeMenuSettings.${item}}"
                  xpath="//setting[@id=\"''${id}\"]"
                  if [ "$(${pkgs.xmlstarlet}/bin/xmlstarlet sel -t -v "count(''${xpath})" "$skin_settings")" = "0" ]; then
                    ${pkgs.xmlstarlet}/bin/xmlstarlet ed -L \
                      -s /settings -t elem -n setting -v true \
                      -i "/settings/setting[last()]" -t attr -n id -v "$id" \
                      -i "/settings/setting[last()]" -t attr -n type -v bool \
                      "$skin_settings"
                  else
                    ${pkgs.xmlstarlet}/bin/xmlstarlet ed -L -u "''${xpath}" -v true "$skin_settings"
                  fi
                '') cfg.homeMenu.hidden
              )}
              ${pkgs.coreutils}/bin/chown ${cfg.user}:users "$skin_settings"
              ${pkgs.coreutils}/bin/chmod 0644 "$skin_settings"
            ''}
          '';
        };

    # Kodi leaves add-ons installed by Nix disabled: there was no install
    # event, so an explicit SetAddonEnabled call is needed. Keep the unit
    # independent from the Kodi restart cycle (no `PartOf=`): on a switch the
    # restart would kill the activation and the switch can return 4.
    systemd.services.kodi-addons = lib.mkIf (cfg.autoEnableAddons != [ ]) {
      description = "Enable Kodi add-ons installed by Nix";
      wantedBy = [ "multi-user.target" ];
      after = [ "kodi-gbm.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 240;
      };
      script = ''
        set -u

        # Kodi does not terminate its JSON-RPC responses with a newline, so
        # `read -t` always times out and leaves the bytes in the variable.
        # Accumulate short reads until the response id appears.
        rpc() {
          (
            resp=""
            chunk=""
            exec {fd}<>/dev/tcp/127.0.0.1/9090 || exit 1
            printf '%s' "$1" >&"$fd"
            for _ in $(${pkgs.coreutils}/bin/seq 1 25); do
              IFS= read -r -t 0.4 chunk <&"$fd" || true
              resp="$resp''${chunk:-}"
              chunk=""
              case "$resp" in
                *"\"id\":$2,"*) break ;;
              esac
            done
            exec {fd}<&-
            printf '%s' "$resp"
          ) 2>/dev/null
        }

        ready=0
        for _ in $(${pkgs.coreutils}/bin/seq 1 90); do
          if rpc '{"jsonrpc":"2.0","id":0,"method":"JSONRPC.Ping"}' 0 | ${pkgs.gnugrep}/bin/grep -q pong; then
            ready=1
            break
          fi
          ${pkgs.coreutils}/bin/sleep 2
        done
        if [ "$ready" != 1 ]; then
          echo "JSON-RPC unavailable after 180 s" >&2
          exit 1
        fi

        id=1
        for a in ${lib.escapeShellArgs cfg.autoEnableAddons}; do
          id=$((id + 1))
          out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"Addons.SetAddonEnabled\",\"params\":{\"addonid\":\"$a\",\"enabled\":true}}" "$id")
          case "$out" in
            *'"result":"OK"'*) echo "enabled: $a" ;;
            *) echo "failed: $a -> $out" >&2 ;;
          esac
        done
      '';
    };

    users.users.${cfg.user} = {
      isNormalUser = true;
      home = cfg.home;
      createHome = true;
      extraGroups = cfg.extraGroups;
    };

    hardware.graphics.enable = lib.mkDefault true;

    security.rtkit.enable = true;
    # Measured on the Zero 3: `LimitRTPRIO = 95` alone is not enough. rtkit
    # sets RLIMIT_RTPRIO=0 and relies on CAP_SYS_NICE, but this kernel
    # (CONFIG_RT_GROUP_SCHED=y, sched_rt_runtime_us=950000) returns EPERM for
    # sched_setscheduler even as root. Disabling RT throttling lets rtkit
    # grant RT: PipeWire's data-loop becomes SCHED_RR/20.
    boot.kernel.sysctl."kernel.sched_rt_runtime_us" = -1;
    systemd.services.rtkit-daemon.serviceConfig.LimitRTPRIO = 95;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
    };

    # WirePlumber 0.5 creates every sink at `device.routes.default-sink-volume`
    # = 0.064 linear, i.e. 40 % as `wpctl get-volume` prints it (cubic) —
    # 0.064 = 0.40³ ≈ −24 dB. Kodi never touches that: its own "100 %" is the
    # volume of its *stream*, not of the sink, so the kiosk played 24 dB below
    # the source with the on-screen volume bar at full. On the Zero 3 the HDMI
    # codec exposes no mixer at all (`route.hw-volume=false`, the sink carries
    # `softVolumes`), so this software volume is the one and only attenuation
    # in the chain. Measured on 2026-10-26: sink at 0.40 → quiet; 1.00 → normal.
    services.pipewire.wireplumber.extraConfig."51-default-sink-volume" = {
      "wireplumber.settings"."device.routes.default-sink-volume" = 1.0;
    };

    services.xserver.enable = lib.mkDefault false;
    documentation.enable = lib.mkDefault false;
    nix.registry = lib.mkForce { };

    boot.kernelParams = cfg.extraKernelParams;

    # The module is pruned from the nixbian kernel unless it is in the module
    # allowlist; `boot.kernelModules` adds it and loads it at boot.
    boot.kernelModules = lib.mkIf cfg.cec.enable [ "dw-hdmi-cec" ];

    # At cold boot, dw-hdmi-cec can keep an invalid physical address
    # (f.f.f.f) when the first EDID read fails. Reloading the module after the
    # device appears makes it pick up the connector address.
    systemd.services.hdmi-cec-reprobe = lib.mkIf (cfg.cec.enable && cfg.cec.reprobeOnBoot) {
      description = "Re-probe dw-hdmi-cec to pick up the HDMI physical address";
      wantedBy = [ "multi-user.target" ];
      after = [ "kodi-settings.service" ];
      before = [ "kodi-gbm.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${pkgs.kmod}/bin/modprobe dw_hdmi_cec 2>/dev/null || true
        for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
          [ -e ${cfg.cec.device} ] && break
          ${pkgs.coreutils}/bin/sleep 0.2
        done
        if [ ! -e ${cfg.cec.device} ]; then
          echo "CEC device ${cfg.cec.device} absent, nothing to re-probe"
          exit 0
        fi
        phys=$(${pkgs.v4l-utils}/bin/cec-ctl -d ${cfg.cec.device} -S 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep -m1 "Physical Address" \
          | ${pkgs.gnused}/bin/sed "s/.*: *//")
        echo "CEC physical address before: $phys"
        if [ "$phys" = "f.f.f.f" ]; then
          ${pkgs.kmod}/bin/modprobe -r dw_hdmi_cec 2>/dev/null || true
          ${pkgs.kmod}/bin/modprobe dw_hdmi_cec 2>/dev/null || true
          ${pkgs.coreutils}/bin/sleep 1
          phys=$(${pkgs.v4l-utils}/bin/cec-ctl -d ${cfg.cec.device} -S 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -m1 "Physical Address" \
            | ${pkgs.gnused}/bin/sed "s/.*: *//")
          echo "CEC physical address after: $phys"
        fi
      '';
    };

    # dw-hdmi invalidates the CEC address on HPD loss. A Kodi modeset re-reads
    # the EDID and re-arms the notifier, so restart Kodi only when no logical
    # address is claimed and the sink is connected. A real hotplug burst
    # (2026-10-26) can also leave the controller unable to claim a logical
    # address: the physical address comes back, but `polling for LA` keeps
    # failing (tx_status 0x0030 = CEC_TX_STATUS_ERROR|MAX_RETRIES), so CEC stays
    # dead until the module is reloaded. Hence the restart is verified against
    # the logical address mask, with one module reload as a fallback.
    systemd.services.hdmi-cec-hotplug = lib.mkIf (cfg.cec.enable && cfg.cec.hotplugRecovery) {
      description = "Restore the CEC physical address after an HDMI hotplug";
      unitConfig = {
        StartLimitIntervalSec = 300;
        StartLimitBurst = 3;
      };
      serviceConfig = {
        Type = "oneshot";
        # Worst case: 3 s settle + 80 s Kodi window + claim + module reload
        # + restart + 80 s window. A 120 s cap killed the last path.
        TimeoutStartSec = 240;
      };
      script = ''
        stamp=/run/hdmi-cec-hotplug.stamp

        cec_ctl() {
          ${pkgs.v4l-utils}/bin/cec-ctl -d ${cfg.cec.device} -S 2>/dev/null
        }

        cec_la_mask() {
          cec_ctl \
            | ${pkgs.gnugrep}/bin/grep -i -m1 "Logical Address Mask" \
            | ${pkgs.gnugrep}/bin/grep -o -m1 "0x[0-9a-fA-F]*" || true
        }

        # 0x0000 means the adapter claimed no logical address at all, and
        # 0x8000 is LA 15 ("unregistered"): broadcast-only, not addressable,
        # and most TVs ignore it. Neither counts as a usable claim — accepting
        # 0x8000 was a false positive at cold boot (2026-10-27).
        cec_has_la() {
          mask=$(cec_la_mask)
          [ -n "$mask" ] || return 1
          [ $(( mask & 0x7fff )) -ne 0 ]
        }

        # Give Kodi modeset up to 80 s to claim a logical address. Kodi only
        # configures CEC ~30 s after it starts, and the first poll can fail
        # (tx_status 0x0030) while the controller is still settling: the window
        # must cover that attempt, otherwise the check runs too early.
        wait_la() {
          for _ in $(${pkgs.coreutils}/bin/seq 1 40); do
            ${pkgs.coreutils}/bin/sleep 2
            if cec_has_la; then
              return 0
            fi
          done
          return 1
        }

        wait_la_quick() {
          for _ in $(${pkgs.coreutils}/bin/seq 1 5); do
            ${pkgs.coreutils}/bin/sleep 2
            if cec_has_la; then
              return 0
            fi
          done
          return 1
        }

        ${pkgs.coreutils}/bin/sleep 3
        ${config.systemd.package}/bin/systemctl is-active --quiet kodi-gbm.service || exit 0
        [ -e ${cfg.cec.device} ] || exit 0
        [ "$(${pkgs.coreutils}/bin/cat /sys/class/drm/${cfg.cec.connector}/status)" = "connected" ] || exit 0

        if cec_has_la; then
          echo "CEC logical address present, nothing to recover"
          ${pkgs.coreutils}/bin/rm -f "$stamp"
          exit 0
        fi

        phys=$(cec_ctl \
          | ${pkgs.gnugrep}/bin/grep -m1 "Physical Address" \
          | ${pkgs.gnused}/bin/sed "s/.*: *//")
        echo "CEC after hotplug: physical address $phys, logical address mask $(cec_la_mask)"

        if [ "$phys" = "f.f.f.f" ]; then
          if [ -e "$stamp" ] && [ $(( $(${pkgs.coreutils}/bin/date +%s) - $(${pkgs.coreutils}/bin/stat -c %Y "$stamp") )) -lt 300 ]; then
            echo "CEC recovery already attempted recently, skip"
            exit 0
          fi
          ${pkgs.coreutils}/bin/touch "$stamp"
          echo "CEC physical address invalid after hotplug, restarting Kodi"
          ${config.systemd.package}/bin/systemctl --no-block restart kodi-gbm.service
          if wait_la; then
            echo "CEC logical address claimed after the Kodi restart"
            ${pkgs.coreutils}/bin/rm -f "$stamp"
            exit 0
          fi
          echo "CEC logical address still missing after the Kodi restart"
        fi

        # 2026-10-27 (cold boot, measured): the first LA poll can run before
        # the CEC block is ready and fail with tx_status=0x0030, leaving the
        # adapter on LA 15 (0x8000). Kodi never retries, so claim explicitly
        # once the adapter has settled — this succeeds where the boot poll
        # failed, and is cheaper than reloading the module.
        if ! cec_has_la; then
          echo "Claiming a logical address (mask $(cec_la_mask)) with cec-ctl --playback"
          ${pkgs.v4l-utils}/bin/cec-ctl -d ${cfg.cec.device} --playback || true
          if wait_la_quick; then
            echo "CEC logical address claimed by cec-ctl (mask $(cec_la_mask))"
            ${pkgs.coreutils}/bin/rm -f "$stamp"
            exit 0
          fi
          echo "CEC claim with cec-ctl failed (mask $(cec_la_mask))"
        fi

        # 2026-10-26: after an HDMI HPD burst the controller can stay in
        # CEC_STAT_ERROR_INIT, so restarting Kodi is not enough. Reloading the
        # module re-initialises the block and lets Kodi claim the address again.
        echo "Reloading dw_hdmi_cec to re-initialise the CEC controller"
        ${pkgs.kmod}/bin/modprobe -r dw_hdmi_cec 2>/dev/null || true
        ${pkgs.kmod}/bin/modprobe dw_hdmi_cec 2>/dev/null || true
        for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
          if [ -e ${cfg.cec.device} ]; then
            break
          fi
          ${pkgs.coreutils}/bin/sleep 0.2
        done
        ${config.systemd.package}/bin/systemctl --no-block restart kodi-gbm.service
        if wait_la; then
          echo "CEC logical address claimed after the module reload"
          ${pkgs.coreutils}/bin/rm -f "$stamp"
        else
          echo "CEC recovery failed: physical address $phys, logical address mask $(cec_la_mask)" >&2
          exit 1
        fi
      '';
    };

    services.udev.extraRules = lib.mkIf (cfg.cec.enable && cfg.cec.hotplugRecovery) ''
      ACTION=="change", SUBSYSTEM=="drm", ENV{HOTPLUG}=="1", TAG+="systemd", ENV{SYSTEMD_WANTS}+="hdmi-cec-hotplug.service"
    '';

    # Kodi defaults to following the TV into standby. An always-on appliance
    # must ignore that command; the adapter file is created or updated before
    # every Kodi start.
    systemd.services.kodi-cec-defaults = lib.mkIf (cfg.cec.enable && cfg.cec.manageAdapterSettings) {
      description = "Set the Kodi CEC adapter defaults";
      wantedBy = [ "multi-user.target" ];
      after = [ "kodi-settings.service" ];
      before = [ "kodi-gbm.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        dir="${cfg.home}/.kodi/userdata/peripheral_data"
        file="$dir/cec_CEC_Adapter.xml"
        ${pkgs.coreutils}/bin/install -d -o ${cfg.user} -g users -m 0755 "$dir"
        if [ ! -f "$file" ]; then
          ${pkgs.coreutils}/bin/install -o ${cfg.user} -g users -m 0644 \
            ${./kodi-cec-adapter.xml} "$file"
        fi
        ${pkgs.gnused}/bin/sed -i \
          's|\(id="standby_pc_on_tv_standby" value="\)[0-9]*"|\1${cecStandbyValue}"|' "$file"
        ${pkgs.coreutils}/bin/chown ${cfg.user}:users "$file"
        ${pkgs.coreutils}/bin/chmod 0644 "$file"
      '';
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.home} 0700 ${cfg.user} users -"
      "d ${cfg.home}/.kodi 0755 ${cfg.user} users -"
      "d /var/lib/pipewire 0700 ${cfg.user} users -"
    ];

    networking.useNetworkd = lib.mkDefault true;
    networking.useDHCP = lib.mkDefault false;
    systemd.network.wait-online = {
      # Either the wired or the wireless link is enough: the appliance may
      # boot with only one of them connected.
      anyInterface = true;
      timeout = 60;
    };
    systemd.network.networks."10-lan" = {
      matchConfig.Name = "en*";
      networkConfig.DHCP = "ipv4";
    };
    systemd.network.networks."10-wlan" = {
      matchConfig.Name = "wl*";
      networkConfig.DHCP = "ipv4";
      linkConfig.RequiredForOnline = "routable";
    };

    services.avahi = {
      enable = lib.mkDefault true;
      nssmdns4 = true;
      publish = {
        enable = true;
        addresses = true;
      };
    };

    # Avahi owns mDNS here; resolved's mDNS stack only triggers the
    # "Detected another mDNS stack" warning and is redundant.
    services.resolved.settings.Resolve.MulticastDNS = lib.mkDefault false;

    environment.defaultPackages = lib.mkForce (
      with pkgs;
      [
        bashInteractive
        coreutils
        iproute2
        kmod
        less
        nano
        procps
        util-linux
      ]
    );
  };
}
