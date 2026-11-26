#!/usr/bin/env bash
# Start all conky widgets:
#   system.conf   - system monitor (left, 2nd monitor)
#   claude.conf   - Claude usage arcs fitted to the wallpaper's round window (2nd monitor)
#   media.conf    - media player fitted to the wallpaper's round window (2nd monitor)
#   vps.conf      - VPS status as a constellation in the round window (2nd monitor)
#   services.conf - self-hosted services status (top-right, 2nd monitor)
#   calendar.conf - next calendar events (bottom-right, above weather, 2nd monitor)
#   weather.conf  - weather (bottom-right, 2nd monitor)
# Shared by all of them: base.conf (window settings) and lua/theme.lua (fonts,
# palette, sizes, helpers). Conky doesn't notice edits to those two, so re-run
# this script after changing them.
# Safe to re-run: any running instances are stopped first.
#
# The media widget is drawn entirely by lua/media.lua (cairo), not by
# ${image}/Imlib2, so no LD_PRELOAD workaround is needed.

DIR="$HOME/.config/conky"
# Settings (CONKY_BIN...) from .env; see .env.default
[ -f "$DIR/.env" ] && . "$DIR/.env"
CONKY="${CONKY_BIN:-$(command -v conky)}"
[ -x "$CONKY" ] || { echo "conky not found: set CONKY_BIN in $DIR/.env" >&2; exit 1; }

# Stop instances started from the AppImage (anchored so this script isn't matched)
pkill -f "^$CONKY" && sleep 1

# When run from autostart, give the session/XWayland a moment to settle
[[ "$1" == "--delay" ]] && sleep 5

"$CONKY" -c "$DIR/system.conf"
"$CONKY" -c "$DIR/claude.conf"
"$CONKY" -c "$DIR/media.conf"
"$CONKY" -c "$DIR/vps.conf"
"$CONKY" -c "$DIR/calendar.conf"
"$CONKY" -c "$DIR/services.conf"
"$CONKY" -c "$DIR/weather.conf"
