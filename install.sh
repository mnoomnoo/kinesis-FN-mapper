#!/usr/bin/env bash
# Symlink-deploy the Kinesis FN Mapper plasmoid and its icon, then reload Plasma.
#
# Both the applet package and its icon are symlinked back to this repo, so edits
# to the source are live with no reinstall step.
#
#   - Applet:  ~/.local/share/plasma/plasmoids/com.desky.kinesisfn -> ./plasmoid
#   - Icon:    ~/.local/share/icons/hicolor/scalable/apps/kinesisfn.svg
#             -> ./plasmoid/contents/icons/kinesisfn.svg
#
# The icon symlink is what makes the custom icon show up in the "Add Widgets"
# explorer: Plasma resolves metadata.json's "Icon": "kinesisfn" through the
# freedesktop icon theme, not the package, so the SVG must live in an icon theme.
#
# NOTE: never `kpackagetool6 -u` this install — the upgrade removes the package
# first and, following the symlink, would delete this repo's source tree.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Applet package
plasmoids_dir="$HOME/.local/share/plasma/plasmoids"
mkdir -p "$plasmoids_dir"
ln -sfn "$REPO/plasmoid" "$plasmoids_dir/com.desky.kinesisfn"

# 2. Icon into the user icon theme (so the widget listing has an icon)
icons_dir="$HOME/.local/share/icons/hicolor/scalable/apps"
mkdir -p "$icons_dir"
ln -sf "$REPO/plasmoid/contents/icons/kinesisfn.svg" "$icons_dir/kinesisfn.svg"

# 3. Refresh caches
kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true

# 4. Reload the shell so both applet and icon are picked up
if command -v kquitapp6 >/dev/null 2>&1; then
  kquitapp6 plasmashell >/dev/null 2>&1 || true
  (kstart plasmashell >/dev/null 2>&1 &)
fi

echo "Installed. Add the widget via: right-click panel/desktop -> Add Widgets -> \"Kinesis FN Mapper\""
