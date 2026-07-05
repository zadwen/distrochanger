# gameify

Point this at pretty much any Linux distro and it profiles your system, then
installs, configures, and keeps updated everything needed to turn it into a
gaming-ready desktop — the philosophy behind Nobara and Bazzite, but as a
script you run on the distro you already have, instead of a whole new ISO.

## Tiers: Standard / Advanced / Experimental

Every install and tweak falls into one of three risk tiers, so you decide how
far gameify reaches into your system instead of it deciding for you:

| Tier | What's in it | Default |
|---|---|---|
| **Standard** | Native GPU drivers, Steam/Wine/GameMode/Lutris/MangoHud/ProtonUp-Qt, Vulkan/`vm.max_map_count`/gamemode-group fixes, Wine-prefix repair, auto-heal log scan, Discord/OBS/Spotify | Always on |
| **Advanced** | PRIME/Optimus auto-config + default-GPU diagnostic, GE-Proton auto-install/update, Gamescope, vkBasalt, per-game Proton override | Asked once, saved |
| **Experimental** | Performance kernels (XanMod/Liquorix/linux-zen), Battle.net/EA App via Lutris | Off unless you opt in |

Pick tiers the first time you run `gameify.sh`, or any time with:
```bash
./gameify.sh --tiers
```
Your choice is saved to `~/.config/gameify/tiers.conf` and reused by both
`gameify.sh` and `update.sh` — no re-asking on every run. Everything in
every tier is reversible: old kernels stay in the bootloader menu, Lutris
installs are just removable prefixes, and package installs go through your
normal package manager (nothing atomic or hard to undo).

## What's actually "smart" about it

- **Real system profiling** — reads CPU model/vendor/cores, detects every
  GPU via `lspci` (including hybrid Optimus/PRIME laptops with two GPUs),
  checks disk type (NVMe/SSD/HDD), monitor refresh rate (`xrandr`/
  `wlr-randr`/DRM fallback), Secure Boot state, kernel version, and session
  type (X11/Wayland) before touching anything.
- **Hybrid-GPU aware, not just hybrid-GPU-tolerant** — actively checks
  which GPU is rendering by default on Optimus/PRIME laptops (`glxinfo`),
  flags when a game would silently land on the weak Intel iGPU, and
  installs a `prime-run` wrapper so forcing the discrete GPU is one word
  instead of a paragraph of env vars.
- **Bug auto-healing** — scans `journalctl` and Steam's own logs for a set
  of known recurring Linux-gaming error signatures (missing Vulkan ICD,
  `vm.max_map_count` too low, GameMode unavailable, corrupted Wine
  prefixes, corrupted shader cache, missing 32-bit libs) and applies the
  safe fix automatically. GPU-reset/Xid errors are reported with next
  steps rather than guessed at, since those usually need a human to look
  at hardware/power settings.
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
git clone https://github.com/zadwen/gameify.git
cd gameify
chmod +x *.sh
./gameify.sh
```

Run as a normal user — it calls `sudo` itself only for the specific commands
that need it, and tells you before each one.

## What it installs / does

**Drivers** (`drivers.sh`)
- `[Standard]` NVIDIA / AMD / Intel, matched to what was actually detected,
  with Flatpak/community-repo fallback if a native package fails
- `[Advanced]` Hybrid-GPU laptops get PRIME/Optimus auto-config plus a
  "Fix wrong default GPU" diagnostic that checks the active renderer and
  either explains why (and how to force the discrete GPU per-game) or
  confirms it's already correct
- `[Advanced]` Installs a `~/.local/bin/prime-run` wrapper (`prime-run
  %command%` in a Steam launch option, or `prime-run some-app` from a
  terminal) — the manual launch-option tip itself is always shown regardless
  of tier, since it's just information

**Performance kernel** (`kernel.sh`, `[Experimental]`, off by default)
- XanMod or Liquorix on Debian/Ubuntu (auto-detects your CPU's x86-64
  instruction level for XanMod's tuned builds)
- linux-zen on Arch (official repo package, no AUR helper required)
- Checks Secure Boot state first and warns clearly that these unsigned,
  community-built kernels will likely fail to boot with Secure Boot on,
  with the two real ways to resolve that (disable it, or sign + enroll a
  MOK key) before asking whether to continue anyway

**Gaming stack** (`gaming-stack.sh`)
- `[Standard]` Steam, Wine, GameMode, Lutris, MangoHud, ProtonUp-Qt, Heroic
  (optional)
- `[Advanced]` GE-Proton — installed and kept current automatically from
  GitHub releases
- `[Advanced]` Gamescope (SteamOS-style compositor, useful for
  handheld/couch setups)
- `[Advanced]` vkBasalt (Vulkan post-processing: sharpening, color
  correction)
- `[Advanced]` Per-game Proton override — writes a `CompatToolMapping` entry
  straight into Steam's `config.vdf` for a given AppID (with an automatic
  backup), so you don't have to click through Properties > Compatibility

**Everyday apps** (`apps.sh`, all optional)
- `[Standard]` Discord, OBS Studio, Spotify — via Flatpak, auto-updating
- `[Experimental]` Battle.net / EA App — neither has a native Linux build or
  a Flatpak, so gameify hands off to Lutris's own maintained install scripts
  (`lutris:install/battlenet`, `lutris:install/ea-app`) instead of trying
  to reimplement installer logic that changes with every client update

**Tweaks & auto-fixes** (`tweaks.sh`, `[Standard]`)
- Checks for a working Vulkan ICD and installs what's missing
- Raises `vm.max_map_count` for certain Proton/UE titles
- Adds your user to the `gamemode` group
- Scans known Wine/Proton prefix locations for corruption (missing
  `drive_c` or `system.reg`) and offers to repair with `wineboot -u`

**Bug auto-healing** (`heal.sh`, `[Standard]`)
- Scans the last 1-2 days of `journalctl` (system + user) and Steam's log
  directory for known error signatures and either fixes them automatically
  (reusing the exact functions above) or reports them with a concrete next
  step. Runs at the end of `gameify.sh` and at the start of every
  `update.sh` run.

**Weekly maintenance** (`update.sh`)
- `[Standard]` Refreshes Flatpak apps and runs the auto-heal log scan —
  neither needs a password
- `[Advanced]` Refreshes GE-Proton, if the Advanced tier is enabled
- When run interactively, also upgrades system packages and re-checks
  drivers
- `./update.sh --install-cron` adds a weekly crontab entry for you (Sundays
  04:00); `./update.sh --remove-cron` takes it back out
- See **Setting up automatic updates** below for the sudo/cron nuance —
  it's a real limitation, not a bug, and worth reading before you wire up
  a cron job.

## Per-game Proton override

The gaming-stack menu offers this at the end of install, or run it directly:

```bash
source detect.sh pkgmanager.sh drivers.sh gaming-stack.sh   # or just run gameify.sh once
set_proton_for_game 730 GE-Proton9-20   # AppID, then the exact Proton build name
```

Close Steam first — it rewrites `config.vdf` on exit and would overwrite the
change otherwise. A backup (`config.vdf.gameify.bak`) is made automatically.

## Fixing "my game is using the wrong GPU"

On hybrid-GPU (Optimus/PRIME) laptops:

```bash
prime-run %command%          # as a Steam launch option
prime-run some-native-app    # from a terminal
```

`drivers.sh`'s "Fix wrong default GPU" menu option checks which GPU is
actually rendering by default and explains the fix that applies to your
situation — the wrapper above, an NVIDIA power-management profile change,
or an in-game GPU-selection setting some titles use instead of env vars.

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
   ExecStart=/path/to/gameify/update.sh

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

Easiest option — let gameify manage its own crontab entry (does only the
non-sudo parts on schedule, safely):
```bash
./update.sh --install-cron   # adds a weekly Sunday 04:00 entry
./update.sh --remove-cron    # takes it back out
```
This is equivalent to hand-adding:
```
0 4 * * 0 /path/to/gameify/update.sh >> ~/.local/share/gameify/cron.log 2>&1
```

## Project layout

```
gameify.sh          entry point — report, menus, orchestration, final summary
update.sh           weekly maintenance + cron install/remove (--install-cron/--remove-cron)
detect.sh           distro/CPU/GPU/RAM/disk/refresh-rate/Secure-Boot/session detection + report
pkgmanager.sh       apt/dnf/pacman/zypper abstraction, Flatpak helpers, change-log, tier framework
drivers.sh          per-distro, per-vendor driver install + hybrid-GPU/PRIME + default-GPU fix
kernel.sh           optional XanMod/Liquorix/linux-zen performance kernel install + Secure Boot check
gaming-stack.sh     Steam/Wine/GameMode/Lutris/MangoHud/ProtonUp-Qt/GE-Proton/Gamescope/vkBasalt/Heroic
                     + per-game Proton override (config.vdf)
apps.sh             optional everyday apps: Discord/OBS/Spotify (Flatpak), Battle.net/EA App (Lutris)
tweaks.sh           Vulkan check, vm.max_map_count, gamemode group, Wine prefix repair
heal.sh             journalctl + Steam log scanning, known-error auto-fixes
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
