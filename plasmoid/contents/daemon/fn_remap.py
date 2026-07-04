#!/usr/bin/env python3
"""Intercept the Kinesis Freestyle2 FN-layer keys and act on them.

Unlike hid_watch.py (which reads /dev/hidraw3 *passively* and can only observe),
this tool takes exclusive control of the keyboard's evdev node with EVIOCGRAB,
so the chosen keys never reach the rest of the system. A uinput virtual keyboard
re-emits everything else untouched, and for the FN-layer keys we do whatever the
FN_ACTIONS table says: pass through, block, remap to another key/combo, or launch
a command.

Layout note: on the KB800 *all* FN keys -- the numpad overlay (NumLock/ScrollLock/
Insert + keypad codes) and the media keys (Mute/Vol/Calc) -- surface on the single
"...KB800 Keyboard" evdev node (the -event-kbd by-id symlink -> event6), so we grab
exactly one device.

FN state itself is invisible to software (it is handled in the keyboard firmware);
we only ever see the resulting keycodes. On this keyboard the numpad overlay codes
only appear while FN is held, so keying off those codes is equivalent to "FN + key".

The mapping table lives in a JSON config (default ~/.config/kinesis-fn/fn_map.json,
seeded from the built-in defaults on first run) shared with the "Kinesis FN Mapper"
KDE plasmoid, which edits it visually. The daemon watches this file and reloads it
live the moment it changes -- so edits (from the plasmoid or by hand) take effect
within a second with no restart and without ever dropping the keyboard grab. A bad
edit is ignored with a warning; the last good mapping stays in force.

Usage:  sudo python3 fn_remap.py [/dev/input/eventN] [--config PATH] [--user NAME]
Stop:   Ctrl-C   (the grab is always released on exit, so the keyboard recovers)

--user is only needed when there is no sudo/pkexec environment to reveal the
human behind us (i.e. the systemd system service in kinesis-fn.service); it names
the desktop user whose config we read and to whom "run" actions are demoted.

Safety: if this process ever wedges while grabbing, the keyboard appears dead until
the grab is released. Kill the process from another terminal (pkill -f fn_remap),
or unplug/replug the keyboard, to recover.
"""
import argparse
import glob
import json
import os
import pwd
import select
import subprocess
import sys

import evdev
from evdev import ecodes


class ConfigError(Exception):
    """A malformed/unreadable config. Fatal at startup (fail-fast), but merely
    warned-about on a live reload so a bad edit never kills the running daemon."""


# --- action helpers ---------------------------------------------------------
# Each FN_ACTIONS value is one of these. The event loop inspects the type.
PASS = ("pass",)          # re-emit the original key event unchanged
BLOCK = ("block",)        # swallow the key entirely


def remap(*key_names):
    """Emit a different key or combo instead of the captured key.

    On key-down the targets are pressed in order (so modifiers land first); on
    key-up they are released in reverse. Auto-repeat is passed through so held
    remapped keys still repeat. Example: remap("KEY_LEFTCTRL", "KEY_C")."""
    codes = [ecodes.ecodes[n] for n in key_names]
    return ("remap", codes)


def run(cmd):
    """Run a shell command once per physical press (key-down only), detached."""
    return ("run", cmd)


# --- the built-in defaults: one stub per FN-layer key, PASS by default ------
# These seed the JSON config file the first time the daemon runs; after that the
# file (edited by hand or by the Kinesis FN Mapper plasmoid) is the source of
# truth. Anything not listed here (i.e. every normal key) is always passed
# through untouched. The key set here defines exactly which FN keys the editor
# exposes, so keep it in sync with the KB800 FN layer.
DEFAULT_FN_ACTIONS = {
    # --- numpad overlay ---
    "KEY_NUMLOCK":    PASS,
    "KEY_SCROLLLOCK": PASS,
    "KEY_INSERT":     PASS,

    "KEY_KPSLASH":    PASS,  # FN '/'
    "KEY_KPASTERISK": PASS,  # FN '*'
    "KEY_KPMINUS":    PASS,  # FN '-'
    "KEY_KPPLUS":     PASS,  # FN '+'

    "KEY_KP1": PASS,
    "KEY_KP2": PASS,
    "KEY_KP3": PASS,
    "KEY_KP4": PASS,
    "KEY_KP5": PASS,
    "KEY_KP6": PASS,
    "KEY_KP7": PASS,
    "KEY_KP8": PASS,
    "KEY_KP9": PASS,
    "KEY_KP0": PASS,
    "KEY_KPDOT": PASS,

    # --- media keys ---
    "KEY_MUTE":       PASS,
    "KEY_VOLUMEDOWN": PASS,
    "KEY_VOLUMEUP":   PASS,
    "KEY_CALC":       PASS,





    # Examples to flip on later:
    #   "KEY_KP7":    remap("KEY_F13"),
    #   "KEY_KPPLUS": remap("KEY_LEFTCTRL", "KEY_C"),
    #   "KEY_CALC":   run("gnome-terminal"),
}

# key event values
KEY_UP, KEY_DOWN, KEY_REPEAT = 0, 1, 2


def resolve_device(arg=None):
    """Return the evdev path to grab. Prefer the stable by-id symlink for the
    Kinesis keyboard node (the raw /dev/input/eventN number shifts across replugs)."""
    if arg:
        return arg
    for link in glob.glob("/dev/input/by-id/*Kinesis*-event-kbd"):
        return os.path.realpath(link)
    return "/dev/input/event6"


def open_device(dev):
    """Open an evdev node with friendly errors (mirrors hid_watch.open_device)."""
    try:
        return evdev.InputDevice(dev)
    except PermissionError:
        sys.exit(f"permission denied opening {dev} -- run with sudo")
    except FileNotFoundError:
        sys.exit(f"{dev} not found -- check `ls /dev/input/by-id/ | grep -i kinesis`")


# --- config file (shared with the Kinesis FN Mapper plasmoid) ---------------
# The on-disk format is a JSON object keyed by evdev KEY_* name, one entry per FN
# key, e.g.  {"KEY_CALC": {"type": "remap", "keys": ["KEY_PLAYPAUSE"]}}.
#   type "pass"  -> {}                       re-emit unchanged
#   type "block" -> {}                       swallow
#   type "remap" -> {"keys": ["KEY_..", ..]} modifiers first
#   type "run"   -> {"cmd": "shell string"}

def _name_for_code(code):
    """Best-effort code -> canonical KEY_* name, for serialising defaults."""
    name = ecodes.KEY.get(code)
    if isinstance(name, list):  # some codes carry several aliases
        key_names = [n for n in name if n.startswith("KEY_")]
        return key_names[0] if key_names else name[0]
    return name


def action_to_json(action):
    """Internal action tuple -> JSON-serialisable config entry."""
    kind = action[0]
    if kind == "pass":
        return {"type": "pass"}
    if kind == "block":
        return {"type": "block"}
    if kind == "remap":
        return {"type": "remap", "keys": [_name_for_code(c) for c in action[1]]}
    if kind == "run":
        return {"type": "run", "cmd": action[1]}
    raise ValueError(f"unserialisable action: {action!r}")


def json_to_action(entry, where):
    """Config entry -> internal action tuple, resolving key names to codes.
    Raises ConfigError on any malformed/unknown entry (fail-fast, like the old
    build_actions did for typos); the caller decides fatal-vs-warn."""
    if not isinstance(entry, dict):
        raise ConfigError(f"malformed entry in {where}: {entry!r} (want a JSON object)")
    t = entry.get("type")
    if t == "pass":
        return PASS
    if t == "block":
        return BLOCK
    if t == "remap":
        names = entry.get("keys", [])
        try:
            return ("remap", [ecodes.ecodes[n] for n in names])
        except KeyError as e:
            raise ConfigError(f"unknown key name in {where}: {e.args[0]!r}")
    if t == "run":
        return ("run", entry.get("cmd", ""))
    raise ConfigError(f"unknown action type {t!r} in {where}")


def default_config():
    """The built-in defaults as the on-disk JSON dict."""
    return {name: action_to_json(action) for name, action in DEFAULT_FN_ACTIONS.items()}


def invoking_user_ids():
    """(uid, gid, home) of the human running us, seen through sudo/pkexec (where
    $HOME/euid are root's). Returns None if we can't tell (i.e. run unprivileged)."""
    user = os.environ.get("SUDO_USER")
    if user:
        try:
            pw = pwd.getpwnam(user)
            return (pw.pw_uid, pw.pw_gid, pw.pw_dir)
        except KeyError:
            pass
    uid = os.environ.get("PKEXEC_UID")
    if uid:
        try:
            pw = pwd.getpwuid(int(uid))
            return (pw.pw_uid, pw.pw_gid, pw.pw_dir)
        except (KeyError, ValueError):
            pass
    return None


# --- launching "run" commands as the desktop user ---------------------------
# The daemon runs as root (pkexec strips the environment), so a "run" action must
# NOT fire the command as-is: root has no graphical session (no DISPLAY/WAYLAND_
# DISPLAY, DBUS, XDG_RUNTIME_DIR), and GUI apps like `code` would either fail to
# reach the compositor or refuse to run as root. We demote to the invoking user
# and hand them back their session environment before exec.

# The subset of the user's session environment a GUI command needs to reach the
# running desktop. Copied verbatim from a live session process when we find one.
_SESSION_VARS = (
    "DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY",
    "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR",
    "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP", "XDG_DATA_DIRS",
)


def _uid_of(pid):
    """Real uid owning /proc/<pid>, or None if it's gone / unreadable."""
    try:
        return os.stat(f"/proc/{pid}").st_uid
    except OSError:
        return None


def _read_environ(pid):
    """Parse /proc/<pid>/environ (NUL-separated) into a dict, or {} if unreadable."""
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            raw = f.read()
    except OSError:
        return {}
    env = {}
    for chunk in raw.split(b"\0"):
        if b"=" in chunk:
            k, v = chunk.split(b"=", 1)
            env[k.decode("utf-8", "replace")] = v.decode("utf-8", "replace")
    return env


def session_env(uid, home, name):
    """The environment to launch a user's "run" command in, so it reaches their
    graphical session. Prefer copying the live session vars from a process owned by
    `uid` that has a display set (e.g. plasmashell/kwin); otherwise synthesise the
    reliable ones from /run/user/<uid>. Always sets HOME/USER/LOGNAME."""
    env = dict(os.environ)  # inherit PATH etc. from the daemon, then correct identity
    env.update(HOME=home, USER=name, LOGNAME=name)

    found = None
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit() or _uid_of(entry.name) != uid:
            continue
        penv = _read_environ(entry.name)
        if penv.get("WAYLAND_DISPLAY") or penv.get("DISPLAY"):
            found = penv
            break

    if found:
        for var in _SESSION_VARS:
            if var in found:
                env[var] = found[var]
    else:
        # No live session process visible -- fall back to the standard locations.
        runtime = f"/run/user/{uid}"
        env.setdefault("XDG_RUNTIME_DIR", runtime)
        env.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path={runtime}/bus")
        env.setdefault("WAYLAND_DISPLAY", "wayland-0")
        env.setdefault("DISPLAY", ":0")
    return env


def demote_preexec(uid, gid, name):
    """Return a preexec_fn that irreversibly drops root -> (uid, gid) before exec.
    Group changes need root, so setgid/initgroups must precede setuid; after
    os.setuid(uid) from uid 0 the real+effective+saved uids are all `uid`, so the
    launched command can never regain root."""
    def _demote():
        os.setgid(gid)
        os.initgroups(name, gid)
        os.setuid(uid)
    return _demote


def make_run_launcher():
    """Resolve *once* how "run" actions are launched, returning launch(name, cmd).

    The decision matrix guarantees a command is never executed as root:
      - unprivileged daemon      -> run as-is (already not root);
      - root + invoking user known -> demote to that user, inject their session env;
      - root + user not resolvable -> refuse and warn (better a no-op than a root GUI).
    Identity + preexec are resolved once, but the session env is captured *per-press*
    so run-commands always target the current session (survives logout/login without a
    daemon restart)."""
    base = dict(shell=True, start_new_session=True,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL)

    if os.geteuid() != 0:
        def launch(name, cmd):
            print(f"{name}: run {cmd!r}")
            subprocess.Popen(cmd, **base)
        return launch

    ids = invoking_user_ids()
    pw_name = None
    if ids is not None:
        try:
            pw_name = pwd.getpwuid(ids[0]).pw_name
        except KeyError:
            pw_name = None

    if pw_name is None:
        def launch(name, cmd):
            print(f"{name}: refusing to run {cmd!r} as root "
                  f"-- could not resolve the desktop user")
        return launch

    uid, gid, home = ids
    preexec = demote_preexec(uid, gid, pw_name)

    def launch(name, cmd):
        print(f"{name}: run {cmd!r} as {pw_name}")
        subprocess.Popen(cmd, env=session_env(uid, home, pw_name),
                         preexec_fn=preexec, **base)
    return launch


def resolve_config_path(arg=None):
    """Where to read the mapping from. An explicit --config wins; otherwise the
    invoking user's ~/.config/kinesis-fn/fn_map.json (resolved even under sudo)."""
    if arg:
        return arg
    ids = invoking_user_ids()
    home = ids[2] if ids else os.path.expanduser("~")
    return os.path.join(home, ".config", "kinesis-fn", "fn_map.json")


def seed_config(path):
    """Write the built-in defaults to `path` on first run. If we're root via
    sudo/pkexec, hand the new dir+file to the invoking user so the plasmoid (run
    unprivileged) can edit it later."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(default_config(), f, indent=2)
        f.write("\n")
    ids = invoking_user_ids()
    if ids and os.geteuid() == 0:
        uid, gid, _ = ids
        os.chown(os.path.dirname(path), uid, gid)
        os.chown(path, uid, gid)


def load_actions(path):
    """Resolve the JSON config at `path` to {code: (name, action)} for the event
    loop, seeding the file from defaults if it does not exist yet."""
    if not os.path.exists(path):
        seed_config(path)
        config = default_config()
    else:
        try:
            with open(path) as f:
                config = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            raise ConfigError(f"cannot read config {path}: {e}")
        if not isinstance(config, dict):
            raise ConfigError(f"config {path} must be a JSON object of KEY_* -> action")

    resolved = {}
    where = f"config {path}"
    for name, entry in config.items():
        try:
            code = ecodes.ecodes[name]
        except KeyError:
            raise ConfigError(f"unknown key name in {where}: {name!r}")
        resolved[code] = (name, json_to_action(entry, where))
    return resolved


def make_uinput(dev, actions):
    """Virtual keyboard mirroring the source device, plus every remap target code
    (which may not be a source capability, e.g. KEY_PLAYPAUSE / KEY_F13) so those
    synthesised events aren't silently filtered out."""
    caps = dev.capabilities()
    caps.pop(ecodes.EV_SYN, None)  # UInput manages SYN itself
    caps.pop(ecodes.EV_FF, None)   # skip force-feedback upload slots
    keys = set(caps.get(ecodes.EV_KEY, []))
    for _, action in actions.values():
        if action[0] == "remap":
            keys.update(action[1])
    caps[ecodes.EV_KEY] = sorted(keys)
    return evdev.UInput(caps, name="fn-remap")


# --- live reload ------------------------------------------------------------
# The daemon polls the config's mtime once per select() timeout and reloads when
# it changes. This keeps the exclusive grab held the whole time (a restart would
# briefly release it) and needs no privilege escalation: the plasmoid already
# rewrites the file unprivileged, and we just notice.

def config_mtime(path):
    """The config's mtime in ns, or None if it's currently unreadable/absent."""
    try:
        return os.stat(path).st_mtime_ns
    except OSError:
        return None


def dispatch(ev, actions, ui, launch):
    """Apply one input event through the current mapping (the body of the event
    loop, factored out so reload can swap `actions`/`ui` between calls)."""
    if ev.type != ecodes.EV_KEY:
        # forward SYN/LED/MSC etc. verbatim so state stays consistent
        ui.write_event(ev)
        return

    entry = actions.get(ev.code)
    if entry is None:
        # normal key -- pass straight through
        ui.write_event(ev)
        ui.syn()
        return

    name, action = entry
    kind = action[0]

    if kind == "pass":
        ui.write_event(ev)
        ui.syn()
    elif kind == "block":
        pass  # swallow
    elif kind == "remap":
        codes = action[1]
        if ev.value == KEY_DOWN:
            for c in codes:
                ui.write(ecodes.EV_KEY, c, KEY_DOWN)
            ui.syn()
        elif ev.value == KEY_UP:
            for c in reversed(codes):
                ui.write(ecodes.EV_KEY, c, KEY_UP)
            ui.syn()
        elif ev.value == KEY_REPEAT:
            # repeat the last (non-modifier) target so holding still autorepeats
            ui.write(ecodes.EV_KEY, codes[-1], KEY_REPEAT)
            ui.syn()
    elif kind == "run":
        if ev.value == KEY_DOWN:  # once per press, ignore repeats
            launch(name, action[1])


def reload_actions(path, dev, old_ui, old_actions):
    """Re-read the config and swap in the new mapping *without ungrabbing*.

    Returns (actions, ui). On any config error the old mapping is kept (the daemon
    stays useful with the last good config) and a warning is printed. On success
    the uinput device is rebuilt so freshly-added remap targets (e.g. a new
    KEY_F13 not in the original capabilities) are advertised; the new device is
    created before the old is closed to keep the swap gap minimal."""
    try:
        new_actions = load_actions(path)
    except ConfigError as e:
        print(f"reload skipped -- {e}", file=sys.stderr)
        return old_actions, old_ui
    new_ui = make_uinput(dev, new_actions)
    old_ui.close()
    print(f"reloaded config {path} ({len(new_actions)} keys)")
    return new_actions, new_ui


def parse_args():
    p = argparse.ArgumentParser(description="Kinesis Freestyle2 FN-layer remapper")
    p.add_argument("device", nargs="?",
                   help="evdev node to grab (default: auto-detect Kinesis)")
    p.add_argument("--config", metavar="PATH",
                   help="mapping JSON (default: ~/.config/kinesis-fn/fn_map.json)")
    p.add_argument("--user", metavar="NAME",
                   help="desktop user to serve when there's no sudo/pkexec env "
                        "(used by the systemd system service): its config is read "
                        "and 'run' actions are demoted to it")
    return p.parse_args()


def main():
    args = parse_args()
    # Under a systemd system service there's no SUDO_USER/PKEXEC_UID, so
    # invoking_user_ids() can't tell whose config to use or whom to demote "run"
    # actions to. --user names that human explicitly; feeding it through SUDO_USER
    # lets the existing resolution (invoking_user_ids) pick it up unchanged.
    if args.user:
        os.environ["SUDO_USER"] = args.user
    config_path = resolve_config_path(args.config)
    dev = open_device(resolve_device(args.device))
    try:
        actions = load_actions(config_path)  # fail-fast at startup only
    except ConfigError as e:
        sys.exit(str(e))
    ui = make_uinput(dev, actions)
    launch = make_run_launcher()

    print(f"grabbing {dev.path} ({dev.name!r}); "
          f"config {config_path} ({len(actions)} keys) ... Ctrl-C to stop")
    try:
        dev.grab()
    except OSError as e:
        # EBUSY: another process already holds the exclusive grab (EVIOCGRAB) on this
        # device -- usually a second copy of this daemon still running. Exit with a
        # legible one-liner instead of an opaque traceback (under systemd we'd just
        # crash-loop on Restart=on-failure otherwise).
        ui.close()
        sys.exit(f"cannot grab {dev.path}: {e.strerror} -- is another fn_remap "
                 f"instance already running? (check: pgrep -af fn_remap)")
    # Event loop with a 1s heartbeat: select() wakes on real key activity, and
    # its timeout gives us a cheap once-a-second window to notice a config change
    # and reload live. Both the evdev grab and the process persist across reloads.
    POLL_INTERVAL = 1.0
    last_mtime = config_mtime(config_path)
    try:
        while True:
            try:
                ready, _, _ = select.select([dev.fd], [], [], POLL_INTERVAL)
            except InterruptedError:
                continue  # a signal woke select(); just loop back
            if ready:
                for ev in dev.read():
                    dispatch(ev, actions, ui, launch)

            mtime = config_mtime(config_path)
            if mtime is not None and mtime != last_mtime:
                last_mtime = mtime
                actions, ui = reload_actions(config_path, dev, ui, actions)
    finally:
        dev.ungrab()
        ui.close()
        print("\nungrabbed -- keyboard restored")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
