{ lib, ... }:

{
  # Orange Pi Zero 3 — Allwinner H618, 1/2/4 GB RAM.
  # The `edge` kernel (nixbian) carries the media and audio patches.
  hardware.nixbian.board = lib.mkDefault "orangepizero3";
  hardware.nixbian.kernelVendor = lib.mkDefault "edge";

  # The VPU and display need a large enough contiguous allocation. Measured
  # on the board: CmaFree dropped to 2 MB of 128 while Kodi played a film and
  # a 765-page allocation failed with -16. 256M is the working value.
  boot.kernelParams = [ "cma=256M" ];
}
