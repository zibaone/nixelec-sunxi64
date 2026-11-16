{
  config,
  lib,
  dtOverlay,
  ...
}:

let
  cfg = config.nixelec.ir;

  # Overlay : le nœud `ir@7040000` est présent dans `sun50i-h616.dtsi` mais
  # `status = "disabled"`. L'overlay ne fait que l'activer ; la broche (PH10)
  # est déjà câblée par `ir_rx_pin`.
  #
  # nixpkgs n'applique un overlay que si son `compatible` intersecte celui de
  # la carte : sans cette ligne il est **silencieusement sauté** (« set() is
  # incompatible »). D'où `dtCompatible`, qui vise le SoC par défaut.
  irOverlayDts = ''
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

  # Compilation par le mécanisme commun (flake.lib.mkDtbo) : dtc seul, pas de
  # kernel.dev, donc pas de recompilation du noyau.
  dtOverlayDtbo = dtOverlay.mkDtbo {
    name = "ir-enable";
    dts = irOverlayDts;
  };
in
{
  options.nixelec.ir = {
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
  };

  config = lib.mkIf cfg.enable {
    nixelec.ir.inputName = lib.mkDefault "sunxi-ir";

    hardware.nixbian.overlays = lib.optional cfg.enableDeviceTree {
      name = "ir-enable";
      dtboFile = dtOverlayDtbo;
    };
  };
}
