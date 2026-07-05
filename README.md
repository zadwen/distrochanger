# gameify

Point this at pretty much any Linux distro and it profiles your system, then
installs, configures, and keeps updated everything needed to turn it into a
gaming-ready desktop — the philosophy behind Nobara and Bazzite, but as a
script you run on the distro you already have, instead of a whole new ISO.

## What's actually "smart" about it

- **Real system profiling** — reads CPU model/vendor/cores, detects every
  GPU via `lspci` (including hybrid Optimus/PRIME laptops with two GPUs),
  checks disk type (NVMe/SSD/HDD), Secure Boot state, kernel version, and
  session type (X11/Wayland) before touching anything.
- **Package-manager-agnostic** — one abstraction layer over `apt`, `dnf`,
  `pacman`, `zypper`, so the same script adapts to Debian/Ubuntu,
  Fedora/Nobara, Arch/Manjaro, and openSUSE.
- **Graceful fallback, not hard failure** — if a native package isn't
  available (common on openSUSE/Fedora for niche gaming tools), it falls
  back to Flatpak automatically instead of just erroring out.
- **Idempotent** — every install/tweak function checks current state first.
  Re-running `gameify.sh` or `update.sh` costs you a few seconds of checks,
  not a re-install of everything.
- **Real auto-updating Proton-GE** — pulls the latest release directly from
  the [GloriousEggroll/proton-ge-custom](https://github.com/GloriousEggroll/proton-ge-custom)
  GitHub API and installs it into Steam's compatibility tools folder. No GUI
  step required, and `update.sh` re-checks it weekly.
- **Reports before and after** — prints a full system report before making
  any changes, and a plain-language summary of exactly what it did (or
  didn't need to do) at the end of every run.

## Supported distros

| Family | Examples | Support level |
|---|---|---|
| Debian/Ubuntu | Ubuntu, Zorin, Mint, Pop!_OS, Debian | Full, including XanMod/Liquorix kernels |
| Fedora | Fedora, Nobara, Rocky, Alma | Full |
| Arch | Arch, Manjaro, EndeavourOS | Full, including linux-zen kernel |
| openSUSE | Leap, Tumbleweed | Best-effort — NVIDIA/Steam need extra community repos that vary by version; the script tries, then points to the official guide if it can't finish automatically |

## Usage

```bash
git clone https://github.com/zadwen/distrochanger.git
cd distrochanger
chmod +x *.sh
./gameify.sh
```

Run as a normal user — it calls `sudo` itself only for the specific commands
that need it, and tells you before each one.

## What it installs / does

**Drivers** (`drivers.sh`)
- NVIDIA / AMD / Intel, matched to what was actually detected
- Hybrid-GPU laptops get PRIME/Optimus tooling where packaged, plus the
  manual per-game GPU-offload launch options either way (these work on
  every distro, with or without extra tooling)

**Performance kernel** (`kernel.sh`, opt-in, skipped by default)
- XanMod or Liquorix on Debian/Ubuntu (auto-detects your CPU's x86-64
  instruction level for XanMod's tuned builds)
- linux-zen on Arch (official repo package, no AUR helper required)

**Gaming stack** (`gaming-stack.sh`)
- Steam, Wine, GameMode, Lutris, MangoHud, ProtonUp-Qt, Heroic (optional)
- GE-Proton — installed and kept current automatically from GitHub releases
- Gamescope (SteamOS-style compositor, useful for handheld/couch setups)
- vkBasalt (Vulkan post-processing: sharpening, color correction)

**Tweaks & auto-fixes** (`tweaks.sh`)
- Checks for a working Vulkan ICD and installs what's missing
- Raised `vm.max_map_count` for certain Proton/UE titles
- Adds your user to the `gamemode` group
- Scans known Wine/Proton prefix locations for corruption (missing
  `drive_c` or `system.reg`) and offers to repair with `wineboot -u`

**Weekly maintenance** (`update.sh`)
- Refreshes Flatpak apps and GE-Proton with no password needed
- When run interactively, also upgrades system packages and re-checks
  drivers
- See **Setting up automatic updates** below for the sudo/cron nuance —
  it's a real limitation, not a bug, and worth reading before you wire up
  a cron job.

## Setting up automatic updates

`update.sh` auto-detects whether it has a real terminal:

- **Run by hand** (`./update.sh` in a terminal): does everything, including
  the parts that need `sudo` (system package upgrades, driver refresh).
- **Run non-interactively** (cron, no TTY): only does what doesn't need a
  password — Flatpak updates and the GE-Proton refresh — and logs a
  reminder for what it skipped.

This is deliberate: a bare cron job has nowhere to type a `sudo` password,
so silently trying anyway would just hang or fail. Two ways to get the full
unattended behavior if you want it:

1. **Recommended: a `systemd --user` timer.** It runs inside your logged-in
   session, where a polkit agent can prompt/authenticate normally.
   ```bash
   # ~/.config/systemd/user/gameify-update.service
   [Unit]
   Description=gameify weekly update

   [Service]
   ExecStart=/path/to/distrochanger/update.sh

   # ~/.config/systemd/user/gameify-update.timer
   [Timer]
   OnCalendar=weekly
   Persistent=true

   [Install]
   WantedBy=timers.target
   ```
   Then: `systemctl --user enable --now gameify-update.timer`

2. **Convenience option: a scoped `NOPASSWD` sudoers rule.** Only if you
   understand the tradeoff — this lets `update.sh` upgrade packages without
   a password prompt, but weakens your system's normal sudo protections for
   those specific commands. Never use a blanket `NOPASSWD ALL` rule. If you
   go this route, scope it to exactly the package-manager commands this
   script calls (`visudo`, then add a line limited to `apt`/`dnf`/`pacman`/
   `zypper` for your user), and accept that's a deliberate security
   tradeoff you're making for convenience.

A plain crontab entry (does the non-sudo parts only, safely):
```
0 4 * * 0 /path/to/distrochanger/update.sh >> ~/.local/share/gameify/update.log 2>&1
```

## Project layout

```
gameify.sh          entry point — report, menus, orchestration, final summary
update.sh           weekly maintenance (Flatpak/GE-Proton always, sudo steps if interactive)
detect.sh           distro/CPU/GPU/RAM/disk/Secure-Boot/session detection + report
pkgmanager.sh       apt/dnf/pacman/zypper abstraction, Flatpak helpers, change-log
drivers.sh          per-distro, per-vendor driver install + hybrid-GPU/PRIME handling
kernel.sh           optional XanMod/Liquorix/linux-zen performance kernel install
gaming-stack.sh     Steam/Wine/GameMode/Lutris/MangoHud/ProtonUp-Qt/GE-Proton/Gamescope/vkBasalt/Heroic
tweaks.sh           Vulkan check, vm.max_map_count, gamemode group, Wine prefix repair
```

Every install/tweak function that changes something calls `log_change`
(defined in `pkgmanager.sh`), which both prints the action immediately and
appends it to a shared `CHANGELOG` array — that's what powers the end-of-run
summary and `update.sh`'s log file.

## Disclaimer

This installs real drivers, kernels, and packages, and on Fedora/openSUSE
may add third-party repos (RPM Fusion / NVIDIA community repo) required for
NVIDIA and Steam. Everything it runs is plain `apt`/`dnf`/`pacman`/`zypper`/
`flatpak`/`curl` — read the `.sh` files before running if you want to see
exactly what it does. Safe to re-run at any time. Swapping kernels (XanMod/
Liquorix/zen) carries slightly more risk than installing an app — that step
is opt-in and off by default for a reason.

See `ROADMAP.md` for where this is headed next.

## License

MIT — see `LICENSE`.
