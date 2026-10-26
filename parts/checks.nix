{ self, ... }:

{
  perSystem =
    {
      lib,
      pkgs,
      system,
      ...
    }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks = {
        # Evaluation only: fast, and enough to catch a renamed option or a
        # module that no longer resolves.
        eval-orangepizero3 = pkgs.runCommand "check-eval-orangepizero3" { } ''
          echo ${builtins.unsafeDiscardStringContext self.nixosConfigurations.orangepizero3-kodi.config.system.build.toplevel.drvPath} > $out
        '';

        eval-orangepizero3-addons = pkgs.runCommand "check-eval-orangepizero3-addons" { } ''
          echo ${builtins.unsafeDiscardStringContext self.nixosConfigurations.orangepizero3-kodi-addons.config.system.build.toplevel.drvPath} > $out
        '';

        kodi-cec-addons =
          pkgs.runCommand "check-kodi-cec-addons"
            {
              cecReprobe = builtins.toJSON (
                builtins.hasAttr "hdmi-cec-reprobe" self.nixosConfigurations.orangepizero3-kodi.config.systemd.services
              );
              cecDefaults = builtins.toJSON (
                builtins.hasAttr "kodi-cec-defaults" self.nixosConfigurations.orangepizero3-kodi.config.systemd.services
              );
              addonsUnit = builtins.toJSON (
                builtins.hasAttr "kodi-addons" self.nixosConfigurations.orangepizero3-kodi-addons.config.systemd.services
              );
              kernelModules = builtins.toJSON (
                self.nixosConfigurations.orangepizero3-kodi.config.boot.kernelModules
              );
            }
            ''
              set -euo pipefail
              test "$cecReprobe" = "true"
              test "$cecDefaults" = "true"
              test "$addonsUnit" = "true"
              echo "$kernelModules" | grep -q '"dw-hdmi-cec"'
              touch $out
            '';

        # Builtin mode must load neither the module, nor the softdep, nor the
        # rebind service. We test option wiring with a prebuilt kernel
        # (assumeKernelBuiltin): no aarch64 IFD on the .config.
        prcm-ppu-loading =
          let
            builtin = self.nixosConfigurations.orangepizero3-kodi.extendModules {
              modules = [
                {
                  nixelec.prcmPpu.mode = "builtin";
                  nixelec.prcmPpu.assumeKernelBuiltin = true;
                }
              ];
            };
            builtinWithKernel = self.nixosConfigurations.orangepizero3-kodi.extendModules {
              modules = [
                {
                  nixelec.prcmPpu.mode = "builtin";
                  nixelec.kernelPackage = null;
                }
              ];
            };
          in
          pkgs.runCommand "check-prcm-ppu-loading"
            {
              defaultInitrd = builtins.toJSON self.nixosConfigurations.orangepizero3-kodi.config.boot.initrd.kernelModules;
              defaultModules = builtins.toJSON self.nixosConfigurations.orangepizero3-kodi.config.boot.kernelModules;
              builtinInitrd = builtins.toJSON builtin.config.boot.initrd.kernelModules;
              builtinModules = builtins.toJSON builtin.config.boot.kernelModules;
              builtinExtraConfig = builtinWithKernel.config.hardware.nixbian.extraConfig;
              defaultRebind = builtins.hasAttr "panfrost-rebind" self.nixosConfigurations.orangepizero3-kodi.config.systemd.services;
              builtinRebind = builtins.hasAttr "panfrost-rebind" builtin.config.systemd.services;
            }
            ''
              set -euo pipefail
              echo "$defaultInitrd" | grep -q sun50i_h6_prcm_ppu
              echo "$defaultModules" | grep -q sun50i_h6_prcm_ppu
              ! echo "$builtinInitrd" | grep -q sun50i_h6_prcm_ppu
              ! echo "$builtinModules" | grep -q sun50i_h6_prcm_ppu
              echo "$builtinExtraConfig" | grep -q '^CONFIG_SUN50I_H6_PRCM_PPU=y$'
              test "$defaultRebind" = "1"
              test "$builtinRebind" = ""
              touch $out
            '';

        # The default mode must carry `=m`: if Armbian removes or flips the
        # symbol, the default image boots without the power domain and the CI
        # stays green. The `.config` derivation builds in ~1 s on x86.
        prcm-ppu-default-config =
          pkgs.runCommand "check-prcm-ppu-default-config" { } ''
            last=$(grep '^CONFIG_SUN50I_H6_PRCM_PPU=' ${self.nixosConfigurations.orangepizero3-kodi.config.boot.kernelPackages.kernel.configfile} | tail -1)
            test "$last" = "CONFIG_SUN50I_H6_PRCM_PPU=m"
            touch $out
          '';

        # `switch` must not restart Kodi: systemctl restart of a
        # `Restart = "always"` unit can fail and makes the switch return 4.
        kodi-restart-policy =
          pkgs.runCommand "check-kodi-restart-policy"
            {
              restartIfChanged = builtins.toJSON self.nixosConfigurations.orangepizero3-kodi.config.systemd.services.kodi-gbm.restartIfChanged;
              restart = builtins.toJSON self.nixosConfigurations.orangepizero3-kodi.config.systemd.services.kodi-gbm.serviceConfig.Restart;
            }
            ''
              set -euo pipefail
              test "$restartIfChanged" = "false"
              test "$restart" = '"always"'
              touch $out
            '';

        formatting =
          pkgs.runCommand "check-nixfmt"
            {
              nativeBuildInputs = [ pkgs.nixfmt ];
            }
            ''
              find ${self} -name '*.nix' -exec nixfmt --check {} +
              touch $out
            '';
      };
    }
    // lib.optionalAttrs (system == "aarch64-linux") {
      checks.prcm-ppu-builtin-config =
        let
          builtin = self.nixosConfigurations.orangepizero3-kodi.extendModules {
            modules = [
              {
                nixelec.prcmPpu.mode = "builtin";
                nixelec.kernelPackage = null;
              }
            ];
          };
        in
        pkgs.runCommand "check-prcm-ppu-builtin-config" { } ''
          grep -q '^CONFIG_SUN50I_H6_PRCM_PPU=y$' ${builtin.config.boot.kernelPackages.kernel.configfile}
          touch $out
        '';
    };
}
