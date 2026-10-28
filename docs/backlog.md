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
| **P1/M** | 49 (safe CEC module reload) | the current last-resort rung can require a cold boot on a headless board |
| **P2/S** | 2 (upstream PR text), 24 (verify the real cache) | cheap, removes a recurring doubt or a permanent warning |
| **P2/M** | 1 (`ntp-after-wifi`) | functional gap on a cold boot |
| **P3** | 3, 4, 10 (replay on the image + public audio doc), 12, 16, 17, 19, 21, 42 (`CONFIG_PSI`, costs a kernel), 44 (`mmc -110` / CMD0, optional), 45 (add-on icons), 46 (CEC kernel fix), 47 (WirePlumber abort: retest on 26.11, nothing to port), public diagnostics | deferred, or knowledge rather than code |
| **closed** | 6, 9, 11, 23, 26, 30, 31, 33, 34, 37, 38, 39, 43 (governor), 46 (layer workaround), 48 (watchdog), 50 (kiosk console), D1 | done |

## In scope

| # | Item | Status in nixelec | Next action |
|---|---|---|---|
| 1 | Cold boot: wlan0 + NTP + Kodi without intervention | **partial**: driver, firmware, `wpa_supplicant`, `wlan-ps-off` and Kodi are present; the NTP resync is still consumer-side. On the reference board with `nixelec.wifi` (cold boot 2026-10-25) WiFi, NTP and Kodi come up. Not replayed on the nixelec image | port the generic `ntp-after-wifi` unit into this layer, then replay on the image |
| 2 | Upstream `armbian/uwe5622` PR | not started: the package consumes upstream unpatched | prepare the PR text and a local patch if upstream is slow |
| 3 | `sprdwl_del_iface` fix | not started; the `wpa_supplicant` workaround is documented | add a patch in nixelec or upstream it |
| 4 | `tty-sdio` (`marlin_platform.h` missing) | not built (Bluetooth unused) | attach to the upstream PR |
| 6 | `configurationLimit = 0` | done in `modules/family/sunxi64.nix` | none |
| 9 | `CONFIG_SUN50I_H6_PRCM_PPU=y` | **capacity available**: `builtin` mode writes `=y` through `hardware.nixbian.extraConfig`, and `checks.aarch64-linux.prcm-ppu-builtin-config` passes. Default stays `=m` to preserve cache parity. **Done 2026-10-26**: `=y` is now carried by the family kernel (`family_config.json`, nixbian `v0.5.0`), `builtin` is the default mode, kernel `iwx0zdgr…`, one cache refill (run `40381164667`) | none |
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
| 42 | `CONFIG_PSI` not enabled | `/proc/pressure/*` is absent on the board, so micro-stutter cannot be attributed. **Done 2026-10-26**: `CONFIG_PSI=y` in the family kernel (`family_config.json`); `/proc/pressure/{cpu,io,memory}` present on the deployed board | none |
| 43 | CPU governor | **done 2026-10-27** (`3284b83`): `nixelec.kodi.cpuGovernor` (default `schedutil`) writes the governor through a guarded oneshot. `powerManagement.cpuFreqGovernor` is not used: it also loads `cpufreq_schedutil` as a module, and that governor is built into the sunxi64 kernel (`modprobe` returns 1), which would leave `systemd-modules-load` failed. Measured on the reference board: `policy0` = `schedutil`, `cpu-governor` active, 0 failed units | none |
| 44 | `mmc0/mmc1: error -110` at boot | measured on the reference board: the first 400 kHz init times out, the core retries at 300 kHz and succeeds; the card is a 2010 3.79 GiB Samsung, and `vmmc` (`reg_dldo1`) is always-on, so a warm reset never power-cycles it. **Warm reset fixed on 2026-10-25**: mainline U-Boot written to SPI at **offset 0** (not 8 KiB, the SD offset), readback verified, 8/8 `systemctl reboot` and a cold boot returned via the SPI fallback with Kodi and WiFi up. **Downgraded to P3**: the `-110` remains on the first Linux init but the retry succeeds, with no observed impact. The CMD0 shutdown hook (`nixelec.orangepizero3.softResetOnShutdown`) was deployed and tested: the BootROM still fell back to SPI (`Trying to boot from sunxi SPI`), so the hook is disabled and optional (kmsg logging, `/dev/mmcblk0` fallback, or a kernel patch) | optional: replace the SD to remove the retry; debug the CMD0 hook only if the SPI fallback must be avoided |
| 45 | Add-on icons written into the store | Kodi logs `Failed to sync addon icon: [Errno 30] Read-only file system: '/nix/store/…'` twice per start | ship add-ons into a writable directory, or pre-seed the texture cache in the kiosk module |
| 46 | CEC physical address after HDMI hotplug | **workaround implemented as `nixelec.kodi.cec`**: adapter defaults, boot reprobe and opt-in hotplug recovery. Cold boot and TV standby were validated on the reference board; the real udev trigger is not replayed on the image and the kernel fix is open. **2026-10-28, measured on the reference board**: the recovery rung that claimed the lost address with `cec-ctl --playback` restored the mask but left libCEC without an address — `cec-ctl -S` showed a valid PA, LA 4 and the TV, the service reported success, and the TV remote stayed dead until Kodi was restarted (libCEC never retries). That rung is removed: the retry is now a Kodi restart, and every verification reads the adapter's vendor ID (`0x001582` = libCEC, `0x000c03` = cec-ctl) together with the mask | replay CEC on the image, including a real hotplug; keep the kernel fix (re-arm/re-read EDID) in nixbian |
| 47 | WirePlumber aborts when restarted with an active stream | **observed on the reference board on 2026-10-26**: `nixos-rebuild switch` restarted the user `wireplumber.service` while Kodi held the HDMI PCM (single-stream `i2s-hifi`); the daemon died on `GLib-GObject:ERROR:../gobject/gsignal.c:4110: invalid_closure_notify: assertion failed: (handler != NULL)` → `status=6/ABRT`, twice, then the graph stopped answering (`wpctl status` hangs, `wpctl get-volume` empty) while every unit still read `active` — playback kept running silently. Recovery: stop Kodi, restart `pipewire`/`pipewire-pulse`/`wireplumber`, start Kodi | **upstream signature, and the patch is already in our build**: this is Ubuntu LP #2127049, the highest-volume wireplumber crash on errors.ubuntu.com. The fix Canonical shipped (`g_signal_handlers_disconnect_by_data` in `modules/module-portal-permissionstore.c`, `0.5.10-3ubuntu1`) landed upstream in **0.5.12** — verified in the tags, absent in 0.5.10/0.5.11 and present from 0.5.12 — so 0.5.14 already has it and porting anything would be a no-op. Arch reports the same assertion as a **0.5.13 regression** (0.5.12 is fine), i.e. a second lifecycle race, with no distro patch available. Decision: carry nothing on 0.5.14; nixos-unstable already ships **0.5.18** (`patches = []`), which 26.11 will bring. Retest a switch during playback after the upgrade (weeks away — no action before); if it still aborts, comment on the upstream issue with this trace and the single-stream ASoC context |
| 48 | Hardware watchdog | **done 2026-10-27** (`3284b83`): `nixelec.kodi.watchdog` sets `RuntimeWatchdogSec`/`RebootWatchdogSec`, 15 s each — the sunxi-wdt `max_timeout` is 16 s (measured), so the 30 s suggested earlier would only have been capped with a warning. Measured on the reference board after activation: `state=active`, `timeleft=15`, 0 failed units, Kodi still running | consumers opt in (`nixelec.kodi.watchdog.enable`); the private layer enables it on the ARM kiosk only, no proven watchdog on x86 |
| 49 | CEC last-resort reload against an open client | **hazard found 2026-10-28 while fixing 46**: the module-reload rung runs `modprobe -r dw_hdmi_cec` while Kodi still holds `/dev/cec0`; `cec_devnode_release` then runs on unloaded text (`Fixing recursive fault but reboot is needed`), i.e. the rung meant to save a headless board can require a power cycle. Related, measured the same day: `systemctl stop kodi-gbm` with a gap longer than ~10 s makes logind close the kiosk session, which restarts the user audio stack *behind* Kodi and leaves it without an HDMI sink — `ActiveAE::InitSink - failed to init` every 5 s for 7 h (23:44 → 06:47), `wpctl status` hanging; a stop/start inside the same second does not do this | stop the kiosk, wait until `pgrep -u kodi -x kodi.bin` is empty (`pkill -9` as a fallback), then rmmod/modprobe, then start; then assert a default sink exists (`wpctl inspect @DEFAULT_AUDIO_SINK@`) and restart `pipewire`/`pipewire-pulse`/`wireplumber` with the kiosk stopped if it does not. Needs a supervised hotplug replay on the board |
| 50 | Kiosk console painted the TV during restarts | **done 2026-10-28**: `kodi-gbm` moved from `StandardOutput`/`StandardError = "journal+console"` to `journal`, and the kiosk profile sets `boot.consoleLogLevel = lib.mkOverride 50 3` (the family keeps `mkDefault 7` for UART bring-up). Observed: a screenful of kernel debug lines in the ~40 s between a restart and Kodi taking DRM master | none |

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
