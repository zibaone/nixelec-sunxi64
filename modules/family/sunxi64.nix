{
  config,
  lib,
  options,
  pkgs,
  ...
}:

let
  cfg = config.nixelec;
in
{
  options.nixelec.kernelPackage = lib.mkOption {
    type = lib.types.nullOr lib.types.package;
    default = null;
    description = ''
      Kernel to use. `null` lets nixbian build the per-board kernel
      (buildKernel + board patches). A nixbian family package reproduces
      the reference deployment and shares its store paths.
    '';
  };

  options.nixelec.wifiHardware = lib.mkOption {
    type = lib.types.enum [
      "none"
      "uwe5622"
      "brcmfmac"
    ];
    default = "none";
    description = ''
      WiFi chip physically present on the board. Set by the board module so
      that driver-specific modules can stay inert on boards they do not serve:
      `nixelec.wifi` (UWE5622) is imported for the whole sunxi64 layer, and
      without this marker it would build and load its out-of-tree driver on a
      board that carries a Broadcom SDIO chip instead.
    '';
  };

  options.nixelec.prcmPpu = {
    mode = lib.mkOption {
      type = lib.types.enum [
        "module"
        "builtin"
      ];
      default = "builtin";
      description = ''
        `builtin`: CONFIG_SUN50I_H6_PRCM_PPU=y, provided by the nixbian family
        kernel (family_config.json). No module to load; the domain is registered
        during kernel initialization. This is the default since the family
        kernel carries the symbol.
        `module`: CONFIG_SUN50I_H6_PRCM_PPU=m, the module is loaded from the
        initrd so the power domain is registered before udev/panfrost. Kept as
        the rollback path when a kernel without the builtin symbol is used.
      '';
    };

    assumeKernelBuiltin = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Assume the selected `kernelPackage` was built with
        CONFIG_SUN50I_H6_PRCM_PPU=y. True for the nixbian family kernel, which
        gets the symbols from family_config.json; set false to force the
        assertion when you bring a foreign or older kernel.
      '';
    };

    manageKernelConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        In builtin mode with `kernelPackage = null` (per-board nixbian build),
        append `CONFIG_SUN50I_H6_PRCM_PPU=y` to `hardware.nixbian.extraConfig`.
        Has no effect with the family kernel: the symbol already comes from
        nixbian's family_config.json, and adding it again would fork the
        kernel derivation away from the shared cache.
      '';
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion =
            cfg.prcmPpu.mode == "module" || cfg.kernelPackage == null || cfg.prcmPpu.assumeKernelBuiltin;
          message = ''
            nixelec.prcmPpu.mode = "builtin" requires a kernel built with
            CONFIG_SUN50I_H6_PRCM_PPU=y. Set nixelec.kernelPackage = null
            (nixbian then builds the kernel), or set
            nixelec.prcmPpu.assumeKernelBuiltin = true if your prebuilt kernel
            already has this setting.
          '';
        }
      ];
    }

    (lib.mkIf (cfg.kernelPackage != null) {
      boot.kernelPackages = lib.mkForce (pkgs.linuxPackagesFor cfg.kernelPackage);
    })

    {
      # nixbian provides the kernel, DTB, U-Boot, extlinux, module pruning and
      # firmware. This module only adds the quirks shared by H616/H618.
      hardware.nixbian = {
        enable = lib.mkDefault true;
        family = lib.mkDefault "sunxi64";
        kernelVendor = lib.mkDefault "edge";
        configMode = lib.mkDefault "armbian";
        excludePatchPatterns = [
          ".*armbian-config.*"
          ".*display-logo.*"
        ];
      };

      boot.consoleLogLevel = lib.mkDefault 7;

      # nixbian publishes the Armbian `.config`, which does not contain
      # CONFIG_ARCH_MMAP_RND_BITS_MAX. `nixos/modules/config/sysctl.nix` reads it
      # unconditionally and fails with "Unable to determine mmap_rnd_bits_max".
      # Neutralise only this sysctl file; the kernel keeps its default, which is
      # the maximum. TODO(nixbian): publish the post-olddefconfig `.config`, then
      # remove this override.
      environment.etc."sysctl.d/55-nixos-aslr-entropy.conf".source = lib.mkForce (
        pkgs.writeText "55-nixos-aslr-entropy.conf" ""
      );

      # The nixbian kernel (Armbian sunxi64 config) does not build the generic
      # SATA/SCSI/NVMe drivers that NixOS puts in the initrd module list
      # (`nixos/modules/hardware/all-hardware.nix`):
      #   modprobe: FATAL: Module 3w-9xxx not found
      # → `linux-7.0.14-modules-shrunk` fails, then initrd and the image. Use
      # the board list instead. `mmc_block`, `ext4`, `vfat` and `usbhid` are
      # built in; `dw_mmc`/`dw_mmc-pltfm` are modules and must be in the initrd
      # for the SD card to appear.
      boot.initrd.includeDefaultModules = false;
      boot.initrd.availableKernelModules = lib.mkForce [
        "mmc_block"
        "dw_mmc"
        "dw_mmc-pltfm"
        "ext4"
        "vfat"
      ];

      # HDMI audio: `dw-hdmi-i2s-audio` and `snd-soc-hdmi-codec` are created in
      # software and have no OF `compatible`. DTB-based pruning removes them.
      # `boot.kernelModules` puts them back into the module tree allowlist and
      # loads them at boot.
      #
      # `sun8i_ce` : le moteur crypto H616 (`crypto@1904000`, compatible
      # `allwinner,sun50i-h616-crypto`, sans propriété `status` donc actif) est
      # déjà construit dans la config de famille (`CONFIG_CRYPTO_DEV_SUN8I_CE=m`
      # + HASH/PRNG/TRNG). Il est listé ici pour deux raisons : `boot.kernelModules`
      # alimente `kernelModules.extraKeep`, donc le module survit au pruning DTB,
      # et le chargement ne dépend pas du modalias OF. Il n'accélère PAS LUKS2 :
      # le CE n'expose que cbc/ecb/cts (pas XTS), donc `aes-xts-plain64` reste en
      # logiciel. Le gain réel est sur SHA/PRNG et sur les modes CBC.
      boot.kernelModules =
        [
          "dw-hdmi-i2s-audio"
          "snd-soc-hdmi-codec"
          "sun8i_ce"
          # `CONFIG_ZRAM=m` : sans chargement explicite, /dev/zram0 n'existe pas
          # au démarrage et l'unité de swap générée par zramSwap attend son
          # périphérique pendant 90 s avant d'abandonner (délai observé sur la
          # Transpeed). Charger le module crée zram0 immédiatement.
          "zram"
        ]
        # WiFi SDIO Broadcom, uniquement sur une carte qui en porte un
        # (marqueur posé par le module de carte). Le module n'est pas dans la
        # fermeture si rien ne le référence : le lister le garde et le charge.
        # `brcmfmac` est découpé : l'attache du firmware réclame au runtime
        # `modprobe brcmfmac-wcc` (brcm_fwvid_request_module), et l'élagage
        # retire `brcmfmac-wcc.ko` si rien ne le cite — sans lui :
        #   brcm_fwvid_request_module: mod=wcc: failed 256
        #   brcmf_attach: brcmf_fwvid_attach failed
        # alors que le firmware, lui, se charge correctement.
        ++ lib.optionals (config.nixelec.wifiHardware == "brcmfmac") [
          "brcmfmac"
          "brcmfmac-wcc"
        ];

      hardware.graphics.enable = lib.mkDefault true;
      # Ce noyau n'a pas `CONFIG_FW_LOADER_COMPRESS` (vérifié dans
      # metadata/nix/families/sunxi64/configs/linux-sunxi64-edge.config), alors
      # que NixOS compresse les firmwares en zstd **d'après la version du
      # noyau** (dès 5.19), sans consulter sa configuration réelle. Résultat :
      # tout firmware livré par `hardware.firmware` l'est en `.zst` et n'est
      # jamais chargé — « Direct firmware load for regulatory.db failed with
      # error -2 » à chaque boot, et brcmfmac qui ne trouve pas son `.bin`.
      hardware.firmwareCompression = lib.mkDefault "none";

      # A single extlinux entry on an appliance: no boot menu.
      boot.loader.generic-extlinux-compatible.configurationLimit = lib.mkDefault 0;
    }

    # `=m`: load the power domain from the initrd, before udev.
    # This is the current mode of the nixbian family kernel.
    (lib.mkIf (cfg.prcmPpu.mode == "module") {
      boot.initrd.kernelModules = [ "sun50i_h6_prcm_ppu" ];
      boot.kernelModules = [ "sun50i_h6_prcm_ppu" ];
      boot.extraModprobeConfig = "softdep panfrost pre: sun50i_h6_prcm_ppu";

      # Fallback if an image boots without the fixed initrd: rebind the GPU
      # once the power domain is available.
      systemd.services.panfrost-rebind = {
        description = "Rebind the Mali GPU when the power domain probed too late";
        wantedBy = [ "multi-user.target" ];
        after = [
          "systemd-modules-load.service"
          "systemd-udev-settle.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${pkgs.kmod}/bin/modprobe sun50i_h6_prcm_ppu || true
          if [ ! -e /dev/dri/renderD128 ] && [ -e /sys/bus/platform/devices/1800000.gpu ]; then
            echo 1800000.gpu > /sys/bus/platform/drivers/panfrost/bind || true
          fi
        '';
      };
    })

    # `=y`: nixbian builds the per-board kernel with the symbol built in.
    # `mkAfter` : la ligne atterrit après celles du consommateur. Avec
    # `mkDefault` elle disparaissait dès qu'un consommateur définissait son
    # propre extraConfig, alors que le mode builtin supprime toujours le
    # chargement du module.
    (lib.mkIf
      (cfg.prcmPpu.mode == "builtin" && cfg.kernelPackage == null && cfg.prcmPpu.manageKernelConfig)
      {
        hardware.nixbian.extraConfig = lib.mkAfter "CONFIG_SUN50I_H6_PRCM_PPU=y\n";
      }
    )

    # Faits H616/H618 pour la couche kiosque (`nixelec-kiosk`). Publiés
    # uniquement quand cette couche est importée : `nixelec.platform` n'existe
    # pas sur une image serveur, et un module ne doit pas créer d'option
    # fantôme. Ce sont des FAITS : la carte ne pose jamais `nixelec.kiosk.*`.
    #
    # Mesuré sur la Zero 3 : CEC natif du HDMI en dw-hdmi, connecteur
    # `HDMI-A-1` (le mode 1080p60 est une préférence, jamais `D`), watchdog
    # sunxi-wdt plafonné à 16 s (`max_timeout`).
    (lib.optionalAttrs (options ? nixelec.platform) {
      nixelec.platform = {
        cecDriver = lib.mkDefault "dw-hdmi-cec";
        hdmiConnector = lib.mkDefault "HDMI-A-1";
        videoMode = lib.mkDefault "1920x1080@60";
        # Console série des sunxi : UART 8250 classique.
        consoleTty = lib.mkDefault "ttyS0";
        # Le codec HDMI du H616 n'expose aucun contrôle de mixer : ACP ne
        # construit pas de profil, donc PipeWire ne publie aucun sink HDMI et
        # Kodi retombe sur la sortie analogique (TV muette). Le PCM brut, lui,
        # fonctionne : `ffmpeg -f alsa hw:1,0` en stéréo 48 kHz sort sans
        # erreur, sans ASoC dans dmesg.
        hdmiPcm = lib.mkDefault "hw:1,0";
        watchdog = {
          enable = lib.mkDefault true;
          maxTimeout = lib.mkDefault 16;
        };
      };
    })
  ];
}
