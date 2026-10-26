# Cache alignment

A consumer can reuse this layer's store paths instead of rebuilding the kernel,
U-Boot, Kodi, mesa, pipewire and the rest of the system closure. Store paths are
content-addressed, so three things must match:

1. the nixpkgs revision;
2. the nixbian and v4l2-request revisions;
3. the cache, and the push must include the toplevel closure, not only the image
   file.

## Current pins

No revision is frozen here: the revs move every day and a copied hash is wrong
the next morning. The contract is the derivation, not the rev — check the
`drvPath` (below) instead of matching commit SHAs. As of 2026-10-26 the kernel
is `iwx0zdgrc4gjh86j46f7mfaf2fj9j0yj-linux-7.0.14.drv`, identical in HavenOS
and nixelec.

Read the pins from the lock when you need them:

```bash
jq -r '.nodes.nixpkgs.locked.rev, .nodes.nixbian.locked.rev' flake.lock
```

## Consuming the flake

Keep the `follows` clauses when the consumer already pins the same inputs:

```nix
inputs.nixelec-sunxi64 = {
  url = "github:zibaone/nixelec-sunxi64";
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.nixbian.follows = "nixbian";
  inputs.v4l2request.follows = "v4l2request";
};
```

Without the `follows` clauses, Nix fetches nixelec's own pins and the store paths
diverge.

## Filling a consumer cache

Use the `cache` job on `push` to `main`, or run it manually. Set the repository
variables to the consumer cache:

1. `CACHIX_CACHE`: cache name.
2. `CACHIX_AUTH_TOKEN` and `CACHIX_SIGNING_KEY`: cache credentials.

```bash
gh workflow run ci.yml
```

If the consumer uses a different nixpkgs revision, pass it explicitly:

```bash
NIXPKGS_REV=$(jq -r '.nodes.root.inputs.nixpkgs as $n | .nodes[$n].locked.rev' \
  /path/to/consumer/flake.lock)
gh workflow run ci.yml -f nixpkgs-rev="$NIXPKGS_REV"
```

The job builds the WiFi-enabled toplevel, `uwe5622` and `kernel.dev`, optionally
with `--override-input nixpkgs github:NixOS/nixpkgs/$NIXPKGS_REV`, pushes them,
and checks their narinfos.

The manual image job is only for the artifact:

```bash
gh workflow run ci.yml -f build-image=true
```

If no consumer cache is configured, the job defaults to `nixelec`. To use a
separate cache from a consumer, add it explicitly:

```nix
nixConfig = {
  extra-substituters = [ "https://nixelec.cachix.org" ];
  extra-trusted-public-keys = [ "nixelec.cachix.org-1:..." ];
};
```

## What the cache job covers

The `cache` job builds `orangepizero3-kodi-cache`, which has
`nixelec.wifi.enable = true` (driver and firmware installed, no SSID/PSK). It
pushes:

- the full system toplevel closure: nixbian kernel, modules, U-Boot, Kodi,
  FFmpeg v4l2-request, mesa, pipewire, systemd;
- the `uwe5622` driver package;
- `kernel.dev`, a build input of the driver and therefore not part of the
  system closure.

The `image` job builds the image artifact separately. It pushes the default
toplevel and the image; the cache job has already filled the shared closure.

Consumer-private additions are not covered: private add-ons, provisioning,
identity, extra runtimes and host-specific options. The consumer builds those,
but the heavy shared base should come from the cache.

## Verifying alignment

In the consumer, compare the shared derivations:

```bash
nix eval --raw .#nixosConfigurations.<host>.config.boot.kernelPackages.kernel.drvPath
nix eval --raw .#nixosConfigurations.<host>.config.hardware.nixbian.uBoot.package.outPath
nix eval --impure --raw --expr \
  '(builtins.getFlake "/path/to/nixelec-sunxi64").inputs.v4l2request.packages.aarch64-linux.kodi-kiosk.drvPath'
```

They must match the values in the main README. A dry-run of the consumer
toplevel should then report few paths to build:

```bash
nix build --dry-run --no-link .#nixosConfigurations.<host>.config.system.build.toplevel
```

## Limitations

- The `cache` job runs on `push` to `main` and manual dispatch; the image
  artifact remains manual.
- The example configuration is not the consumer's private profile. The shared
  base aligns; the final toplevel does not, and is not expected to.
- `nixpkgs-rev` must be updated whenever the consumer bumps nixpkgs, and the
  nixbian pin must be bumped here as well.
