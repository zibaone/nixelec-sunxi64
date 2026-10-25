# Backlog: nixelec-sunxi64

This document lists the public backlog for the reusable layer. Private fleet
work, consumer-specific add-ons and deployment policy are out of scope. Kernel,
DTB and platform work stays in nixbian; media packages stay in nix-v4l2-request.

## Priorities

`P1` blocks the deliverable or breaks a normal use, `P2` is a functional gap,
`P3` is deferred or a documented decision. Effort: `S` under a session, `M` a
session or two, `L` more.

| Priority | Items | Why |
|---|---|---|
| **P2/S** | 2 (upstream PR text), 24 (verify the real cache), 43 (governor) | cheap, removes a recurring doubt or a permanent warning |
| **P2/M** | 1 (`ntp-after-wifi`), 44 (`mmc -110` at boot) | functional gaps on a cold boot |
| **P3** | 3, 4, 10 (replay on the image + public audio doc), 12, 16, 17, 19, 21, 42 (`CONFIG_PSI`, costs a kernel), 45 (add-on icons), 46 (CEC kernel fix), public diagnostics | deferred, or knowledge rather than code |
| **closed** | 6, 9, 11, 23, 26, 30, 31, 33, 34, 37, 38, 39, 46 (layer workaround), D1 | done |

## In scope

| # | Item | Status in nixelec | Next action |
|---|---|---|---|
| 1 | Cold boot: wlan0 + NTP + Kodi without intervention | **partial**: driver, firmware, `wpa_supplicant`, `wlan-ps-off` and Kodi are present; the NTP resync is still consumer-side. On the reference board with `nixelec.wifi` (cold boot 2026-10-25) WiFi, NTP and Kodi come up. Not replayed on the nixelec image | port the generic `ntp-after-wifi` unit into this layer, then replay on the image |
| 2 | Upstream `armbian/uwe5622` PR | not started: the package consumes upstream unpatched | prepare the PR text and a local patch if upstream is slow |
| 3 | `sprdwl_del_iface` fix | not started; the `wpa_supplicant` workaround is documented | add a patch in nixelec or upstream it |
| 4 | `tty-sdio` (`marlin_platform.h` missing) | not built (Bluetooth unused) | attach to the upstream PR |
| 6 | `configurationLimit = 0` | done in `modules/family/sunxi64.nix` | none |
| 9 | `CONFIG_SUN50I_H6_PRCM_PPU=y` | **capacity available**: `builtin` mode writes `=y` through `hardware.nixbian.extraConfig`, and `checks.aarch64-linux.prcm-ppu-builtin-config` passes. Default stays `=m` to preserve cache parity | none — do not make `=y` the family default without a cache refill |
| 10 | HDMI audio | **validated on the reference board on 2026-10-24** with kernel `dsrz3rnrb` and this DTB: `audio-hub` 49.125 MHz, 0.055 % error (1 cent), 0 `ccu_helper_wait_for_lock` during playback, Kodi video at normal speed. The boot-time probe warning is benign. Not replayed on the nixelec image | replay on the nixelec image and publish the public audio doc |
| 11 | cedrus decode in Kodi GBM | **validated on the reference board (same kernel/DTB)**: Kodi logs `CDVDVideoCodecDRMPRIME` on a 1080p sample; a reliable CPU measurement on a real film remains | close the layer part; hardware can refine the CPU measurement |
| 12 | `kodi-wayland` | not exposed | add `nixelec.kodi.windowing = "gbm" \| "wayland"`; the package exists in nix-v4l2-request |
| 16 | `service.iptv.manager` | not packaged | package the add-on and its dependencies in a public consumer layer |
| 17 | `plugin.video.catchuptvandmore` | not packaged | package the add-on in a public consumer layer |
| 19 | Reference IPTV chain | not documented | document `pvr.iptvsimple` + a public IPTV source; keep private lists out |
| 21 | USB MCE remote | not enabled | optional `mceusb` module; board test |
| 23 | LIRC decision | decided: `ir-keytable`/rc-core, no LIRC | documented; no code |
| 24 | Cachix / `fix-sub.sh` | CI uses explicit `cachix push` plus narinfo checks; no `fix-sub.sh` | verify on the real cache; the `cache` job fills it on push |
| 26 | `nixos-rebuild switch` exits 4 | **fixed and unit-verified**: `restartIfChanged = false` in `modules/profiles/kodi-gbm.nix`, `kodi-restart-policy` green, and the generated unit carries `X-RestartIfChanged=false` with `Restart=always` | none in this layer; replay a switch on the image in CI |
| 30 | WiFi power save, card side | **done**: `wlan-ps-off` waits for the IPv4 address, toggles on then off, and runs as `Type=simple` so `multi-user.target` is not delayed | workstation-side `power_save off` is consumer policy |
| 31 | Kodi web server for Android remotes | **implemented** as `nixelec.kodi.webServer`: a `kodi-settings` oneshot before `kodi-gbm` sets `webserver`, `esallinterfaces`, Basic auth, port and password from `passwordFile`; the secret stays outside the store. Measured on the reference board (`0.0.0.0:8080`, 401 without auth, 200 with); not replayed with this image. Kodi ignores a password setting that still carries `default="true"`, so the unit deletes it | none in this layer; the consumer supplies the runtime secret |
| 33 | `marlin_exit` oops | **tested on 2026-10-24, not reproduced**: `modprobe -r` of both modules returns 0 and there is no oops. Reload is a separate failure: `sdiohal` stays registered and a cold boot is required | attach the unload trace to #2; do not claim runtime reload |
| 34 | Kodi UI sounds | **implemented** as `nixelec.kodi.uiSounds`: the `kodi-settings` oneshot sets `audiooutput.guisoundmode=0` and an empty `lookandfeel.soundskin`. Measured on the reference board; not replayed with this image | none in this layer |
| 37 | CMA size, board layer | **done**: `cma=256M` in `modules/boards/orangepizero3.nix`; measured `CmaTotal` 262144 kB, `CmaFree` 218796 kB at rest | none |
| 38 | `RequiredForOnline` costs two minutes of boot | **done**: `RequiredForOnline = "routable"` and `wait-online { anyInterface = true; timeout = 60; }`; measured success on the reference board | none |
| 39 | PipeWire realtime priority | **fixed and validated**: `LimitRTPRIO = 95` alone was not enough; `kernel.sched_rt_runtime_us = -1` lets rtkit grant RT. PipeWire's data-loop is `SCHED_RR/20` | none |
| 42 | `CONFIG_PSI` not enabled | `/proc/pressure/*` is absent on the board, so micro-stutter cannot be attributed | enable `CONFIG_PSI=y`; it costs a kernel rebuild and forks the cache, so batch it with another kernel change |
| 43 | CPU governor | the board runs `ondemand` (`cur` 1200 MHz, `max` 1416) | for a mains-powered appliance, `schedutil` or `performance` avoids late frequency ramps at scene start |
| 44 | `mmc0/mmc1: error -110` at boot | measured on the reference board: the first 400 kHz init times out, the core retries at 300 kHz and succeeds; the card is a 2010 3.79 GiB Samsung, and `vmmc` (`reg_dldo1`) is always-on, so a warm reset never power-cycles it. **Fixed for warm reset on 2026-10-25**: mainline U-Boot written to SPI at **offset 0** (not 8 KiB, the SD offset), readback verified, and 8/8 `systemctl reboot` returned via the SPI fallback with Kodi and WiFi up. The `-110` remains on the first Linux init; replacing the old SD is still the way to remove it. A cold boot was also validated on 2026-10-25. The CMD0 shutdown hook (`nixelec.orangepizero3.softResetOnShutdown`) was deployed and tested: the BootROM still fell back to SPI (`Trying to boot from sunxi SPI`), so the hook is disabled in the reference consumer and left for later debugging (kmsg logging, `/dev/mmcblk0` fallback, or a kernel patch) | replace the SD to remove the retry; debug the CMD0 hook separately if the SPI fallback must be avoided |
| 45 | Add-on icons written into the store | Kodi logs `Failed to sync addon icon: [Errno 30] Read-only file system: '/nix/store/…'` twice per start | ship add-ons into a writable directory, or pre-seed the texture cache in the kiosk module |
| 46 | CEC physical address after HDMI hotplug | **workaround implemented as `nixelec.kodi.cec`**: adapter defaults, boot reprobe and opt-in hotplug recovery. Cold boot and TV standby were validated on the reference board; the real udev trigger is not replayed on the image and the kernel fix is open | replay CEC on the image, including a real hotplug; keep the kernel fix (re-arm/re-read EDID) in nixbian |

## Public add-ons example

`examples/zero3-kodi-addons.nix` installs and enables four public nixpkgs
add-ons: `inputstream.adaptive`, `inputstream.ffmpegdirect`,
`inputstream.rtmp` and `pvr.iptvsimple`. The flake evaluates it in
`checks.x86_64-linux.eval-orangepizero3-addons`. Private add-ons and private
repositories stay out of this layer.

## Current cache coverage

The `cache` job (on `push` to `main` or manual dispatch) builds and pushes:

- the WiFi-enabled toplevel (`orangepizero3-kodi-cache`): kernel, U-Boot, Kodi,
  mesa, pipewire, systemd, UWE5622 driver and firmware;
- the `uwe5622` package;
- `kernel.dev`, which is a build input and not part of the system closure.

The image artifact is built by the manual `image` job. Consumer-private layers
are not built here.

## Reproducibility

A fresh clone evaluates from the public inputs alone:

```bash
nix eval --raw .#nixosConfigurations.orangepizero3-kodi.config.system.build.toplevel.drvPath
```

Keep the property: a `path:` input or a private URL breaks it silently, and the
first symptom is a stranger's clone that does not evaluate.

## Maintenance

Update this file with public items only. No secrets, hostnames, private
repository names, private add-on IDs or consumer-specific deployment details.
Hardware measurements must be marked as measured or not measured.
