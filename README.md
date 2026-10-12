# herdr-devbox-launcher

A Mac Dock app that connects to a remote devbox over Tailscale/SSH using
[herdr](https://herdr.dev), with health checks, retry-on-failure, and a
custom icon — rather than remembering a raw `herdr --remote ... --session ...`
command.

## What it does

Double-clicking **Herdr Devbox.app** opens a Ghostty window running
`herdr-devbox-launcher.sh`, which:

1. Checks `herdr` is installed and up to date (installs/upgrades via
   Homebrew if needed, with an hourly-cached brew-index check).
2. Checks Tailscale is installed and running.
3. Pings the devbox (5s timeout) over Tailscale.
4. Makes sure the **Claude Tools** app (a separate, unrelated local tool
   that bridges Mac-side MCP servers to the devbox) is running.
5. Attaches: `herdr --remote <devbox> --session <session>`.

On any failure it prints what went wrong and offers `r` to retry (loops
back to step 1) or any other key to close — no `exec`/process replacement,
just a plain loop, so it can't confuse the terminal's process tracking.

## Layout

| Path | What |
|---|---|
| `herdr-devbox-launcher.sh` | The actual launcher script. |
| `herdr-devbox-launch.conf` | Ghostty config: runs the launcher as the window's command, locks the window title to "Herdr Devbox" (overrides OSC title escapes), quits Ghostty when the window closes. |
| `app/HerdrDevbox` | The app bundle's "binary" — just a one-line zsh script invoking Ghostty with the config above. Not a compiled binary. |
| `app/Info.plist` | App bundle metadata (bundle id, name, icon file). |
| `icon/new_icon.png` | 1024×1024 source icon (vivid violet→sky-blue→emerald gradient, terminal chevron, amber signal glyph — no bright border, which the generic Automator default icon had). |
| `icon/make_icon.py` | Regenerates `new_icon.png` from scratch (Pillow). Only needed if you want to redesign the icon; `install.sh` works directly off the committed PNG otherwise. |
| `install.sh` | Builds the `.icns` from the PNG, assembles `Herdr Devbox.app`, and installs everything. Safe to re-run. |

## Install

Edit `DEVBOX` and `SESSION` at the top of `herdr-devbox-launcher.sh` first —
they're hardcoded to this machine's devbox host/session name.

```bash
./install.sh
```

Then drag `~/Applications/Herdr Devbox.app` to the Dock.

## Why a plain zsh script instead of a "real" Automator/Swift app

Automator's generated binary stub is just as replaceable with a one-liner
`exec`, and keeping it as a plain text file means the whole app is
reproducible from source in this repo — no compiled artifact to lose track
of.
