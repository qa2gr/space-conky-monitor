#!/bin/sh
# Prints the status of the main self-hosted services, from an Uptime Kuma
# status page, for lua/services.lua:
#   ts 1795650000                     (when this was fetched, epoch seconds)
#   Nextcloud 1 476 0.9993            (name, status, ping ms, 24 h uptime 0-1)
# Status is Uptime Kuma's: 1 up, 0 down, 2 pending, 3 maintenance.
# A service missing from the page is printed with status -1.
# Prints nothing if the status page can't be reached (the widget then shows
# the data as stale once it is over 3 minutes old).
#
# services.conf runs it every 60 s and saves the output to ~/.cache/conky/services.

# Settings from .env: SERVICES_URL, SERVICES_PAGE, SERVICES_NAMES.
ENV="$(dirname "$0")/../.env"
[ -f "$ENV" ] && . "$ENV"
[ -n "$SERVICES_URL" ] || exit 0
BASE="${SERVICES_URL%/}/api/status-page"
PAGE="${SERVICES_PAGE:-main}"
SERVICES="$SERVICES_NAMES"

page=$(curl -sf --max-time 10 "$BASE/$PAGE") || exit 0
beats=$(curl -sf --max-time 10 "$BASE/heartbeat/$PAGE") || exit 0

echo "ts $(date +%s)"
for name in $SERVICES; do
    printf '%s\n%s\n' "$page" "$beats" | jq -rs --arg name "$name" '
        .[0] as $page | .[1] as $hb
        | ([$page.publicGroupList[].monitorList[]
            | select(.name | ascii_downcase == ($name | ascii_downcase)) | .id] | first) as $id
        | if $id == null then "\($name) -1 - -"
          else ($hb.heartbeatList[($id | tostring)] // [] | last) as $last
          | "\($name) \($last.status // -1) \($last.ping // "-") \($hb.uptimeList["\($id)_24"] // "-")"
          end'
done
