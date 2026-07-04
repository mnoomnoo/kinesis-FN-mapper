<h1>
  <img src="plasmoid/contents/icons/kinesisfn.svg" alt="Kinesis FN Mapper icon" width="32" align="center">
  Kinesis FN Mapper
</h1>

<p align="center">
  <a href="https://store.kde.org/p/2364571">
    <img src="https://img.shields.io/badge/KDE_Store-Get_it-1d99f3?logo=kde&logoColor=white" alt="Get it on the KDE Store">
  </a>
</p>

Kinesis FN Mapper puts the FN-layer keys of a Kinesis Freestyle2 (KB800) keyboard to work
on KDE Plasma 6. Those are the numpad overlay and the media/lock keys that FN normally locks
you into. Pick any FN key in the widget and choose what it does: pass it through so it behaves
normally, block it so it sends nothing, remap it to another key or shortcut, or run a command
each time you press it. Everything is set up from a Plasma widget, no config files required.

<p align="center">
  <img src="docs/images/overview.png" alt="Kinesis FN Mapper widget — overview" width="60%">
  <br><em>The widget: numpad grid on the left, media/lock FN column on the right.</em>
</p>

<p align="center">
  See <a href="docs/screenshots.md">Screenshots</a> for each action shown in the editor.
</p>

## Requirements

- **KDE Plasma 6** (the applet requires Plasma API ≥ 6.0)
- **Python 3** with **[python-evdev](https://python-evdev.readthedocs.io/)** —
  install it yourself (see below); the daemon can't run without it.
- **polkit** (`pkexec`) — used once to install the autostart service, and to
  start/stop it afterwards.
- A **Kinesis Freestyle2 / KB800** keyboard
- The daemon needs root (it reads `/dev/input/*` and writes `/dev/uinput`), but that
  root is confined to a single auto-started service — your user account gains no new
  privileges.

## Install

You can install straight from the **KDE Store** (recommended for users) or **from
source** (recommended for developers — edits are live). Either way you install the
`python3-evdev` dependency once, and then click **Enable autostart** in the widget a
single time.

### From the KDE Store

**1. Install the daemon dependency** — this is the only terminal step:

```bash
sudo dnf install python3-evdev      # Fedora
# sudo apt install python3-evdev    # Debian/Ubuntu
# pip install --user evdev          # any distro
```

**2. Get the widget.** Right-click a panel or the desktop → *Add Widgets…* → *Get New
Widgets…* → *Download New Plasma Widgets*, then search **"Kinesis FN Mapper"** and
install. (Or grab the `.plasmoid` from the [store page](https://store.kde.org/p/2364571)
and run `kpackagetool6 --type Plasma/Applet -i <file>.plasmoid`.)

**3. Add it.** *Add Widgets…* → search **"Kinesis FN Mapper"** → add it to a panel or
the desktop.

**4. Enable autostart (once).** Open the widget and click **Enable autostart**;
authorise the **single** polkit prompt. This installs the daemon as a system service
that starts now and on every boot — no per-session Start, no repeated prompts.

### From source (developers)

```bash
git clone https://github.com/mnoomnoo/kinesis-FN-mapper.git
cd kinesis-FN-mapper
sudo dnf install python3-evdev      # (or apt / pip, as above)
./install.sh
```

`install.sh` symlinks both the applet package **and** its icon back to the repo (so
your edits are live with no reinstall), refreshes the caches, and reloads the shell.
Doing it by hand is equivalent to:

```bash
# applet package
ln -s "$PWD/plasmoid" ~/.local/share/plasma/plasmoids/com.desky.kinesisfn
# icon into the user icon theme (see note below)
ln -s "$PWD/plasmoid/contents/icons/kinesisfn.svg" \
      ~/.local/share/icons/hicolor/scalable/apps/kinesisfn.svg
kquitapp6 plasmashell && kstart plasmashell   # reload the shell
```

Then add the widget and click **Enable autostart** exactly as in the store flow above.
(The equivalent CLI, if you'd rather not use the button, is
`sudo plasmoid/contents/daemon/kinesis-fn-setup.sh enable "$USER" "$HOME" "$PWD/plasmoid/contents/daemon/fn_remap.py"`.)

> ℹ️ **Why the icon symlink?** The system-tray icon is loaded from the package by
> path, but the **"Add Widgets" explorer** resolves `metadata.json`'s
> `"Icon": "kinesisfn"` through the **freedesktop icon theme** — not the package. So
> the SVG must be installed into an icon theme (`hicolor/scalable/apps`). `install.sh`
> does this; a plain KDE Store install does not, so the *explorer listing* icon may be
> blank there (the in-panel icon is unaffected).

> ⚠️ **Never run `kpackagetool6 --type Plasma/Applet -u plasmoid` against the
> symlinked install.** The upgrade removes the existing package first, and with a
> symlinked dev install that follows the link and **deletes your source tree**. To
> apply changes just restart plasmashell (above) or re-add the widget.

If you'd rather install a plain **copy** (not a dev symlink), use
`kpackagetool6 --type Plasma/Applet -i plasmoid`.

## Usage

1. Open the widget (click its icon in the panel).
2. Click a key tile. The tiles are arranged like the physical keyboard: the numpad
   overlay grid on the left, the media/lock FN column on the right.
3. Pick an action in the editor:
   - **Pass through** — key behaves normally.
   - **Block** — key sends nothing.
   - **Remap** — send another key, optionally with Ctrl/Alt/Shift/Super held.
   - **Run command** — run a shell command once per press (e.g. `kcalc`).
4. Click **Save** — the change applies within about a second. No restart, no prompt.

Once you've clicked **Enable autostart** (see Install), the daemon runs as a service
that comes up on every boot — you never start it manually again. The status pill shows
**Running** / **Stopped** (polled every 2 s), and the **Start**/**Stop** buttons control
the service if you want to. The daemon **watches the config file and reloads it live**,
so saved edits take effect within a second while the daemon keeps its keyboard grab —
there's nothing to restart. (A **Restart** button is still there as a manual fallback; a
bad edit is ignored with a log warning and the last good mapping stays in force.)

### Config file

Both halves share:

```
~/.config/kinesis-fn/fn_map.json
```

It's seeded from the built-in defaults the first time the daemon runs. It's a JSON
object keyed by evdev `KEY_*` name, one entry per FN key:

```jsonc
{
  "KEY_CALC": { "type": "remap", "keys": ["KEY_PLAYPAUSE"] },
  "KEY_KP7":  { "type": "remap", "keys": ["KEY_LEFTCTRL", "KEY_C"] },
  "KEY_KP1":  { "type": "run",   "cmd": "gnome-terminal" },
  "KEY_MUTE": { "type": "block" },
  "KEY_KP5":  { "type": "pass" }
}
```

- `pass` — re-emit the key unchanged.
- `block` — swallow it.
- `remap` — emit `keys` instead; **list modifiers first** (they're pressed in order
  on key-down, released in reverse on key-up).
- `run` — run `cmd` in a shell, once per physical press. Although the daemon runs as
  root, the command is launched **as your desktop user in your current session**, so GUI
  apps (e.g. `code`, `kcalc`) open normally.

You can edit this file by hand instead of using the widget; the daemon watches it and
picks up your changes automatically within a second — no restart needed.

### Autostart / the service

**Enable autostart** (in the widget, or the `kinesis-fn-setup.sh` CLI shown in Install)
installs two things, as root:

- `/usr/local/bin/kinesis-fn-remap` — a **root-owned copy** of the daemon (copied out of
  the package so systemd never runs root code from a user-writable path).
- `/etc/systemd/system/kinesis-fn.service` — a system service with your user and config
  path baked into its `ExecStart` (`--user <you> --config ~/.config/kinesis-fn/fn_map.json`).
  It's `enable`d, so it starts on every boot.

Check it any time with `systemctl status kinesis-fn` (or `journalctl -u kinesis-fn`).

To remove it, click **Disable autostart** in the widget, or run:

```bash
sudo systemctl disable --now kinesis-fn \
  && sudo rm -f /etc/systemd/system/kinesis-fn.service /usr/local/bin/kinesis-fn-remap \
  && sudo systemctl daemon-reload
```

### Running the daemon standalone

```bash
# after Enable autostart (root-owned copy):
sudo /usr/local/bin/kinesis-fn-remap [/dev/input/eventN] [--config PATH]
# from a source checkout:
sudo python3 plasmoid/contents/daemon/fn_remap.py [/dev/input/eventN] [--config PATH]
```

- The device defaults to auto-detecting the Kinesis node via
  `/dev/input/by-id/*Kinesis*-event-kbd`.
- `--config` defaults to the invoking user's `~/.config/kinesis-fn/fn_map.json`
  (resolved correctly even under `sudo`/`pkexec`).
- `--user NAME` is only needed when there's no `sudo`/`pkexec` environment to reveal
  the human — i.e. the systemd service uses it. Under `sudo` it's auto-resolved.
- Stop with **Ctrl-C** — the grab is always released on exit, so the keyboard
  recovers.

> **Recovery:** while the daemon holds the grab, if it ever wedges the keyboard
> appears dead. Kill it from another terminal (`pkill -f fn_remap`) or unplug/replug
> the keyboard.

## Development

Because the plasmoid is symlinked, **edits to the repo are live immediately** — no
install step. To see QML/JS changes, reload the shell:

```bash
kquitapp6 plasmashell && kstart plasmashell
```

(or just remove and re-add the widget).

### Previewing with plasmoidviewer

To run the widget in its own window without touching the panel — and without even
installing it — point `plasmoidviewer` (from `plasma-sdk`) at the package dir:

```bash
plasmoidviewer -a ~/pprojects/kinesis-FN-mapper/plasmoid
```

The bundled daemon and setup script live in the package under `contents/daemon/`, so
the widget's **Enable autostart** / **Start** / **Restart** actions resolve them
correctly here too.

### Packaging a release

To build the distributable `.plasmoid` archive (the file you upload to the KDE
Store):

```bash
./package.sh
```

It reads the version from `plasmoid/metadata.json` and writes
`dist/kinesis-fn-mapper-<version>.plasmoid`. The archive is a ZIP with
`metadata.json` at its **root** — the script guarantees this by zipping from inside
`plasmoid/`. **Bump `KPlugin.Version` in `plasmoid/metadata.json` before packaging**,
or the store will reject the re-upload as unchanged.

### Adding or changing an FN key

The FN key set is defined in **two** places that must stay in sync:

- `DEFAULT_FN_ACTIONS` in `plasmoid/contents/daemon/fn_remap.py` — the daemon's
  defaults and the authoritative key set.
- `FN_KEYS` in `keydata.js` — what the editor exposes; also add the code to
  `NUMPAD_GRID` or `FN_COLUMN` so it appears as a tile.

### Debugging the daemon

Run it in a terminal (`sudo python3 plasmoid/contents/daemon/fn_remap.py`) to watch its
startup line (which device/config it grabbed and how many keys) and `run`-action logs.
Once the service is installed, `journalctl -u kinesis-fn -f` shows the same output.

## How it works

On the KB800 the **FN** key is handled in firmware and is invisible to software; all
it does is make the affected keys emit *different* keycodes (numpad codes, media
codes). `fn_remap.py` takes exclusive control of the keyboard's evdev node with
`EVIOCGRAB`, re-emits every ordinary key untouched through a `uinput` virtual
keyboard, and for the FN-layer keycodes applies the action from the config. Keying
off those codes is effectively "FN + key".

The plasmoid never touches the keyboard directly — it just edits the shared JSON and,
once you've enabled autostart, controls a systemd system service that runs the daemon
(installed via a one-time `pkexec` step). The config is the contract between the two.

## License & Trademarks

MIT — see the source headers/`metadata.json`.

This is an independent, unofficial project and is not affiliated with, endorsed by, or
sponsored by Kinesis Corporation. "Kinesis", "Freestyle2", and "KB800" are trademarks of
Kinesis Corporation, used here solely for nominative/descriptive purposes to indicate the
hardware this tool works with.
