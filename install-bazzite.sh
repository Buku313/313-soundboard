#!/usr/bin/env bash
# 313 Soundboard - Bazzite / Immutable Linux Installer
# Works on Bazzite, Fedora Atomic, SteamOS, or any Linux where TS6 isn't at /opt/teamspeak
#
# Usage:
#   ./install-bazzite.sh                    # auto-detect TeamSpeak location
#   ./install-bazzite.sh /path/to/TeamSpeak  # specify path manually

set -euo pipefail

ADDON_ID="myinstants_soundboard"
ADDON_NAME="MyInstants Soundboard"
ADDON_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}$1${NC}"; }
ok()    { echo -e "${GREEN}$1${NC}"; }
warn()  { echo -e "${YELLOW}$1${NC}"; }
err()   { echo -e "${RED}$1${NC}"; }

# ── Read addon source files ─────────────────────────────────

CSS_FILE="$SCRIPT_DIR/myinstants-soundboard/src/soundboard.css"
JS_FILE="$SCRIPT_DIR/myinstants-soundboard/src/soundboard.js"

if [[ ! -f "$CSS_FILE" ]] || [[ ! -f "$JS_FILE" ]]; then
    err "Error: Can't find addon source files."
    err "Make sure you're running this from the 313-soundboard repo root."
    err "Expected: $CSS_FILE"
    err "Expected: $JS_FILE"
    exit 1
fi

SOUNDBOARD_CSS="$(cat "$CSS_FILE")"
SOUNDBOARD_JS="$(cat "$JS_FILE")"

# ── Find TeamSpeak ──────────────────────────────────────────

find_teamspeak() {
    local candidates=(
        # Manual arg
        "$1"
        # Common Linux install locations
        "/opt/teamspeak"
        "/opt/TeamSpeak"
        "$HOME/TeamSpeak"
        "$HOME/teamspeak"
        "$HOME/Applications/TeamSpeak"
        "$HOME/.local/share/TeamSpeak"
        "$HOME/.local/opt/TeamSpeak"
        # Flatpak locations
        "$HOME/.local/share/flatpak/app/com.teamspeak.TeamSpeak/current/active/files"
        "/var/lib/flatpak/app/com.teamspeak.TeamSpeak/current/active/files"
        # Snap
        "/snap/teamspeak/current"
        # AppImage extraction
        "$HOME/.local/share/appimagekit/TeamSpeak"
    )

    for dir in "${candidates[@]}"; do
        [[ -z "$dir" ]] && continue
        local index="$dir/html/client_ui/index.html"
        if [[ -f "$index" ]]; then
            echo "$dir"
            return 0
        fi
    done

    # Broader search in home directory
    local found
    found=$(find "$HOME" -maxdepth 5 -path "*/html/client_ui/index.html" -type f 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        # Strip html/client_ui/index.html to get the TS dir
        echo "${found%/html/client_ui/index.html}"
        return 0
    fi

    return 1
}

# ── Inject addon ────────────────────────────────────────────

inject_addon() {
    local ts_dir="$1"
    local index_path="$ts_dir/html/client_ui/index.html"

    if [[ ! -f "$index_path" ]]; then
        err "Error: index.html not found at $index_path"
        return 1
    fi

    # Build inject payload
    local inject="<style>${SOUNDBOARD_CSS}</style><script>${SOUNDBOARD_JS}</script>"

    # Wrap with addon markers
    local install_id
    install_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen || echo "$(date +%s)-$$")"
    local name_b64
    name_b64="$(echo -n "$ADDON_NAME" | base64)"
    local start_marker="<!-- ADDON_START v2 ${ADDON_ID} ${ADDON_VERSION} \"${name_b64}\" ${install_id} -->"
    local end_marker="<!-- ADDON_END ${install_id} -->"
    local wrapped="${start_marker}${inject}${end_marker}"

    # Read current index.html
    local index
    index="$(cat "$index_path")"

    # Remove existing addon with same ID (re-install)
    index="$(echo "$index" | perl -0pe "s/<!-- ADDON_START v\\d+ ${ADDON_ID} .*?<!-- ADDON_END[^>]*-->//gs")"

    # Inject before </body>
    index="${index//<\/body>/${wrapped}<\/body>}"

    # Write back
    echo "$index" > "$index_path"

    return 0
}

# ── Main ────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}  ================================================${NC}"
echo -e "${YELLOW}       313 SOUNDBOARD - LINUX ADDON INSTALLER${NC}"
echo -e "${BOLD}  ================================================${NC}"
echo ""

# Step 1: Find TeamSpeak
info "[1/2] Looking for TeamSpeak 6..."

TS_DIR=""
if [[ -n "${1:-}" ]]; then
    # User provided path
    if [[ -f "$1/html/client_ui/index.html" ]]; then
        TS_DIR="$1"
    else
        err "  No index.html found at: $1/html/client_ui/index.html"
        exit 1
    fi
else
    TS_DIR="$(find_teamspeak "" 2>/dev/null)" || true
fi

if [[ -z "$TS_DIR" ]]; then
    echo ""
    warn "  TeamSpeak 6 not found automatically."
    echo ""
    echo "  Common locations on Bazzite:"
    echo "    ~/TeamSpeak"
    echo "    ~/Applications/TeamSpeak"
    echo "    ~/.local/share/TeamSpeak"
    echo ""
    echo "  If you installed via Distrobox, run this script inside the container."
    echo ""
    read -rp "  Enter the path to your TeamSpeak 6 folder: " TS_DIR
    TS_DIR="${TS_DIR%/}"
    TS_DIR="${TS_DIR/#\~/$HOME}"

    if [[ ! -f "$TS_DIR/html/client_ui/index.html" ]]; then
        err "  Error: No index.html found at that location."
        exit 1
    fi
fi

ok "  Found: $TS_DIR"
echo ""

# Step 2: Inject addon
info "[2/2] Injecting 313 Soundboard addon..."

if inject_addon "$TS_DIR"; then
    ok "  Addon injected successfully!"
else
    err "  Injection failed."
    exit 1
fi

echo ""
echo -e "${BOLD}  ================================================${NC}"
echo -e "${GREEN}       INSTALLATION COMPLETE!${NC}"
echo -e "${BOLD}  ================================================${NC}"
echo ""
echo "  Restart TeamSpeak 6 to see the soundboard button."
echo "  Room code: 313"
echo ""
echo "  If the soundboard iframe doesn't load, you may need"
echo "  the binary patch. Install Java and run:"
echo "    java -jar TS6AddonInstaller-3.4.0-all.jar"
echo ""
