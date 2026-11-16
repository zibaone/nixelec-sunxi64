{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec.frontPanel;
  fd6xx = pkgs.callPackage ../../packages/fd6xx { };

  # La commande est construite ici pour que `text` puisse contenir des
  # espaces sans casser le script systemd.
  action = if cfg.text == "" then "blank" else "write ${lib.escapeShellArg cfg.text}";
in
{
  # Afficheur de facade 7 segments des boites H616/H618 (FD650/FD655).
  #
  # OPT-IN ET DESACTIVE PAR DEFAUT, volontairement : un afficheur est un
  # accessoire. Il ne doit ni retarder le boot, ni le faire echouer. L'unite
  # est donc `oneshot` + `RemainAfterExit`, n'a aucun `before=` sur une cible
  # du boot, et son script termine toujours en 0 (`|| true`).
  #
  # Pourquoi en espace utilisateur et non en pilote noyau : la puce **n'ACK
  # pas** (mesure sur les deux cartes), or `i2c-gpio` exige un ACK — le
  # couple i2c-gpio + tm16xx rend `-ENXIO` au premier octet. Il faudrait
  # ecrire un pilote dedie (bit-bang maison) ; c'est le bon produit a terme,
  # mais l'outil en espace utilisateur permet d'iterer sur le protocole sans
  # recompiler un noyau aarch64 (~45 min a 3 h sous emulation). Voir
  # `docs/affichage-facade.md` pour l'arbitrage et les mesures.
  options.nixelec.frontPanel = {
    enable = lib.mkEnableOption "afficheur facade 7 segments FD650/FD655 (2 fils bit-banges)";

    chip = lib.mkOption {
      type = lib.types.str;
      default = "/dev/gpiochip1";
      description = ''
        Peripherique gpio-v2 du controleur PIO principal (`300b000.pinctrl`).
        Attention : la numerotation des noeuds `/dev/gpiochipN` n'est pas
        celle de `/sys/class/gpio` — sur ces cartes le PIO principal est
        `gpiochip1` alors que son `base` sysfs est 0.
      '';
    };

    clk = lib.mkOption {
      type = lib.types.int;
      default = 226;
      description = ''
        Numero GPIO global de l'horloge (offset dans `chip`). 226 = PH2 sur
        la H96 Max H618, mesure et confirme a l'ecran.
      '';
    };

    dat = lib.mkOption {
      type = lib.types.int;
      default = 227;
      description = "Numero GPIO global des donnees. 227 = PH3 sur la H96.";
    };

    brightness = lib.mkOption {
      type = lib.types.ints.between 0 7;
      default = 3;
      description = "Luminosite, 0 (1/8 de rapport cyclique) a 7 (8/8).";
    };

    text = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Texte affiche au demarrage (5 caracteres au plus, chiffres et un jeu
        de lettres). Vide = afficheur eteint, ce qui est le comportement le
        plus sur : rien ne s'allume si la carte n'a pas d'afficheur.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # L'outil reste disponible en console pour verifier a la main
    # (`fd6xx test`, `fd6xx write 1234`) : c'est la seule verification qui
    # vaille pour un afficheur.
    environment.systemPackages = [ fd6xx ];

    systemd.services.front-panel = {
      description = "Afficheur facade 7 segments (FD650/FD655)";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${fd6xx}/bin/fd6xx \
          --chip ${lib.escapeShellArg cfg.chip} \
          --clk ${toString cfg.clk} \
          --dat ${toString cfg.dat} \
          --brightness ${toString cfg.brightness} \
          ${action} || true
      '';
    };
  };
}
