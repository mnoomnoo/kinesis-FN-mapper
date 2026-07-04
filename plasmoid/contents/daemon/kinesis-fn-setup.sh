#!/usr/bin/env bash
# Install/remove the Kinesis FN Mapper autostart service. Run as root (the widget
# invokes it via pkexec) — that's the *only* moment this project needs elevation.
#
#   kinesis-fn-setup.sh enable  <user> <home> <src_daemon.py>
#   kinesis-fn-setup.sh disable
#
# "enable" copies the daemon to a ROOT-OWNED path and writes+enables a systemd
# system service, so it starts at boot with no further prompts. The copy is
# deliberate: pointing the unit's ExecStart at the daemon inside ~/.local/share
# (user-writable) would let anything running as the user rewrite code that then
# runs as root at boot. A root-owned copy closes that hole.
set -euo pipefail

BIN=/usr/local/bin/kinesis-fn-remap
UNIT=/etc/systemd/system/kinesis-fn.service

die() { echo "kinesis-fn-setup: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (the widget uses pkexec)"

case "${1:-}" in
  enable)
    user="${2:-}"; home="${3:-}"; src="${4:-}"
    [ -n "$user" ] && [ -n "$home" ] && [ -n "$src" ] \
      || die "usage: enable <user> <home> <src_daemon.py>"
    id "$user" >/dev/null 2>&1 || die "unknown user: $user"
    [ -f "$src" ] || die "daemon not found: $src"

    config="$home/.config/kinesis-fn/fn_map.json"

    install -m 0755 -o root -g root "$src" "$BIN"

    # Write the unit atomically. --user makes the daemon resolve $user's config
    # and demote "run" actions to them, since a system service has no sudo env.
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
[Unit]
Description=Kinesis Freestyle2 FN-layer remapper
Documentation=https://github.com/mnoomnoo/kinesis-FN-mapper
After=multi-user.target

[Service]
Type=simple
ExecStart=$BIN --user $user --config $config
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    install -m 0644 -o root -g root "$tmp" "$UNIT"
    rm -f "$tmp"

    systemctl daemon-reload
    systemctl enable --now kinesis-fn.service
    echo "kinesis-fn-setup: enabled ($BIN, $UNIT) — autostarts at boot"
    ;;

  disable)
    # Tolerate a partial/absent install so this is always a safe teardown.
    systemctl disable --now kinesis-fn.service >/dev/null 2>&1 || true
    rm -f "$UNIT" "$BIN"
    systemctl daemon-reload
    echo "kinesis-fn-setup: disabled and removed"
    ;;

  *)
    die "usage: $(basename "$0") {enable <user> <home> <src_daemon.py> | disable}"
    ;;
esac
