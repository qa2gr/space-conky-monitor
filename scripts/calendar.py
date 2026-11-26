#!/usr/bin/env python3
"""
Prints the next calendar events for lua/calendar.lua.

The events come from KDE's Akonadi database (the local copy of the Infomaniak
CalDAV calendars that Akonadi keeps in sync), read through its MariaDB socket:
no network access and no password needed. Recurring events are expanded
(RRULE, RDATE, EXDATE, moved or cancelled occurrences).

Output, one line each:
  ts 1795650000                                   (when this was made)
  <start> <end> <allday 0|1> <#rrggbb> <title>    (tab-separated, epoch seconds)

calendar.conf runs it every 60 s and saves the output to ~/.cache/conky/calendar.
Prints nothing if Akonadi can't be read, so the widget keeps the last data.
"""

import os
import re
import subprocess
import sys
import time
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from dateutil.rrule import rrulestr

DAYS = 60          # how far ahead to look
MAX_EVENTS = 12    # the widget shows fewer; a few spare
SOCKET = f"/run/user/{os.getuid()}/akonadi/mysql.socket"
EMOJI = re.compile("[\U0001F000-\U0001FAFF\u2600-\u27BF\uFE0F\u200D]")
def local_zone():
    """The system time zone, from $TZ or /etc/localtime (UTC if neither)."""
    name = os.environ.get("TZ", "").lstrip(":")
    if not name:
        link = os.path.realpath("/etc/localtime")
        name = link.split("zoneinfo/", 1)[1] if "zoneinfo/" in link else "UTC"
    try:
        return ZoneInfo(name)
    except Exception:
        return ZoneInfo("UTC")


LOCAL = local_zone()


def query(sql):
    out = subprocess.run(["mariadb", "-S", SOCKET, "akonadi", "-B", "-N", "-e", sql],
                         capture_output=True, text=True, timeout=10, check=True).stdout
    return [line.split("\t") for line in out.splitlines()]


def calendars():
    """{collection id: (name, colour)} for every event collection."""
    cols = {}
    for cid, in query("select r.Collection_id from collectionmimetyperelation r "
                      "join mimetypetable m on m.id = r.MimeType_id "
                      "where m.name = 'application/x-vnd.akonadi.calendar.event'"):
        cols[cid] = ["", "#7aa2f7"]
    if not cols:
        return cols
    ids = ",".join(cols)
    for cid, typ, value in query("select collectionId, type, value from collectionattributetable "
                                 f"where collectionId in ({ids}) and type in ('ENTITYDISPLAY','collectioncolor')"):
        if typ == "collectioncolor" and re.fullmatch(r"#[0-9a-fA-F]{8}", value):
            cols[cid][1] = "#" + value[3:]          # #aarrggbb -> #rrggbb
        elif typ == "ENTITYDISPLAY":
            m = re.match(r'\("((?:[^"\\]|\\.)*)"', value)
            if m:
                cols[cid][0] = m.group(1)
    return cols


# ---------------------------------------------------------------- iCalendar
def unfold(text):
    return re.sub(r"\r?\n[ \t]", "", text).splitlines()


def parse_prop(line):
    """'DTSTART;TZID=Europe/Paris:2025...' -> ('DTSTART', {'TZID': ...}, '2025...')"""
    head, _, value = line.partition(":")
    name, *params = head.split(";")
    pd = {}
    for p in params:
        k, _, v = p.partition("=")
        pd[k.upper()] = v.strip('"')
    return name.upper(), pd, value


def unescape(v):
    return re.sub(r"\\([\\;,nN])", lambda m: "\n" if m.group(1) in "nN" else m.group(1), v)


def parse_dt(value, params):
    """-> (naive datetime in tz, tz, allday)"""
    value = value.strip()
    if params.get("VALUE") == "DATE" or re.fullmatch(r"\d{8}", value):
        d = datetime.strptime(value[:8], "%Y%m%d")
        return d, LOCAL, True
    d = datetime.strptime(value[:15], "%Y%m%dT%H%M%S")
    if value.endswith("Z"):
        return d.replace(tzinfo=ZoneInfo("UTC")).astimezone(LOCAL).replace(tzinfo=None), LOCAL, False
    tzid = params.get("TZID")
    try:
        tz = ZoneInfo(tzid) if tzid else LOCAL
    except Exception:
        tz = LOCAL
    return d, tz, False


def to_tz(naive, src, dst):
    return naive.replace(tzinfo=src).astimezone(dst).replace(tzinfo=None)


def parse_duration(v):
    m = re.fullmatch(r"([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?", v.strip())
    if not m:
        return timedelta(0)
    sign, w, d, h, mi, s = m.groups()
    td = timedelta(weeks=int(w or 0), days=int(d or 0), hours=int(h or 0), minutes=int(mi or 0), seconds=int(s or 0))
    return -td if sign == "-" else td


def vevents(ical):
    """Yields each VEVENT as a list of (name, params, value)."""
    cur, depth = None, 0
    for line in unfold(ical):
        if line == "BEGIN:VEVENT":
            cur, depth = [], 0
        elif line == "END:VEVENT" and cur is not None:
            yield cur
            cur = None
        elif cur is not None:
            if line.startswith("BEGIN:"):
                depth += 1          # VALARM inside the event: skip its properties
            elif line.startswith("END:"):
                depth -= 1
            elif depth == 0:
                cur.append(parse_prop(line))


def occurrences(props, start, end):
    """(start, end, allday) epoch pairs of one VEVENT (master) within start..end."""
    get = lambda n: next(((p, v) for k, p, v in props if k == n), None)
    ds = get("DTSTART")
    if not ds:
        return []
    dtstart, tz, allday = parse_dt(ds[1], ds[0])
    de, du = get("DTEND"), get("DURATION")
    if de:
        dend, dtz, _ = parse_dt(de[1], de[0])
        dur = to_tz(dend, dtz, tz) - dtstart
    elif du:
        dur = parse_duration(du[1])
    else:
        dur = timedelta(days=1) if allday else timedelta(0)

    # window in the event's own wall-clock time
    lo = to_tz(datetime.fromtimestamp(start), LOCAL, tz) - dur - timedelta(days=1)
    hi = to_tz(datetime.fromtimestamp(end), LOCAL, tz) + timedelta(days=1)

    rules = [v for k, p, v in props if k == "RRULE"]
    if rules:
        starts = []
        for r in rules:
            # UNTIL must match DTSTART's kind (naive here): bring a UTC UNTIL
            # into the event's time zone, a date-only one to the end of that day
            def fix(m):
                u = m.group(1)
                if u.endswith("Z"):
                    d = to_tz(datetime.strptime(u[:15], "%Y%m%dT%H%M%S"), ZoneInfo("UTC"), tz)
                elif len(u) == 8:
                    d = datetime.strptime(u, "%Y%m%d") + timedelta(hours=23, minutes=59, seconds=59)
                else:
                    d = datetime.strptime(u[:15], "%Y%m%dT%H%M%S")
                return "UNTIL=" + d.strftime("%Y%m%dT%H%M%S")
            r = re.sub(r"UNTIL=([0-9TZ]+)", fix, r)
            try:
                starts += rrulestr(r, dtstart=dtstart).between(lo, hi, inc=True)
            except Exception:
                pass
    else:
        starts = [dtstart]
    for k, p, v in props:
        if k == "RDATE" and p.get("VALUE") != "PERIOD":
            for x in v.split(","):
                starts.append(to_tz(*parse_dt(x, p)[:2], tz))
    ex = set()
    for k, p, v in props:
        if k == "EXDATE":
            for x in v.split(","):
                d, xtz, xall = parse_dt(x, p)
                ex.add(d.date() if xall else to_tz(d, xtz, tz))
    out = []
    for s in sorted(set(starts)):
        if s in ex or (allday and s.date() in ex):
            continue
        out.append(s)
    return [(s, s + dur, tz, allday) for s in out]


def epoch(naive, tz):
    return int(naive.replace(tzinfo=tz).timestamp())


def main():
    now = int(time.time())
    end = now + DAYS * 86400
    try:
        cols = calendars()
        if not cols:
            return
        ids = ",".join(cols)
        rows = query("select i.collectionId, hex(p.data) from parttable p "
                     "join pimitemtable i on i.id = p.pimItemId "
                     "join parttypetable t on t.id = p.partTypeId "
                     f"where i.collectionId in ({ids}) and t.ns = 'PLD' and t.name = 'RFC822'")
    except Exception as e:
        print(f"calendar.py: {e}", file=sys.stderr)
        return

    # Akonadi stores a moved / changed occurrence as an item of its own,
    # sharing the UID of the recurring event: gather everything first.
    masters, overrides = [], []
    for cid, hexdata in rows:
        try:
            ical = bytes.fromhex(hexdata).decode("utf-8", "replace")
        except ValueError:
            continue
        for props in vevents(ical):
            uid = next((v for k, _, v in props if k == "UID"), None)
            is_override = any(k == "RECURRENCE-ID" for k, _, _ in props)
            (overrides if is_override else masters).append((cid, uid, props))

    # occurrences replaced by an override (moved, changed or cancelled)
    replaced = set()
    for _, uid, props in overrides:
        rid = next((p, v) for k, p, v in props if k == "RECURRENCE-ID")
        d, tz, _ = parse_dt(rid[1], rid[0])
        replaced.add((uid, epoch(d, tz)))

    events = []
    for kind, items in (("master", masters), ("override", overrides)):
        for cid, uid, props in items:
            if any(k == "STATUS" and v.upper() == "CANCELLED" for k, _, v in props):
                continue
            title = unescape(next((v for k, _, v in props if k == "SUMMARY"), "(no title)"))
            for s, e, tz, allday in occurrences(props, now, end):
                if kind == "master" and (uid, epoch(s, tz)) in replaced:
                    continue
                if allday:     # all-day: local midnight to midnight
                    se, ee = epoch(s, LOCAL), epoch(e, LOCAL)
                else:
                    se, ee = epoch(s, tz), epoch(e, tz)
                if (ee > now or (ee == se and se >= now)) and se < end:
                    events.append((se, ee, allday, cols[cid][1], title))

    events.sort(key=lambda ev: (ev[0], not ev[2], ev[4]))
    print(f"ts {now}")
    for se, ee, allday, color, title in events[:MAX_EVENTS]:
        # cairo's toy text API can't draw emoji (e.g. the holiday calendar's flag)
        title = " ".join(EMOJI.sub("", title).split()) or "(no title)"
        print(f"{se}\t{ee}\t{int(allday)}\t{color}\t{title}")


if __name__ == "__main__":
    main()
