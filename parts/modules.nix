{ inputs, ... }:

let
  # Modèle B (2026-11-16) : la couche famille construit elle-même le noyau
  # sunxi64. nixbian ne fournit plus que l'export Armbian vanilla (sources,
  # série de patches, configuration) ; les patches vendor/board vivent ici.
  #
  # Un seul noyau pour toutes les cartes H616/H618 de la couche : il porte
  # l'union des patches et de la configuration mesurés sur la Zero3, la
  # Transpeed et la H96. Les différences entre cartes tiennent dans les données
  # de carte (DTB, modules, services), pas dans quatre noyaux distincts.
  familyKernel =
    # `extraConfig` : fragment ajouté APRÈS la configuration mesurée de la
    # famille. Sert aux noyaux dérivés qui ont besoin d'options en plus sans
    # toucher au noyau des kiosques (ex. noyau de transport : CONFIG_KEXEC).
    {
      pkgs,
      extraConfig ? "",
      ...
    }:
    let
      lib = pkgs.lib;
      helpers = import (inputs.nixbian.outPath + "/metadata/nix/library.nix") { inherit pkgs; };
      platforms = import (inputs.nixbian.outPath + "/metadata/nix/families/sunxi64/platforms.nix");
      base = platforms."sunxi64-edge";
      system = pkgs.stdenv.hostPlatform.system;
      kernelSrc = inputs.nixbian.legacyPackages.${system}.sunxi64.kernelSrcs."sunxi64-edge";
      # Le `platforms.nix` de nixbian généré avant la bascule B peut encore
      # lister les quatre répertoires vendor. Ils vivent maintenant dans
      # `patches/kernel` de cette couche : on les retire de la liste nixbian
      # avant d'ajouter les patches locaux. L'export nixbian est régénéré
      # séparément (le filtre reste alors sans effet).
      baseKernelPatches = builtins.filter (p: builtins.match ".*/sunxi-7\\.0-[^/]+/[^/]+$" p == null) (
        base.kernel.patches or [ ]
      );
      meta = base // {
        linux_family = "sunxi64";
        family = "sunxi64";
        kernel = base.kernel // {
          src = kernelSrc;
          patches = baseKernelPatches;
        };
      };

      patchDir = ../patches/kernel;

      # Patches venus de l'ancien export nixbian : ils ne sont pas Armbian.
      # L'ordre compte : l'AIC8800 patch suit le backport 3401 de la série
      # Armbian, et les DTS H96/Transpeed arrivent après les patches Ethernet.
      vendorPatches =
        lib.concatMap
          (
            dir:
            map (name: "${patchDir}/${dir}/${name}") (
              builtins.filter (name: builtins.match ".*\\.patch" name != null) (
                builtins.attrNames (builtins.readDir "${patchDir}/${dir}")
              )
            )
          )
          [
            "sunxi-7.0-hdmi-audio"
            "sunxi-7.0-cec"
            "sunxi-7.0-h96-max"
            # Apres h96-max : son 0001 modifie la dtsi H96 que ce dernier cree.
            "sunxi-7.0-board-audio"
            "sunxi-7.0-aic8800-kbuild"
          ];

      # Ordre mesuré : DTS Transpeed (0002 puis 0004), VP9 avant les fences
      # cedrus, CEC après. Un chemin de source en store porte son nom, donc ne
      # pas renommer ces fichiers sans accepter un nouveau hash de noyau.
      localPatches = map (name: "${patchDir}/${name}") [
        "0001-net-phy-add-ac300-ephy.patch"
        "0002-arm64-dts-h616-emac1-ac300.patch"
        "0003-net-stmmac-sun8i-h616-emac1.patch"
        "0004-arm64-dts-h616-transpeed-sunxi-gmac.patch"
        "0004-net-phy-xpowers-acx00-backport.patch"
        "0005-clk-sunxi-ng-emac25m-from-pll-periph0.patch"
        "0006-asoc-sun4i-codec-h616-analog-out-defaults.patch"
        "vp9-cedrus-7.0.14.patch"
        "cedrus-wait-dst-fences.patch"
        "cec-restore-phys-addr-hpd.patch"
      ];

      # Union des configurations mesurées sur la H96 et la Transpeed. Le
      # `family_config.json` de nixbian apporte déjà CONFIG_SUN50I_H6_PRCM_PPU=y;
      # ces lignes-ci sont l'Ethernet vendor et ses dépendances.
      familyExtraConfig = ''
        CONFIG_AC300_PHY=y
        CONFIG_XPOWERS_ACX00_PHY=m
        CONFIG_AW_GMAC=m
        CONFIG_AW_GMAC_MDIO=m
        CONFIG_AW_EPHY=m
        CONFIG_DWMAC_SUN8I=m
        CONFIG_MODULE_ALLOW_BTF_MISMATCH=y
        CONFIG_PWM_SUNXI_ENHANCE=m

        # ────────────────────────────────────────────────────────────────
        #  kexec — étage 2 de l'installation (nixos-anywhere)
        #
        #  `nixos-anywhere --kexec` charge le noyau de l'installateur par
        #  `kexec_load`. Mesuré sur le noyau déployé (2026-11-19) :
        #  `# CONFIG_KEXEC is not set` → « kexec_load failed: Function not
        #  implemented ».
        #
        #  Ces deux symboles sont dans la configuration de FAMILLE, pas dans
        #  un noyau dérivé : les deux box eMMC (H96, Transpeed) n'ont pas de
        #  slot SD, donc leur seul transport est FEL — à 316 Ko/s. Un payload
        #  minimal (sans `nix`) plus un tarball kexec coûte ~8 min de
        #  transfert ; un payload qui embarque `nix` en coûterait 18. Le
        #  second noyau, lui, coûtait un build de 4 h qui n'était jamais en
        #  cache. Un noyau, une dérivation, un cache.
        #
        #  Contrepartie assumée : `kexec` est compilé pour les kiosques. Il
        #  exige `CAP_SYS_BOOT` (`kernel/kexec_core.c:1117`,
        #  `kexec_load_permitted`) et se coupe à chaud par
        #  `kernel.kexec_load_disabled=1` — posé sur les kiosques, absent du
        #  transport.
        # ────────────────────────────────────────────────────────────────
        CONFIG_KEXEC=y
        CONFIG_KEXEC_FILE=y

        # ────────────────────────────────────────────────────────────────
        #  Bornes de randomisation d'adresse, écrites explicitement
        #
        #  La configuration Armbian est un `savedefconfig` : les symboles
        #  restés à leur valeur par défaut n'y figurent pas. Or nixpkgs
        #  (25.11+) calcule `55-nixos-aslr-entropy.conf` en grepant
        #  `CONFIG_ARCH_MMAP_RND_BITS_MAX` dans
        #  `boot.kernelPackages.kernel.configfile`, et sort en 1 **sans
        #  message** si le motif manque — ce qui ressemble à un échec de
        #  construction aarch64. Mesuré le 2026-11-20 sur le payload FEL de la
        #  H96 (72 dérivations, arrêt sur celle-ci, `builder failed with exit
        #  code 1`, aucun log).
        #
        #  Valeurs arm64 / VA 48 bits pour 7.0.x : celles que `olddefconfig`
        #  matérialise dans la configuration finale.
        # ────────────────────────────────────────────────────────────────
        CONFIG_ARCH_MMAP_RND_BITS=18
        CONFIG_ARCH_MMAP_RND_BITS_MIN=18
        CONFIG_ARCH_MMAP_RND_BITS_MAX=33
        CONFIG_ARCH_MMAP_RND_COMPAT_BITS=11
        CONFIG_ARCH_MMAP_RND_COMPAT_BITS_MIN=11
        CONFIG_ARCH_MMAP_RND_COMPAT_BITS_MAX=16
      '';
    in
    let
      kernel = helpers.buildKernel {
        inherit meta;
        extraConfig = familyExtraConfig + extraConfig;
        extraPatches = localPatches ++ vendorPatches;
        dtb_list = [
          "allwinner/sun50i-h618-orangepi-zero3.dtb"
          "allwinner/sun50i-h618-transpeed-8k618-t.dtb"
          "allwinner/sun50i-h618-h96-max.dtb"
        ];
        configMode = "armbian";
      };
    in
    kernel
    // {
      # Le garde-fou HavenOS (`cedrus-vp9-guard.nix`) vérifie la présence des
      # patches VP9/fencing dans le noyau du kiosque. Sous le modèle B ils sont
      # dans cette couche, donc on les expose ici.
      passthru = (kernel.passthru or { }) // {
        patches = localPatches ++ vendorPatches;
        linuxFamily = "sunxi64";
        platformKey = "sunxi64-edge";
        branch = base.branch or "linux-7.0.y";
      };
    };
in
{
  # Noyau de famille, avec un fragment de configuration optionnel. Exposé pour
  # les noyaux dérivés d'un consommateur (HavenOS : noyau de transport FEL, qui
  # a besoin de CONFIG_KEXEC sans imposer un rebuild du noyau des kiosques).
  # Les patches et la configuration mesurée restent ici : un patch, une couche.
  flake.lib.mkSunxi64Kernel =
    {
      pkgs,
      extraConfig ? "",
    }:
    familyKernel { inherit pkgs extraConfig; };

  flake.nixosModules = {
    # Family base: nixbian + sunxi64 quirks (GPU, HDMI audio, console).
    # Le noyau est produit ici, plus par nixbian (modèle B).
    sunxi64 =
      {
        lib,
        pkgs,
        ...
      }:
      {
        imports = [
          inputs.nixbian.nixosModules.nixbian
          inputs.nixelec-common.nixosModules.video-codecs
          ../modules/family/sunxi64.nix
        ];

        nixelec.kernelPackage = lib.mkDefault (familyKernel {
          inherit pkgs;
        });
        # Le garde-fou HavenOS vérifie cette liste ; sous le modèle B le noyau
        # de famille porte ces patches, mais on les déclare aussi ici pour que
        # le repli nixbian et le garde-fou restent cohérents.
        hardware.nixbian.extraPatches = lib.mkForce [
          ../patches/kernel/vp9-cedrus-7.0.14.patch
          ../patches/kernel/cedrus-wait-dst-fences.patch
          ../patches/kernel/cec-restore-phys-addr-hpd.patch
        ];
      };

    # Board: Orange Pi Zero 3 (H618). Le noyau de famille porte les patches
    # VP9/cedrus/CEC ; la carte n'ajoute que ses données et ses services.
    orangepizero3 =
      { ... }:
      {
        imports = [
          inputs.self.nixosModules.sunxi64
          ../modules/boards/orangepizero3.nix
        ];
      };

    # Board: Transpeed 8K618-T (H618 TV box, board entry local to nixbian).
    transpeed-8k618-t =
      { ... }:
      {
        imports = [
          inputs.self.nixosModules.sunxi64
          ../modules/boards/transpeed-8k618-t.nix
        ];
      };

    # Board: H96 Max H618 (H618 TV box, eMMC only, board entry local to nixbian).
    h96-max-h618 =
      { ... }:
      {
        imports = [
          inputs.self.nixosModules.sunxi64
          ../modules/boards/h96-max-h618.nix
        ];
      };

    # Driver-agnostic WPA client: wpa_supplicant + PSK rendered from a secret
    # file at boot. No driver, no firmware, no PSK in the store.
    # Implementation in nixelec-common; the option name is unchanged
    # (`nixelec.wifiClient`), so this is a pure re-export.
    wifi-client = inputs.nixelec-common.nixosModules.wifi-client;

    # UWE5622 WiFi: driver, firmware, wpa_supplicant. Disabled by default.
    # The wrapper imports the common client; the module itself only provides
    # the out-of-tree driver and its firmware.
    wifi-uwe5622 =
      { ... }:
      {
        imports = [
          inputs.nixelec-common.nixosModules.wifi-client
          ../modules/services/wifi-uwe5622.nix
        ];
      };

    # Allwinner SD image: U-Boot at offset 8 KiB, extlinux, DTB.
    sd-image = ../modules/image/sunxi-sd.nix;

    # Racine sur eMMC : contrat dans nixelec-common (fileSystems."/" par
    # etiquette, bootloader-agnostique). Cette couche ajoute les outils de banc
    # (bench) que les configurations installees utilisaient.
    emmc-root =
      { pkgs, ... }:
      {
        imports = [ inputs.nixelec-common.nixosModules.emmc-root ];
        nixelec.emmc.extraPackages = [ (pkgs.callPackage ../packages/bench { }) ];
      };

    # MAC déterministe dérivée de la SID, pour les cartes qui n'ont aucune
    # adresse gravée en usine (les deux H618 de ce dépôt).
    mac-from-sid = ../modules/system/mac-from-sid.nix;

    # Afficheur facade 7 segments FD650/FD655 (2 fils bit-banges), en espace
    # utilisateur. Desactive par defaut : un afficheur ne doit pas pouvoir
    # casser un boot. Broches et protocole mesures : docs/affichage-facade.md.
    front-panel = inputs.nixelec-common.nixosModules.front-panel;

    # Profil de dalle H96 Max H618, donnee de carte et non de flotte : la
    # couche carte le fournit aux configurations qui l'importent (bring-up
    # eMMC et composition kiosque). Le contrat fd6xx reste dans
    # nixelec-common ; ce module ne fait que poser les valeurs mesurees.
    h96-max-h618-front-panel = {
      imports = [ inputs.nixelec-common.nixosModules.front-panel ];
      nixelec.frontPanel = {
        enable = true;
        chip = "/dev/gpiochip1";
        clk = 226;
        dat = 227;
        pushPull = true;
        text = "H96";
        layout = {
          digits = 5;
          digitBase = 104; # 0x68
          digitStride = 2;
        };
        # Dalle mesurée le 2026-11-23, icône par icône (`fd6xx scan --addr 0x66`)
        # puis confirmée à l'écran : sept icônes sur l'octet 0x66, dans cet
        # ordre de bits. Ce n'est PAS l'écriture de 0x66 qui éteint la dalle —
        # c'est la valeur `0x7f` qui porte les sept bits à la fois (mesuré le
        # 2026-11-25 : `--bit 102:16` allume le colon, `--bit 102:32` allume
        # lan, sans toucher aux chiffres). Un bit isolé s'écrit normalement.
        layout.icons = {
          alarm = {
            address = 102; # 0x66
            mask = 1;
          };
          usb = {
            address = 102;
            mask = 2;
          };
          pause = {
            address = 102;
            mask = 4;
          };
          play = {
            address = 102;
            mask = 8;
          };
          colon = {
            address = 102;
            mask = 16; # 0x10 — le « : » entre HH et MM
          };
          lan = {
            address = 102;
            mask = 32; # 0x20
          };
          wifi = {
            address = 102;
            mask = 64; # 0x40
          };
        };
        # Rien d'allumé en permanence : les icônes d'état sont pilotées par
        # `front-panel-clock` (lan = `operstate` de eth0, wifi = association
        # de wlan0), et le colon clignote une seconde sur deux.
        icons = [ ];
        status = {
          enable = true;
          ethernetIcon = "lan";
          wifiIcon = "wifi";
        };
        clock = {
          enable = true;
          colonIcon = "colon";
        };
      };
    };

    # Profil de dalle Transpeed 8K618-T : même protocole 2 fils que la H96,
    # mais 4 positions, adresse 0x68 à gauche et pas de pull-up interne.
    # La colonne et les icônes viennent de la table vendor ; seuls les
    # chiffres et l'horloge sont utilisés au boot, les icônes restant à
    # mesurer sur cette dalle.
    transpeed-8k618-t-front-panel = {
      imports = [ inputs.nixelec-common.nixosModules.front-panel ];
      nixelec.frontPanel = {
        enable = true;
        chip = "/dev/gpiochip1";
        clk = 267;
        dat = 268;
        pushPull = true;
        leftToRight = true;
        text = "8618";
        layout = {
          digits = 4;
          digitBase = 104; # 0x68
          digitStride = 2;
        };
        # Aucune icône mesurée sur cette dalle : le 2026-11-26, les huit bits
        # de l'octet 0x66 puis le point décimal de chacune des quatre
        # positions ont été allumés un par un, sans qu'aucun ne produise quoi
        # que ce soit à l'écran. Elle affiche l'heure, et rien d'autre.
        icons = [ ];
        # Pas d'icônes d'état tant que les masques ne sont pas mesurés : les
        # assertions du module exigent que les noms existent dans layout.icons.
        status = {
          ethernetIcon = null;
          wifiIcon = null;
        };
        clock = {
          enable = true;
          colonIcon = null;
        };
      };
    };

    # IR : tables, fusion, gardes et keymap dans nixelec-common ; cette couche
    # apporte le recepteur sunxi-ir et l'overlay qui active ir@7040000.
    ir =
      { pkgs, ... }:
      {
        _module.args.dtOverlay = inputs.nixelec-common.lib { inherit pkgs; };
        imports = [
          inputs.nixelec-common.nixosModules.ir
          ../modules/services/ir.nix
        ];
      };
  };
}
