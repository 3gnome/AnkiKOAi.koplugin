#!/bin/bash
# Launch KOReader with this plugin, in one of two modes:
#
#   appimage  - Launch a stable KOReader AppImage directly. No plugin syncing,
#               no emulator tree, no ./luajit reader.lua. This is the DEFAULT on
#               WSL because the dev emulator under WSLg can trigger external
#               window/COPY_MODE issues ("[WARN: COPY MODE]" / "WARNING COPY MODE").
#   emulator  - Sync this plugin into the KOReader dev emulator tree and launch
#               ./luajit reader.lua. This is the DEFAULT off WSL.
#
# Usage:
#   bash start.sh                       # default mode, file manager
#   bash start.sh alice.epub            # default mode, open a book (relative to repo)
#   bash start.sh /abs/path/book.epub   # default mode, absolute book path
#   bash start.sh --appimage alice.epub # force AppImage mode
#   bash start.sh --emulator alice.epub # force emulator mode
#   bash start.sh -h | --help           # show help
#
# Environment overrides:
#   KOREADER_MODE      - appimage | emulator (overrides auto-detected default)
#   KOREADER_APPIMAGE  - path to a KOReader AppImage (appimage mode)
#   KOREADER_DIR       - emulator koreader root (default: ~/koreader-dev/emulator/usr/lib/koreader)
#   PLUGIN_DIR         - this plugin source (default: directory containing this script)
#   PLUGIN_DST         - where to rsync the plugin in the emulator tree

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KOREADER="${KOREADER_DIR:-$HOME/koreader-dev/emulator/usr/lib/koreader}"
PLUGIN_SRC="${PLUGIN_DIR:-$SCRIPT_DIR}"
PLUGIN_DST="${PLUGIN_DST:-$HOME/koreader-dev/plugins/AnkiKOAi.koplugin}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_wsl() {
    # Detect WSL/WSLg via the WSLg mount, the distro env var, or kernel version.
    if [ -d /mnt/wslg ]; then
        return 0
    fi
    if [ -n "${WSL_DISTRO_NAME:-}" ]; then
        return 0
    fi
    if [ -r /proc/version ] && grep -qiE 'microsoft|wsl' /proc/version; then
        return 0
    fi
    return 1
}

resolve_book() {
    # Resolve a (possibly relative) book path against the script directory.
    # Prints the resolved path on stdout. Empty input -> empty output.
    local book="${1:-}"
    if [ -z "$book" ]; then
        return 0
    fi
    if [ "${book:0:1}" != "/" ]; then
        book="$SCRIPT_DIR/$book"
    fi
    printf '%s' "$book"
}

find_appimage() {
    # Locate a KOReader AppImage. Prints the path on stdout, or nothing if none.
    #   1. KOREADER_APPIMAGE if set
    #   2. otherwise newest ~/Downloads/koreader-appimage-*.AppImage
    if [ -n "${KOREADER_APPIMAGE:-}" ]; then
        printf '%s' "$KOREADER_APPIMAGE"
        return 0
    fi

    local candidate
    candidate="$(ls -t "$HOME"/Downloads/koreader-appimage-*.AppImage 2>/dev/null | head -n 1 || true)"
    if [ -n "$candidate" ]; then
        printf '%s' "$candidate"
    fi
}

sync_plugin_to_emulator() {
    # Mirror the plugin source into the emulator plugin tree and symlink it in.
    if [ ! -d "$PLUGIN_SRC" ]; then
        echo "ERROR: Plugin source not found at: $PLUGIN_SRC" >&2
        echo "Set PLUGIN_DIR to this plugin's directory." >&2
        exit 1
    fi

    mkdir -p "$PLUGIN_DST"
    rsync -a --delete "$PLUGIN_SRC/" "$PLUGIN_DST/" \
        --exclude '.git' \
        --exclude 'koreader.log' \
        --exclude 'configuration.lua'

    if [ -f "$PLUGIN_SRC/configuration.lua" ]; then
        cp "$PLUGIN_SRC/configuration.lua" "$PLUGIN_DST/"
    elif [ -f "$PLUGIN_SRC/configuration.lua.sample" ]; then
        cp "$PLUGIN_SRC/configuration.lua.sample" "$PLUGIN_DST/configuration.lua"
    fi

    local emulator_plugins="$KOREADER/plugins"
    if [ -d "$emulator_plugins" ]; then
        ln -sfn "$PLUGIN_DST" "$emulator_plugins/AnkiKOAi.koplugin"
    fi
}

launch_appimage() {
    # Launch a KOReader AppImage directly, optionally with a book.
    local book="${1:-}"

    local appimage
    appimage="$(find_appimage)"
    if [ -z "$appimage" ] || [ ! -f "$appimage" ]; then
        echo "ERROR: No KOReader AppImage found." >&2
        echo "Set KOREADER_APPIMAGE=/path/to/koreader.AppImage, or place a file" >&2
        echo "matching ~/Downloads/koreader-appimage-*.AppImage" >&2
        exit 1
    fi

    if [ ! -x "$appimage" ]; then
        chmod +x "$appimage" || true
    fi

    echo "Launching AppImage: $appimage" >&2
    if [ -n "$book" ] && [ -e "$book" ]; then
        exec "$appimage" "$book"
    else
        exec "$appimage"
    fi
}

launch_emulator() {
    # Sync the plugin and launch the KOReader dev emulator (./luajit reader.lua).
    local book="${1:-}"

    if [ ! -d "$KOREADER" ]; then
        echo "ERROR: KOReader emulator not found at: $KOREADER" >&2
        echo "Set KOREADER_DIR to your emulator install." >&2
        exit 1
    fi

    sync_plugin_to_emulator

    cd "$KOREADER"
    export LD_LIBRARY_PATH="./libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    # WSLg: the dev emulator under WSLg can trigger external COPY_MODE window
    # issues ("[WARN: COPY MODE]"). AppImage mode is recommended (and default)
    # on WSL. If you really want the emulator here, force software rendering so
    # ZINK doesn't fail silently and leave you with no window.
    if is_wsl; then
        export DISPLAY="${DISPLAY:-:0}"
        export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/mnt/wslg/runtime-dir}"
        export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
        export MESA_LOADER_DRIVER_OVERRIDE="${MESA_LOADER_DRIVER_OVERRIDE:-llvmpipe}"
        export SDL_RENDER_DRIVER="${SDL_RENDER_DRIVER:-software}"
    fi

    # Avoid a headless zombie if a previous launch left reader.lua running.
    pkill -f './luajit reader.lua' 2>/dev/null || true
    sleep 0.5

    if [ -n "$book" ] && [ -e "$book" ]; then
        exec ./luajit reader.lua "$book"
    else
        exec ./luajit reader.lua
    fi
}

print_help() {
    cat <<'EOF'
start.sh - Launch KOReader with the AnkiKOAi plugin

MODES
  appimage   Launch a stable KOReader AppImage directly. No plugin syncing and
             no dev emulator. DEFAULT on WSL, because launching the dev emulator
             under WSLg can trigger external window / COPY_MODE issues
             ("[WARN: COPY MODE]" / "WARNING COPY MODE").
  emulator   Sync this plugin into the KOReader dev emulator tree and launch it
             via ./luajit reader.lua. DEFAULT off WSL.

USAGE
  bash start.sh [--appimage | --emulator] [book]
  bash start.sh -h | --help

OPTIONS
  --appimage        Force AppImage mode.
  --emulator        Force emulator mode.
  book              Book to open. Relative paths resolve against this repo.

ENVIRONMENT
  KOREADER_MODE      appimage | emulator (overrides the auto-detected default)
  KOREADER_APPIMAGE  Path to a KOReader AppImage (appimage mode)
  KOREADER_DIR       Emulator koreader root
                     (default: ~/koreader-dev/emulator/usr/lib/koreader)
  PLUGIN_DIR         This plugin source (default: this script's directory)
  PLUGIN_DST         Where to rsync the plugin in the emulator tree

EXAMPLES
  bash start.sh                          # default mode (AppImage on WSL)
  bash start.sh alice.epub               # default mode, open a book
  bash start.sh /abs/path/to/book.epub   # default mode, absolute path
  bash start.sh --appimage alice.epub    # force AppImage mode
  bash start.sh --emulator alice.epub    # force emulator mode
  KOREADER_APPIMAGE=~/koreader.AppImage bash start.sh --appimage
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

MODE=""
BOOK_ARG=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        --appimage)
            MODE="appimage"
            shift
            ;;
        --emulator)
            MODE="emulator"
            shift
            ;;
        --)
            shift
            if [ "$#" -gt 0 ]; then
                BOOK_ARG="$1"
                shift
            fi
            ;;
        *)
            BOOK_ARG="$1"
            shift
            ;;
    esac
done

# Mode precedence: CLI flag > KOREADER_MODE env > auto-detected default.
if [ -z "$MODE" ] && [ -n "${KOREADER_MODE:-}" ]; then
    MODE="$KOREADER_MODE"
fi

if [ -z "$MODE" ]; then
    if is_wsl; then
        MODE="appimage"
    else
        MODE="emulator"
    fi
fi

# ---------------------------------------------------------------------------
# Resolve book and dispatch
# ---------------------------------------------------------------------------

BOOK="$(resolve_book "$BOOK_ARG")"
if [ -n "$BOOK" ] && [ ! -e "$BOOK" ]; then
    echo "WARNING: Book not found: $BOOK -- launching without a book." >&2
    BOOK=""
fi

case "$MODE" in
    appimage)
        launch_appimage "$BOOK"
        ;;
    emulator)
        launch_emulator "$BOOK"
        ;;
    *)
        echo "ERROR: Unknown mode: $MODE (expected 'appimage' or 'emulator')." >&2
        exit 1
        ;;
esac
