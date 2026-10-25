{
  lib,
  stdenv,
  fetchFromGitHub,
  kernel,
}:

# Out-of-tree WiFi/BT driver for the Unisoc UWE5622 (AW859A) combo found on
# the Orange Pi Zero 3 (SDIO, chipid 0x2355b001 = MARLIN3L_AB).
#
# Source: armbian/uwe5622, Allwinner branch (CONFIG_AW_WIFI_DEVICE_UWE5622).
# The tty-sdio Bluetooth module is not built: its Makefile does not include
# marlin_platform.h in out-of-tree builds, and it is not needed here.
stdenv.mkDerivation {
  pname = "uwe5622-${kernel.version}";
  version = "unstable-2026-10-13";

  src = fetchFromGitHub {
    owner = "armbian";
    repo = "uwe5622";
    rev = "fa9d1a6703a93a85bcf68e865ebc2726474076ad";
    sha256 = "1w440plnhdmwg202bknfjdhmr1nmxblhgy5v9837aalg98xzbfwi";
  };

  nativeBuildInputs = [ ];
  buildInputs = [ kernel.dev ];

  dontConfigure = true;
  enableParallelBuilding = true;

  buildPhase = ''
    runHook preBuild
    make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build M=$PWD \
      KERNELRELEASE=${kernel.modDirVersion} \
      ARCH=${stdenv.hostPlatform.linuxArch} \
      CONFIG_AW_WIFI_DEVICE_UWE5622=y \
      CONFIG_WLAN_UWE5622=m \
      UNISOC_FW_PATH_CONFIG=/etc/uwe5622/ \
      UNISOC_WIFI_CUS_CONFIG=/etc/uwe5622/ \
      modules
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -d $out/lib/modules/${kernel.modDirVersion}/extra
    cp unisocwcn/uwe5622_bsp_sdio.ko \
       unisocwifi/sprdwl_ng.ko \
       $out/lib/modules/${kernel.modDirVersion}/extra/
    runHook postInstall
  '';

  meta = {
    description = "Unisoc UWE5622 (AW859A) WiFi driver for ${kernel.version}";
    homepage = "https://github.com/armbian/uwe5622";
    license = lib.licenses.gpl2Only;
    platforms = [ "aarch64-linux" ];
  };
}
