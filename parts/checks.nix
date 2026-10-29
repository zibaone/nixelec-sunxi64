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
          echo ${builtins.unsafeDiscardStringContext self.nixosConfigurations.orangepizero3.config.system.build.toplevel.drvPath} > $out
        '';

        eval-orangepizero3-cache = pkgs.runCommand "check-eval-orangepizero3-cache" { } ''
          echo ${builtins.unsafeDiscardStringContext self.nixosConfigurations.orangepizero3-cache.config.system.build.toplevel.drvPath} > $out
        '';

        # Builtin mode must load neither the module, nor the softdep, nor the
        # rebind service. We test option wiring with a prebuilt kernel
        # (assumeKernelBuiltin): no aarch64 IFD on the .config.
        prcm-ppu-loading =
          let
            # Default is builtin since P3.2: the family kernel carries the
            # symbol, so nothing is loaded from the initrd and no rebind runs.
            # `module` stays the rollback wiring (with a kernel that has =m).
            moduleMode = self.nixosConfigurations.orangepizero3.extendModules {
              modules = [
                {
                  nixelec.prcmPpu.mode = "module";
                }
              ];
            };
            builtinWithKernel = self.nixosConfigurations.orangepizero3.extendModules {
              modules = [
                {
                  nixelec.prcmPpu.mode = "builtin";
                  nixelec.kernelPackage = null;
                }
              ];
            };
            builtinWithConsumer = self.nixosConfigurations.orangepizero3.extendModules {
              modules = [
                {
                  nixelec.prcmPpu.mode = "builtin";
                  nixelec.kernelPackage = null;
                  hardware.nixbian.extraConfig = "CONFIG_DEBUG_INFO_NONE=y\n";
                }
              ];
            };
          in
          pkgs.runCommand "check-prcm-ppu-loading"
            {
              defaultInitrd = builtins.toJSON self.nixosConfigurations.orangepizero3.config.boot.initrd.kernelModules;
              defaultModules = builtins.toJSON self.nixosConfigurations.orangepizero3.config.boot.kernelModules;
              moduleInitrd = builtins.toJSON moduleMode.config.boot.initrd.kernelModules;
              moduleModules = builtins.toJSON moduleMode.config.boot.kernelModules;
              builtinExtraConfig = builtinWithKernel.config.hardware.nixbian.extraConfig;
              consumerExtraConfig = builtinWithConsumer.config.hardware.nixbian.extraConfig;
              defaultRebind = builtins.hasAttr "panfrost-rebind" self.nixosConfigurations.orangepizero3.config.systemd.services;
              moduleRebind = builtins.hasAttr "panfrost-rebind" moduleMode.config.systemd.services;
            }
            ''
              set -euo pipefail
              ! echo "$defaultInitrd" | grep -q sun50i_h6_prcm_ppu
              ! echo "$defaultModules" | grep -q sun50i_h6_prcm_ppu
              echo "$moduleInitrd" | grep -q sun50i_h6_prcm_ppu
              echo "$moduleModules" | grep -q sun50i_h6_prcm_ppu
              echo "$builtinExtraConfig" | grep -q '^CONFIG_SUN50I_H6_PRCM_PPU=y$'
              # A consumer assigning its own extraConfig must not drop the line:
              # it has to stay the last one (kconfig keeps the last occurrence).
              last=$(printf '%s\n' "$consumerExtraConfig" | grep -v '^$' | tail -1)
              test "$last" = "CONFIG_SUN50I_H6_PRCM_PPU=y"
              test "$defaultRebind" = ""
              test "$moduleRebind" = "1"
              touch $out
            '';

        # The effective default .config must end with the symbol the default
        # mode expects. Builtin is the default since P3.2, and the family line
        # comes from nixbian's family_config.json: if Armbian or the generator
        # drops it, the image boots without the power domain and the CI would
        # stay green. The `.config` derivation builds in ~1 s on x86.
        prcm-ppu-default-config = pkgs.runCommand "check-prcm-ppu-default-config" { } ''
          last=$(grep '^CONFIG_SUN50I_H6_PRCM_PPU=' ${self.nixosConfigurations.orangepizero3.config.boot.kernelPackages.kernel.configfile} | tail -1)
          test "$last" = "CONFIG_SUN50I_H6_PRCM_PPU=y"
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
          builtin = self.nixosConfigurations.orangepizero3.extendModules {
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
