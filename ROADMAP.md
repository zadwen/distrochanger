# Roadmap

An honest look at the gap between "a script that configures your existing
distro" (what `gameify` is today) and "a gaming distro" (what Nobara and
Bazzite are), and the real steps to close it.

## Recently completed

The system-analyzer/auto-healing pass added:

- [x] Full hardware/session profiling: CPU, GPU(s), RAM, disk type
      (NVMe/SSD/HDD), monitor refresh rate, Secure Boot state, kernel
      version, session type (X11/Wayland) — `detect.sh`
- [x] Hybrid-GPU (Optimus/PRIME) default-renderer diagnosis + `prime-run`
      wrapper, on top of the existing PRIME tooling install — `drivers.sh`
- [x] Secure Boot pre-checks before offering XanMod/Liquorix/linux-zen,
      since unsigned community kernels commonly fail to boot with it on —
      `kernel.sh`
- [x] Per-game Proton override via direct, backed-up `config.vdf` edits,
      on top of GE-Proton/Gamescope/vkBasalt already being installed and
      auto-updated — `gaming-stack.sh`
- [x] Bug auto-healing: `journalctl` + Steam log scanning for known error
      signatures (Vulkan ICD, `vm.max_map_count`, GameMode, broken Wine
      prefixes, shader cache corruption, missing 32-bit libs), with safe
      fixes applied automatically — `heal.sh`
- [x] Everyday app installs: Discord/OBS/Spotify via Flatpak, Battle.net/EA
      App handed off to Lutris's maintained install scripts — `apps.sh`
- [x] Self-managed weekly cron job (`update.sh --install-cron`/
      `--remove-cron`), running the auto-heal scan on every cycle
- [x] **Standard / Advanced / Experimental tiers** — every install and
      tweak is now labeled by risk level, Standard runs by default, and
      Advanced/Experimental are opt-in choices saved to
      `~/.config/gameify/tiers.conf` (`./gameify.sh --tiers` to change) —
      `pkgmanager.sh` (framework) + every module (labeling/gating)

## Where gameify stands today

A convenience layer on top of your existing distro: detect hardware,
install drivers/gaming stack/tweaks, keep Proton and Flatpaks current. This
is genuinely useful and has an advantage Nobara/Bazzite don't — it works on
whatever distro you already have, no reinstall required. But it isn't a
distro. It doesn't control the base image, so it inherits whatever's
already broken or outdated on the system it's run on, and every update
model of the underlying distro is still in play underneath it.

## Why Nobara/Bazzite are structurally different

- **Nobara** is a full Fedora respin: its own kernel build, its own repo
  mirrors, media codecs and gaming packages baked into the ISO itself. You
  install it once and it's already done.
- **Bazzite** goes further — it's image-based (`rpm-ostree`/OCI), meaning
  the entire OS is an atomically-updated, versioned image. Updates are
  rollback-able as a unit, and it ships a gamescope session for
  handheld/console-mode out of the box, plus its own controller/TDP daemon
  (HHD) for Deck-likes.

Neither of those is something a shell script running on top of an arbitrary
existing install can fully replicate — they're a different distribution
model, not just a different package list.

## Realistic near-term improvements (script stays a script)

- [ ] `--dry-run` flag across every module — print every command instead of
      running it, so people can audit before trusting it with sudo.
- [ ] Expand `~/.config/gameify/` beyond tiers to remember per-run choices
      too (which driver, whether to install Heroic, kernel choice) so
      re-runs and `update.sh` don't have to re-ask about those either — the
      tier config added this cycle is the first piece of this, not the
      whole thing.
- [ ] Per-run JSON log (not just human-readable) so results are scriptable —
      useful for the community driver-testing idea below.
- [ ] Expand openSUSE support to be first-class instead of best-effort —
      needs real testing on Leap and Tumbleweed, not just theory.
- [ ] Gamescope **session** integration (a proper desktop-session entry, not
      just the binary) for people who want a console-like boot-to-Steam mode
      without leaving their existing desktop environment installed.
- [ ] A minimal TUI (using something like `gum` or `dialog`) instead of
      plain `select` menus — much friendlier on first run.
- [ ] **GNOME gaming extensions** — auto-install/configure
      `gamemode`-aware indicator extensions (e.g. a MangoHud/GameMode status
      toggle in the top bar) and a "Game Mode" GNOME profile that disables
      animations/idle-suspend while a game is running, mirroring what
      Bazzite's desktop layer does out of the box. Needs a KDE equivalent
      too (Plasma has more native support for this already via KWin rules).
- [ ] **OBS scene/profile presets** — ship ready-made OBS profiles for
      common gameplay-recording setups (webcam+game capture, "just
      gameplay", clip-highlights) instead of leaving a blank OBS install,
      pre-wired to PipeWire capture on Wayland.
- [ ] **Anti-cheat compatibility reporting** — surface Are We Anti-Cheat
      Yet–style data (respecting its terms of use/attribution) in the
      system report and per-game Proton menu, so people find out a title
      won't work under Proton *before* spending an hour troubleshooting it,
      not after.
- [ ] Expand `heal.sh`'s known-error signature set over time (this is the
      kind of thing that benefits most from real bug reports — see
      **Contributing** below) and add an opt-in "send anonymized signature
      counts" telemetry mode, off by default, purely to prioritize which
      signatures are worth adding next.

## GUI evolution — learning from Windows tweak-utility tools

Tools like Chris Titus Tech's WinUtil proved a useful shape for this kind of
project: start as a script, categorize everything by risk (safe tweaks vs.
performance vs. experimental), add repair/troubleshooting tools alongside
the tweaks, then grow update management, and only *then* layer a GUI on top
once the underlying logic is solid. `gameify` is deliberately following that
same order rather than jumping straight to a GUI:

1. **Script + tiers (done this cycle)** — Standard/Advanced/Experimental
   categorization across every module, so the risk model exists before any
   UI has to represent it.
2. **Repair tools (done this cycle)** — `heal.sh`'s log-scanning auto-fixes
   are gameify's equivalent of WinUtil's "repair common Windows problems"
   panel, just aimed at Linux gaming's actual failure modes (Vulkan, Wine
   prefixes, `vm.max_map_count`, GameMode).
3. **Update management (done this cycle)** — `update.sh` plus self-managed
   cron, the equivalent of WinUtil's scheduled-maintenance angle.
4. **Minimal TUI (near-term, see above)** — replace plain `select` menus
   with a `gum`/`dialog`-based TUI that visually groups options by tier,
   the first real "UI" pass before a graphical one.
5. **Native GUI (medium-term)** — a GTK (to match GNOME, the default DE on
   Fedora/most Nobara-adjacent setups) or Qt front-end that shells out to
   the exact same `.sh` functions underneath, with three visually distinct
   sections mirroring Standard/Advanced/Experimental, a live system-report
   panel, and a one-click "run auto-heal now" button. The scripts stay the
   source of truth and remain independently runnable from a terminal —
   the GUI is a thin, optional layer, not a rewrite.
6. **Optional web-local GUI (further out, exploratory)** — a small local
   web server (e.g. `systemd --user` service serving on localhost) as an
   alternative to a native GUI toolkit, for people who'd rather manage
   gameify from a browser tab; only worth doing if there's real demand,
   since it adds a whole extra maintenance surface (auth, CSRF, etc.) for
   something that's supposed to be a trusted local tool.

## Medium-term: closing the distro-model gap

- [ ] **Immutable overlay mode**: investigate whether an OCI/`rpm-ostree`-
      style layered image could be offered as an *optional* alternative
      install path on Fedora-based systems, giving Bazzite-style atomic
      updates/rollback without requiring a totally separate distro.
- [ ] **Controller/handheld daemon**: evaluate integrating with or
      packaging something like Bazzite's HHD (Handheld Daemon) for
      TDP/fan-curve/controller-remapping support on handheld PCs — this is
      one of Bazzite's biggest practical advantages for that hardware class.
- [ ] **Pre-flight compatibility checks**: query ProtonDB/SteamDB-style data
      (respecting their terms of use) so the report can flag "this specific
      GPU+driver combo has known issues with X" before install, not after.

## Community & trust

- [ ] Publish `gameify` itself as a Flatpak or a `.deb`/`.rpm`/AUR package,
      so people aren't cloning a git repo and running scripts blind.
- [ ] Signed releases (GPG or Sigstore) once the project is stable enough
      that "verify before you `sudo`" is a meaningful promise to make.
- [ ] A test matrix (real VMs, not just syntax checks) across the four
      supported distro families before every tagged release.

## Explicitly out of scope for now

- Building and maintaining a full custom ISO — that's a different project
  with a different maintenance burden (mirrors, image builds, ISO testing)
  than a script repo can responsibly take on without a team behind it.
- Anything that would need to ship a custom/forked kernel by default —
  `kernel.sh` intentionally stays opt-in and uses upstream XanMod/
  Liquorix/zen builds rather than gameify maintaining its own.

## Contributing

If you want to help move any of the above from idea to PR, the most useful
first contributions are real hardware testing reports (what worked, what
didn't, on which distro/GPU combo) — that's the thing a script like this
can't get from CI alone.
