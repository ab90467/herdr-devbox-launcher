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
5. Restarts `npm start` / `dev-remote.sh` in their existing herdr panes if
   they've been running for more than 6h (stale kubectl port-forwards and
   a long-lived vite server otherwise just sit there silently rotting).
   `dev-remote.sh` is restarted against the namespace (and `--context`, if
   set explicitly) it is *currently* forwarding to, read from its running
   `kubectl port-forward` children — not from kubeconfig — so `aam` vs
   `aambrann` survives a restart. If that can't be read, it is not restarted.
6. Attaches: `herdr --remote <devbox> --session <session>`.

On any failure it prints what went wrong and offers `r` to retry (loops
back to step 1) or any other key to close — no `exec`/process replacement,
just a plain loop, so it can't confuse the terminal's process tracking.

## Layout

| Path | What |
|---|---|
| `herdr-devbox-launcher.sh` | The actual launcher script. |
| `restart-stale-dev.py` | Runs on the devbox (piped via ssh into `python3 -`). Finds the `npm start` / `dev-remote.sh` panes by cwd and restarts whichever has been running past the threshold. Paths/commands are hardcoded for this project — edit `TARGETS` if yours differ (last field = keep the k8s namespace on restart). A `flock` on `/tmp/restart-stale-dev.lock` means a second launcher invocation landing while one is still mid-restart skips instead of racing it on the same pane. |
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

## Troubleshooting

**Splash hangs right after "herdr installert (...)"** — this is the
`brew outdated herdr` network call stalling, not a script bug. Close the
window and relaunch; it has resolved itself every time this has been
observed.

**"Can't type" in the window** — before suspecting herdr/the connection,
check window focus. The Dock app and a plain `ghostty` window share the
same app bundle/identity, so macOS Accessibility (`osascript ... set
frontmost of process ...`) cannot reliably force focus onto one over the
other — it can silently fail or get reclaimed by whichever window spawned
the script. Click directly on the Herdr Devbox window (or Cmd+Tab to it)
rather than trying to script the switch.
