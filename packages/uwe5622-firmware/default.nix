{
  lib,
  stdenvNoCC,
  fetchurl,
}:

# UWE5622 (AW859A) combo firmware for the Orange Pi Zero 3.
#
# Two files:
#   - wcnmodem.bin: raw image for chipid 0x2355b001 (MARLIN3L_AB);
#   - wifi_2355b001_1ant.ini: RF calibration, single antenna.
#
# The vendor tree's `wcnmodem.bin.hex` pack is not suitable: it is tagged
# 3EAB/3LAB while the Allwinner variant expects MLAA/MLAB.
let
  wcnmodem = fetchurl {
    url = "https://raw.githubusercontent.com/armbian/firmware/master/uwe5622/wcnmodem.bin";
    sha256 = "102sf7klpqlajy6bgs0g4zrsr1gyp0zjkxv2fjk38mw76378g6qi";
  };

  ini = fetchurl {
    url = "https://raw.githubusercontent.com/armbian/firmware/master/uwe5622/wifi_2355b001_1ant.ini";
    sha256 = "1xrqx72fymhrrixzpkl0mc451pfnjxjp08qwmnchp3as4kn40g0z";
  };
in
stdenvNoCC.mkDerivation {
  pname = "uwe5622-firmware";
  version = "unstable-2026-10-13";

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm644 ${wcnmodem} $out/lib/firmware/uwe5622/wcnmodem.bin
    install -Dm644 ${ini} $out/lib/firmware/uwe5622/wifi_2355b001_1ant.ini
    runHook postInstall
  '';

  meta = {
    description = "Firmware and RF calibration for the Unisoc UWE5622 (AW859A) combo";
    platforms = lib.platforms.linux;
  };
}
