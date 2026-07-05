# Roadmap

An honest look at the gap between "a script that configures your existing
distro" (what `gameify` is today) and "a gaming distro" (what Nobara and
Bazzite are), and the real steps to close it.

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
- [ ] Config file (`~/.config/gameify/config.toml` or similar) to save
      choices (which driver, whether to install Heroic, kernel choice) so
      re-runs and `update.sh` don't have to re-ask.
- [ ] Per-run JSON log (not just human-readable) so results are scriptable —
      useful for the community driver-testing idea below.
- [ ] Expand openSUSE support to be first-class instead of best-effort —
      needs real testing on Leap and Tumbleweed, not just theory.
- [ ] Gamescope **session** integration (a proper desktop-session entry, not
      just the binary) for people who want a console-like boot-to-Steam mode
      without leaving their existing desktop environment installed.
- [ ] A minimal TUI (using something like `gum` or `dialog`) instead of
      plain `select` menus — much friendlier on first run.

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
