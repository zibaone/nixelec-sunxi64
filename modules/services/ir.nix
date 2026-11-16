{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec.ir;

  # ir-keytable vient de v4l-utils ; `withGUI = false` évite de tirer Qt pour
  # un outil en ligne de commande (même choix que le profil Kodi de HavenOS).
  v4l = pkgs.v4l-utils.override { withGUI = false; };

  # ---------------------------------------------------------------------------
  # Télécommandes : un fichier TOML par télécommande, plusieurs activables
  # ---------------------------------------------------------------------------
  # Chaque fichier est une keymap `ir-keytable` (TOML : `[[protocols]]` +
  # `[protocols.scancodes]`), au format capturé sur la carte avec
  # `ir-keytable -s <dev> -p nec -t`.
  #
  # La keymap chargée est la **fusion** des télécommandes activées : rc-core ne
  # garde qu'un keycode par scancode (`rc-main.c`, `ir_update_mapping`) et
  # `ir-keytable` éclate toutes les sections en une seule liste
  # (`keytable.c:372`, `add_keymap`). Ajouter une télécommande = déposer un
  # fichier, l'ajouter à `remotes` si le défaut ne le prend pas, et recharger.
  #
  # Le répertoire du module porte les tables publiques ; `extraRemotesDir`
  # permet à une couche privée d'ajouter les siennes sans modifier ce dépôt
  # (même nom = la version privée gagne).
  dirs = [ ./remotes ] ++ lib.optional (cfg.extraRemotesDir != null) cfg.extraRemotesDir;

  remoteFiles = lib.foldl' (
    acc: dir:
    acc
    // lib.mapAttrs' (n: _: lib.nameValuePair (lib.removeSuffix ".toml" n) (dir + "/${n}")) (
      lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".toml" n) (builtins.readDir dir)
    )
  ) { } dirs;

  availableNames = lib.attrNames remoteFiles;

  enabledNames = if cfg.remotes == [ ] then availableNames else cfg.remotes;

  unknownRemotes = lib.subtractLists availableNames enabledNames;

  # `variant` est documentaire : ir-keytable l'ignore (seul `ir-ctl` le lit).
  # Le décodeur NEC du noyau rend NEC, NECX et NEC32 dès que `nec` est activé,
  # donc `-p nec` couvre les tables « necx » et « nec32 ».
  parseRemote =
    name:
    let
      lines = lib.splitString "\n" (builtins.readFile remoteFiles.${name});
      grab =
        pattern:
        let
          found = lib.filter (m: m != null) (map (l: builtins.match pattern l) lines);
        in
        if found == [ ] then null else lib.head (lib.head found);
      protocol = grab "[ \t]*protocol[ \t]*=[ \t]*\"([a-z0-9._-]+)\".*";
    in
    {
      protocol = if protocol == null then "nec" else protocol;
      variant = grab "[ \t]*variant[ \t]*=[ \t]*\"([a-z0-9._-]+)\".*";
      entries =
        map
          (m: {
            scancode = lib.elemAt m 0;
            keycode = lib.elemAt m 1;
          })
          (
            lib.filter (m: m != null) (
              map (l: builtins.match "[ \t]*(0x[0-9a-fA-F]+)[ \t]*=[ \t]*\"(KEY_[A-Z0-9_]+)\".*" l) lines
            )
          );
    };

  # Toutes les revendications par scancode : de quoi nommer un conflit et les
  # télécommandes en cause.
  claims = lib.foldl' (
    acc: name:
    let
      remote = parseRemote name;
    in
    lib.foldl' (
      inner: entry:
      inner
      // {
        ${entry.scancode} = (inner.${entry.scancode} or [ ]) ++ [
          {
            inherit (entry) keycode;
            inherit (remote) protocol variant;
            remote = name;
          }
        ];
      }
    ) acc remote.entries
  ) { } enabledNames;

  conflicts = lib.filterAttrs (_: c: lib.length (lib.unique (map (x: x.keycode) c)) > 1) claims;

  conflictReport = lib.mapAttrsToList (
    scancode: c: "${scancode} → ${lib.concatStringsSep ", " (map (x: "${x.keycode} (${x.remote})") c)}"
  ) conflicts;

  # Un conflit n'est pas fatal : une surcharge du scancode le tranche.
  unresolvedConflicts = lib.filter (s: !(cfg.remoteOverrides ? ${s})) (lib.attrNames conflicts);

  # Une surcharge qui ne correspond à aucun scancode chargé est une faute de
  # frappe, ou vise une télécommande désactivée.
  orphanOverrides = lib.filter (s: !(claims ? ${s})) (lib.attrNames cfg.remoteOverrides);

  finalEntries = lib.filter (e: e.keycode != null) (
    lib.mapAttrsToList (
      scancode: c:
      let
        first = lib.head c;
        overridden = cfg.remoteOverrides ? ${scancode};
      in
      {
        inherit scancode;
        inherit (first) protocol variant;
        keycode = if overridden then cfg.remoteOverrides.${scancode} else first.keycode;
      }
    ) claims
  );

  # Une section [[protocols]] par couple protocole/variante.
  keymapText = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      group: entries:
      let
        parts = lib.splitString "|" group;
        protocol = lib.head parts;
        variant = lib.elemAt parts 1;
        header = [
          "[[protocols]]"
          "name = \"nixelec\""
          "protocol = \"${protocol}\""
        ]
        ++ lib.optional (variant != "") "variant = \"${variant}\""
        ++ [ "[protocols.scancodes]" ];
      in
      lib.concatStringsSep "\n" header
      + "\n"
      + lib.concatMapStrings (e: "${e.scancode} = \"${e.keycode}\"\n") entries
    ) (lib.groupBy (e: "${e.protocol}|${if e.variant == null then "" else e.variant}") finalEntries)
  );

  # Une table dont tous les scancodes tiennent sur 8 bits vient d'un récepteur à
  # décodeur matériel. Le décodeur sunxi rend `adresse << 8 | commande` : elle
  # ne matchera que si l'adresse NEC vaut 0x00. Avertissement, pas erreur.
  maybeHardwareTables = lib.filter (
    name:
    let
      entries = (parseRemote name).entries;
    in
    entries != [ ] && lib.all (e: lib.stringLength e.scancode <= 4) entries
  ) enabledNames;

  keymap = pkgs.writeText "remotes.toml" (
    lib.warnIf (maybeHardwareTables != [ ])
      "nixelec.ir : table(s) 8 bits (${lib.concatStringsSep ", " maybeHardwareTables}) — relevées avec un décodeur matériel, elles ne matcheront sur le décodage sunxi que si l'adresse NEC vaut 0x00"
      keymapText
  );

  # Overlay : le nœud `ir@7040000` est présent dans `sun50i-h616.dtsi` mais
  # `status = "disabled"`. L'overlay ne fait que l'activer ; la broche (PH10)
  # est déjà câblée par `ir_rx_pin`.
  #
  # nixpkgs n'applique un overlay que si son `compatible` intersecte celui de
  # la carte : sans cette ligne il est **silencieusement sauté** (« set() is
  # incompatible »). D'où `dtCompatible`, qui vise le SoC par défaut.
  dtOverlay = pkgs.writeText "ir-enable.dts" ''
    /dts-v1/;
    /plugin/;

    / {
      compatible = ${lib.concatMapStringsSep ", " (c: "\"${c}\"") cfg.dtCompatible};

      fragment@0 {
        target-path = "/soc";
        __overlay__ {
          ir@7040000 {
            status = "okay";
          };
        };
      };
    };
  '';

  # Compilé ici plutôt que laissé à `hardware.deviceTree.overlays` avec un
  # `dtsFile` : `compileDTS` de nixpkgs tire `kernel.dev`
  # (include-prefixes), sortie qui n'est pas au cache — mesuré le 2026-11-16,
  # cela déclenche une recompilation complète du noyau. Un `.dtbo` fourni tel
  # quel ne passe que par `applyOverlays`, qui travaille sur le DTB déjà
  # construit.
  dtOverlayDtbo = pkgs.runCommandLocal "ir-enable.dtbo" { nativeBuildInputs = [ pkgs.dtc ]; } ''
    ${pkgs.dtc}/bin/dtc -@ -I dts -O dtb -o $out ${dtOverlay}
  '';
in
{
  options.nixelec.ir = {
    enable = lib.mkEnableOption "récepteur IR (rc-core + ir-keytable, sans LIRC)";

    remotes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "hk1x3"
        "mecool"
      ];
      description = ''
        Télécommandes activées, par nom de fichier sans `.toml`. Vide = toutes
        celles trouvées (celles du module, plus `extraRemotesDir`). Les tables
        sont **fusionnées** : plusieurs télécommandes cohabitent, à condition
        qu'aucun scancode ne revendique deux keycodes différents — un conflit
        non tranché échoue à l'éval, pas à la télécommande.
      '';
    };

    remoteOverrides = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
      default = { };
      example = {
        "0x404043" = null;
        "0x116" = "KEY_ENTER";
      };
      description = ''
        Surcharges par scancode : `null` désactive la touche (le scancode n'est
        pas écrit, donc absent du keybit), une valeur la réaffecte. C'est le
        mécanisme pour trancher un doublon entre deux télécommandes.
      '';
    };

    extraRemotesDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Répertoire supplémentaire de keymaps `.toml` (couche privée). Même nom
        de fichier qu'une table du module = la version privée gagne.
      '';
    };

    enableDeviceTree = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Poser un overlay qui passe `ir@7040000` en `status = "okay"`. Inutile
        quand le DTS de carte active déjà le nœud (Transpeed 8K618-T) ; requis
        quand il le laisse désactivé (H96 Max H618).

        L'overlay est fourni en `.dtbo` compilé à part : `compileDTS` de
        nixpkgs, utilisé quand on passe un `dtsFile`, tire `kernel.dev` et
        **fait recompiler le noyau**. En `.dtbo`, seuls `dtc` et `fdtoverlay`
        tournent, sur le DTB déjà construit — quelques secondes.
      '';
    };

    dtCompatible = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "allwinner,sun50i-h618" ];
      description = ''
        `compatible` porté à la racine de l'overlay. nixpkgs écarte
        silencieusement un overlay qui n'intersecte pas celui de la carte ; le
        SoC suffit et couvre toutes les cartes H616/H618.
      '';
    };

    inputName = lib.mkOption {
      type = lib.types.str;
      default = "sunxi-ir";
      description = ''
        Nom du périphérique d'entrée créé par rc-core — c'est lui que la règle
        udev doit taguer pour que Kodi/libinput l'énumère. `sunxi-ir` pour le
        décodeur du SoC, `gpio_ir_recv` pour un récepteur GPIO.
      '';
    };

    protocols = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "nec" ];
      description = ''
        Décodeurs activés par `ir-keytable -p`. `nec` couvre NEC, NECX et
        NEC32 : c'est le cas de toutes les télécommandes relevées jusqu'ici.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = unknownRemotes == [ ];
        message = "nixelec.ir.remotes : télécommande(s) inconnue(s) ${lib.concatStringsSep ", " unknownRemotes} — disponibles : ${lib.concatStringsSep ", " availableNames}.";
      }
      {
        assertion = enabledNames != [ ];
        message = "nixelec.ir.remotes : aucune télécommande disponible (répertoire `remotes/` vide ?).";
      }
      {
        assertion = unresolvedConflicts == [ ];
        message = "nixelec.ir : scancode(s) revendiqué(s) avec deux keycodes — ${lib.concatStringsSep " ; " conflictReport}. Trancher avec `nixelec.ir.remoteOverrides`.";
      }
      {
        assertion = orphanOverrides == [ ];
        message = "nixelec.ir.remoteOverrides : scancode(s) absent(s) des tables chargées — ${lib.concatStringsSep ", " orphanOverrides}.";
      }
    ];

    # `ir_nec_decoder` n'a aucun compatible OF : le pruner de modules de nixbian
    # ne le garde que s'il est déclaré ici. Sans lui, `ir-keytable -p nec`
    # échoue et le device reste en mode brut — silencieusement côté Kodi.
    boot.kernelModules = [ "ir_nec_decoder" ];

    hardware.nixbian.overlays = lib.optional cfg.enableDeviceTree {
      name = "ir-enable";
      dtboFile = dtOverlayDtbo;
    };

    # La keymap est la fusion de toutes les télécommandes activées ; le nom du
    # fichier ne change pas quand la liste change, donc `rc_maps.cfg` reste
    # valable pour les outils qui le lisent.
    environment.etc."rc_keymaps/remotes.toml".source = keymap;
    environment.etc."rc_maps.cfg".text = "* * remotes.toml";

    environment.systemPackages = [ v4l ];

    # Sans ce tag, udev ne place pas le device sur un siège et libinput (le
    # backend de Kodi) ne l'énumère jamais : la keymap est chargée mais les
    # touches n'arrivent pas. `ID_INPUT_POINTINGSTICK` est un faux positif du
    # classifieur — le bitmask KEY_* d'une télécommande ressemble à un stick.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="input", ATTRS{name}=="${cfg.inputName}", ENV{ID_SEAT}="seat0", TAG+="seat", ENV{ID_INPUT_KEY}="1", ENV{ID_INPUT_KEYBOARD}="1", ENV{ID_INPUT_POINTINGSTICK}=""
    '';

    systemd.services.ir-keymap = {
      description = "Charge les keymaps IR (toutes les télécommandes configurées)";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" ];
      serviceConfig.Type = "oneshot";
      # Le numéro de `rcN` n'est pas stable : sur ces SoC le CEC HDMI peut
      # occuper rc0. On choisit le premier device dont les protocoles
      # mentionnent celui qu'on veut, jamais par numéro.
      script = ''
        dev=""
        for d in /sys/class/rc/rc*; do
          [ -e "$d/protocols" ] || continue
          for p in ${lib.concatStringsSep " " cfg.protocols}; do
            if grep -qw "$p" "$d/protocols"; then dev=$(basename "$d"); break 2; fi
          done
        done
        if [ -z "$dev" ]; then
          echo "ir-keymap: aucun récepteur IR (nœud DT absent ou désactivé ?)" >&2
          exit 0
        fi
        exec ${v4l}/bin/ir-keytable -s "$dev" -c -p ${lib.concatStringsSep "," cfg.protocols} -w /etc/rc_keymaps/remotes.toml
      '';
    };
  };
}
