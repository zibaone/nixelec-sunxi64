{
  lib,
  stdenv,
}:

stdenv.mkDerivation {
  pname = "fd6xx";
  version = "0.1.0";

  src = ./.;

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -o fd6xx fd6xx.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 fd6xx $out/bin/fd6xx
    runHook postInstall
  '';

  meta = {
    description = "Bit-bang userspace driver for H616/H618 front-panel 7-segment displays (FD650/FD655)";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
