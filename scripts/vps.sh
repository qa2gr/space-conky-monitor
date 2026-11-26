#!/bin/sh
# Prints the Tailscale ping of each VPS, one line per machine, in this order:
#   apollo up 3
#   gemini up 28
#   soyuz down -
# (NAME, up/down, latency in ms or - when it doesn't answer within 5 s)
#
# vps.conf runs it every 30 s and saves the output to
# ~/.cache/conky/vps-status for lua/vps.lua to draw.

# Hosts from VPS_HOSTS in .env
ENV="$(dirname "$0")/../.env"
[ -f "$ENV" ] && . "$ENV"
HOSTS="$VPS_HOSTS"

tmp=$(mktemp -d)
for h in $HOSTS; do
    # all machines at once, one ping each, so a slow one doesn't hold up the rest
    (
        ms=$(tailscale ping -c 1 --timeout 5s "$h" 2>/dev/null |
             sed -n 's/^pong from .* in \([0-9.]*\)ms.*/\1/p' | head -n 1)
        if [ -n "$ms" ]; then printf '%s up %.0f\n' "$h" "$ms"
        else printf '%s down -\n' "$h"; fi
    ) > "$tmp/$h" &
done
wait
for h in $HOSTS; do cat "$tmp/$h"; done
rm -rf "$tmp"
