{ inputs, ... }:

let
  # Same kernel as the reference deployment selects for its sunxi64 boards:
  # the nixbian family kernel, not the per-board buildKernel of the nixbian
  # module. Without this, store paths diverge and the shared cache no longer
  # serves. A consumer can set `null` to use nixbian's per-board kernel.
  familyKernel =
    { config, pkgs, ... }:
    let
      system = pkgs.stdenv.hostPlatform.system;
      family = "sunxi64";
      key = "sunxi64-${config.hardware.nixbian.kernelVendor}";
      legacy = inputs.nixbian.legacyPackages.${system} or { };
      familyPackages = legacy.${family} or { };
      kernels = familyPackages.kernels or { };
    in
    if builtins.hasAttr key kernels then
      kernels.${key}
    else
      throw ''
        nixelec: nixbian does not expose legacyPackages.${system}.${family}.kernels.${key}.
        Check the nixbian input and hardware.nixbian.kernelVendor.
      '';
in
{
  flake.nixosModules = {
    # Family base: nixbian + sunxi64 quirks (GPU, HDMI audio, console).
    sunxi64 =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      {
        imports = [
          inputs.nixbian.nixosModules.nixbian
          ../modules/family/sunxi64.nix
        ];

        nixelec.kernelPackage = lib.mkDefault (familyKernel {
          inherit config pkgs;
        });
      };

    # Board: Orange Pi Zero 3 (H618).
    orangepizero3 =
      { ... }:
      {
        imports = [
          inputs.nixbian.nixosModules.nixbian
          ../modules/family/sunxi64.nix
          ../modules/boards/orangepizero3.nix
        ];

        # Pas de `familyKernel` ici : la carte porte ses propres patches noyau
        # (VP9 + fencing), posés par `modules/boards/orangepizero3.nix`. Un
        # paquet noyau de famille les ignorerait (`boot.kernelPackages` est
        # forcé), donc `null` laisse nixbian construire le noyau de la carte.
        # C'est ce noyau que le job `cache` de la CI construit et publie, et
        # que HavenOS consomme ensuite : même nixpkgs, même nixbian, donc même
        # chemin de store des deux côtés.
        nixelec.kernelPackage = null;
      };

    # Board: Transpeed 8K618-T (H618 TV box, board entry local to nixbian).
    transpeed-8k618-t =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      {
        imports = [
          inputs.nixbian.nixosModules.nixbian
          ../modules/family/sunxi64.nix
          ../modules/boards/transpeed-8k618-t.nix
        ];

        # Pas de `familyKernel` ici : cette carte porte ses propres patches
        # noyau (Ethernet EMAC1 + PHY AC300) et sa propre config, posés par
        # `modules/boards/transpeed-8k618-t.nix`. Un paquet noyau de famille
        # les ignorerait (`boot.kernelPackages` est forcé), donc `null` laisse
        # nixbian construire le noyau de la carte. Aucune autre carte n'est
        # affectée : le chemin de store diffère, et c'est voulu.
        nixelec.kernelPackage = null;
      };

    # Driver-agnostic WPA client: wpa_supplicant + PSK rendered from a secret
    # file at boot. No driver, no firmware, no PSK in the store.
    wifi-client = ../modules/services/wifi-client.nix;

    # UWE5622 WiFi: driver, firmware, wpa_supplicant. Disabled by default.
    # Imports `wifi-client` for the supplicant part.
    wifi-uwe5622 = ../modules/services/wifi-uwe5622.nix;

    # Allwinner SD image: U-Boot at offset 8 KiB, extlinux, DTB.
    sd-image = ../modules/image/sunxi-sd.nix;
  };
}
