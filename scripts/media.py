#!/usr/bin/env python3
"""Write the active MPRIS player's state for lua/media.lua to draw.
Run by media.conf via ${execi 1}; prints nothing. Needs only busctl and curl.

State file (~/.cache/conky/media-state), one value per line:
    status (Playing/Paused/Stopped, empty = no player), title, artist,
    position (s), length (s; 0 = unknown, -1 = live stream), cover PNG path
    (may be empty), album

A lock makes overlapping calls (e.g. two conky instances) no-ops instead of
racing on the cover cache."""
import fcntl, hashlib, json, os, subprocess, urllib.parse

CACHE = os.path.expanduser("~/.cache/conky/covers")
ART = 220          # cover PNG size in px (drawn at 110: crisp on scaled screens)

def busctl(*args):
    try:
        out = subprocess.run(["busctl", "--user", "--json=short", *args],
                             capture_output=True, text=True, timeout=2)
        return json.loads(out.stdout) if out.returncode == 0 else None
    except Exception:
        return None

def prop(name, p):
    r = busctl("get-property", name, "/org/mpris/MediaPlayer2",
               "org.mpris.MediaPlayer2.Player", p)
    return r["data"] if r else None

def players():
    r = busctl("list")
    if not r:
        return []
    return [s["name"] for s in r if s.get("name", "").startswith("org.mpris.MediaPlayer2.")]

STATE = os.path.expanduser("~/.cache/conky/media-state")

def write_state(*fields):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    clean = [str(f or "").replace("\n", " ").strip() for f in fields]
    with open(STATE + ".tmp", "w") as f:
        f.write("\n".join(clean) + "\n")
    os.replace(STATE + ".tmp", STATE)

def cover(url):
    """Return a PNG of the cover, pre-scaled to ART x ART (cairo reads PNG natively)."""
    if not url:
        return None
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, hashlib.md5(url.encode()).hexdigest() + ".png")
    if os.path.isfile(path):
        return path
    for f in os.listdir(CACHE):              # new track: keep the cache tiny
        os.remove(os.path.join(CACHE, f))
    if url.startswith("file://"):
        src = urllib.parse.unquote(url[7:])
    else:
        # download to a temp file so a failed download is simply retried next update
        src = path + ".part"
        r = subprocess.run(["curl", "-sfL", "--max-time", "5", "-o", src, url])
        if r.returncode != 0:
            if os.path.exists(src):
                os.remove(src)
            return None
    try:
        from PIL import Image
        with Image.open(src) as im:
            im.convert("RGB").resize((ART, ART), Image.LANCZOS).save(path + ".tmp", "PNG")
        os.replace(path + ".tmp", path)
    except Exception:
        return None
    finally:
        if src.endswith(".part") and os.path.exists(src):
            os.remove(src)
    return path

def main():
    found = []
    for name in players():
        status = prop(name, "PlaybackStatus")
        if status:
            found.append((name, status))
    if not found:
        write_state("")                      # no player: lua/media.lua draws nothing
        return
    # prefer a playing player, then paused, then anything
    order = {"Playing": 0, "Paused": 1}
    name, status = sorted(found, key=lambda x: order.get(x[1], 2))[0]
    md = prop(name, "Metadata") or {}
    get = lambda k: (md.get(k) or {}).get("data")
    artist = get("xesam:artist") or ""
    if isinstance(artist, list):
        artist = ", ".join(artist)
    raw_len = get("mpris:length") or 0
    # Browsers report live streams (Twitch, YouTube live) with INT64_MAX as the
    # length; anything over ~30 days is treated as "live", not a real duration.
    if raw_len >= 30 * 86400 * 1e6:
        length = -1
    else:
        length = max(0, raw_len) / 1e6
    pos = (prop(name, "Position") or 0) / 1e6
    write_state(status, get("xesam:title") or "Unknown title", artist,
                f"{pos:.1f}", f"{length:.1f}", cover(get("mpris:artUrl")),
                get("xesam:album") or "")

os.makedirs(os.path.dirname(STATE), exist_ok=True)
with open(STATE + ".lock", "w") as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit   # the other widget is updating the state right now
    main()
