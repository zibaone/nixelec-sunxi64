{
  perSystem =
    { pkgs, ... }:
    {
      formatter = pkgs.nixfmt;

      packages.uwe5622-firmware = pkgs.callPackage ../packages/uwe5622-firmware { };
      packages.bench = pkgs.callPackage ../packages/bench { };
    };
}
