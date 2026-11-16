{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      formatter = pkgs.nixfmt;

      packages.uwe5622-firmware = pkgs.callPackage ../packages/uwe5622-firmware { };
      packages.aic8800-firmware = pkgs.callPackage ../packages/aic8800-firmware { };
      packages.bench = pkgs.callPackage ../packages/bench { };
      packages.fd6xx = inputs.nixelec-common.packages.${pkgs.stdenv.hostPlatform.system}.fd6xx;
    };
}
