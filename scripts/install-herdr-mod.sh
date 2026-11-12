#!/bin/sh
# Install (or --uninstall) the NemoNotch mod into the running Herdr app.
#
#   sh scripts/install-herdr-mod.sh            # install / refresh (idempotent)
#   sh scripts/install-herdr-mod.sh --uninstall
#
# The mod lives in a kept frameless window (Herdr's main layout is read-only and
# mod.json docking doesn't take): `do mod.open` opens it once, Herdr records it in
# windows.json and reopens it on every start. `mod.open` is a TOGGLE, so install
# only calls it when the window isn't already open. Uninstall order matters:
# close the window first, THEN delete the folder — the reverse leaves
# "no mod folder" in `status.errors` and the window can't be closed by id.
set -eu

MOD=nemonotch
SRC="$(cd "$(dirname "$0")/.." && pwd)/integrations/herdr-mod"
HOME_DIR="${HERDR_APP_HOME:-$HOME/.config/herdr-app}"
DEST="$HOME_DIR/mods/$MOD"

if command -v herdr-app >/dev/null 2>&1; then
    HERDR=herdr-app
elif [ -x /Applications/Herdr.app/Contents/MacOS/Herdr ]; then
    HERDR=/Applications/Herdr.app/Contents/MacOS/Herdr
else
    echo "❌ Herdr not found (no herdr-app on PATH, no /Applications/Herdr.app)" >&2
    exit 1
fi

if ! STATUS=$("$HERDR" status 2>/dev/null); then
    echo "❌ Herdr window isn't running — open Herdr first, then re-run this script" >&2
    exit 1
fi

# true when the mod's kept window is currently open
window_open() {
    "$HERDR" status | python3 -I -c 'import json,sys; sys.exit(0 if "nemonotch" in (json.load(sys.stdin).get("overlays") or []) else 1)'
}

if [ "${1:-}" = "--uninstall" ]; then
    if window_open; then
        "$HERDR" do mod.open --name "$MOD" >/dev/null
        sleep 1
    fi
    if python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if any("nemonotch" in v for v in d.get("kept",{}).values()) else 1)' \
        "$HOME_DIR/windows.json" 2>/dev/null; then
        echo "❌ Herdr still keeps the nemonotch window; not deleting the folder (see $HOME_DIR/windows.json)" >&2
        exit 1
    fi
    rm -rf "$DEST"
    echo "✅ NemoNotch mod uninstalled"
    exit 0
fi

mkdir -p "$DEST"
# Only our sources: Herdr writes jsconfig.json / *.d.ts into the folder itself.
for file in mod.json main.js edges.js; do
    cp "$SRC/$file" "$DEST/$file"
done

if ! "$HERDR" check "$DEST"; then
    echo "❌ herdr-app check failed for $DEST" >&2
    exit 1
fi

if window_open; then
    echo "✅ NemoNotch mod updated (window already open; Herdr reloads it on save)"
else
    "$HERDR" do mod.open --name "$MOD" >/dev/null
    echo "✅ NemoNotch mod installed — look for ● NemoNotch in the sidebar's Spaces row"
fi
: "$STATUS"
