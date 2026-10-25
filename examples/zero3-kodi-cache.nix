{ ... }:

{
  imports = [ ./zero3-kodi.nix ];

  # Cache build: install the UWE5622 driver and firmware without associating
  # to a network.
  nixelec.wifi.enable = true;
}
