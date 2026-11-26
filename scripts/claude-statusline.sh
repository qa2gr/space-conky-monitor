#!/bin/sh
# Claude Code statusline: caches rate-limit data for conky, prints a short status.
input=$(cat)
cache="$HOME/.cache/claude-usage.json"
# Only overwrite the cache when this payload actually carries rate limits
if printf '%s' "$input" | jq -e '.rate_limits' >/dev/null 2>&1; then
  printf '%s' "$input" | jq -c '{rate_limits, ts: now}' > "$cache.tmp" && mv "$cache.tmp" "$cache"
fi
printf '%s' "$input" | jq -r '
  def pct(x): if x == null then "-" else "\(x | floor)%" end;
  "\(.model.display_name // "Claude") · 5h \(pct(.rate_limits.five_hour.used_percentage)) · 7d \(pct(.rate_limits.seven_day.used_percentage))"'
