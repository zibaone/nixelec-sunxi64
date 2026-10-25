{ ... }:

{
  imports = [ ./zero3-kodi.nix ];

  # CONFIG_SUN50I_H6_PRCM_PPU=y: nixbian builds the per-board kernel with the
  # power domain built in. No module is loaded.
  nixelec.prcmPpu.mode = "builtin";
  nixelec.kernelPackage = null;
}
