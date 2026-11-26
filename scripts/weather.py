#!/usr/bin/env python3
"""
Conky-Mirage helper, reduced to the forecast for the "Next 24 hours" box.

lua/weather.lua runs this as a one-shot every few seconds, detached, with every
setting on the command line. When the forecast is older than the refresh
interval it fetches a new one from Open-Meteo, which needs no API key, writes
it to the cache directory as a Lua table, and bumps `serial` so the widget
knows to reload. A run with nothing to do costs a few milliseconds.

Standard library only. The full version is Conky Mirage in https://github.com/alexsson-xexpanderx/Conky-themes
"""

import argparse
import fcntl
import json
import math
import os
import re
import sys
import time

USER_AGENT = "conky-mirage/1.0 (+https://github.com/alexsson-xexpanderx/Conky-themes)"


# --------------------------------------------------------------------------
# small utilities
# --------------------------------------------------------------------------

def log(cache, message):
    """Append to weather.log, keeping it from growing without bound."""
    path = os.path.join(cache, "weather.log")
    try:
        if os.path.getsize(path) > 200_000:
            os.replace(path, path + ".old")
    except OSError:
        pass
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(time.strftime("%Y-%m-%d %H:%M:%S ") + message.rstrip() + "\n")


def write_atomically(path, data):
    """Write via a temporary file and rename, so the widget never reads half a file."""
    tmp = path + ".tmp"
    mode = "wb" if isinstance(data, bytes) else "w"
    with open(tmp, mode, **({} if mode == "wb" else {"encoding": "utf-8"})) as handle:
        handle.write(data)
    os.replace(tmp, path)


IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def lua_string(text):
    out = []
    for ch in text:
        if ch in '"\\':
            out.append("\\" + ch)
        elif ord(ch) < 32 or ord(ch) == 127:
            out.append("\\%03d" % ord(ch))
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def lua_value(value):
    """Serialise to a Lua literal. Strings come from web APIs, so escape fully."""
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if math.isnan(value) or math.isinf(value):
            return "0"
        return repr(round(value, 5))
    if isinstance(value, str):
        return lua_string(value)
    if isinstance(value, (list, tuple)):
        return "{" + ", ".join(lua_value(v) for v in value) + "}"
    if isinstance(value, dict):
        parts = []
        for key, item in value.items():
            if item is None:
                continue
            name = key if IDENTIFIER.match(str(key)) else "[" + lua_string(str(key)) + "]"
            parts.append(name + " = " + lua_value(item))
        return "{" + ", ".join(parts) + "}"
    raise TypeError(type(value))


def bump_serial(cache):
    path = os.path.join(cache, "serial")
    try:
        with open(path, encoding="utf-8") as handle:
            serial = int(handle.read().strip() or 0)
    except (OSError, ValueError):
        serial = 0
    write_atomically(path, str(serial + 1) + "\n")


def load_state(cache):
    try:
        with open(os.path.join(cache, "state.json"), encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def save_state(cache, state):
    write_atomically(os.path.join(cache, "state.json"), json.dumps(state, indent=1))


# --------------------------------------------------------------------------
# weather
# --------------------------------------------------------------------------

WMO = {
    0: ("Clear", "clear", 0), 1: ("Mostly clear", "few", 0), 2: ("Partly cloudy", "partly", 0),
    3: ("Overcast", "cloudy", 0), 45: ("Fog", "fog", 0), 48: ("Freezing fog", "fog", 0),
    51: ("Light drizzle", "drizzle", 1), 53: ("Drizzle", "drizzle", 2), 55: ("Heavy drizzle", "drizzle", 3),
    56: ("Freezing drizzle", "sleet", 1), 57: ("Freezing drizzle", "sleet", 2),
    61: ("Light rain", "rain", 1), 63: ("Rain", "rain", 2), 65: ("Heavy rain", "rain", 3),
    66: ("Freezing rain", "sleet", 2), 67: ("Freezing rain", "sleet", 3),
    71: ("Light snow", "snow", 1), 73: ("Snow", "snow", 2), 75: ("Heavy snow", "snow", 3),
    77: ("Snow grains", "snow", 1), 80: ("Light showers", "showers", 1), 81: ("Showers", "showers", 2),
    82: ("Heavy showers", "showers", 3), 85: ("Snow showers", "snow", 2), 86: ("Heavy snow showers", "snow", 3),
    95: ("Thunderstorm", "thunder", 2), 96: ("Thunderstorm with hail", "thunder", 3),
    99: ("Thunderstorm with hail", "thunder", 3),
}
WET_KINDS = {"drizzle": "Drizzle", "rain": "Rain", "showers": "Showers", "sleet": "Sleet",
             "snow": "Snow", "thunder": "Thunderstorms"}


def describe(code):
    return WMO.get(int(code or 0), ("Unknown", "cloudy", 0))


def fetch_json(url, timeout=15):
    # Imported here: urllib.request pulls in ssl, which costs more than the
    # whole of a run that has nothing to fetch.
    import urllib.request
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def urlencode(query):
    from urllib.parse import urlencode as encode
    return encode(query)


def locate(spec, state):
    """Resolve the location setting to coordinates, caching the answer."""
    spec = (spec or "auto").strip()
    cached = state.get("location")
    if cached and cached.get("spec") == spec and \
            (spec != "auto" or time.time() - cached.get("time", 0) < 6 * 3600):
        return cached

    place = None
    m = re.fullmatch(r"\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*(?:,\s*(.+))?", spec)
    if m:
        place = {"lat": float(m.group(1)), "lon": float(m.group(2)), "name": (m.group(3) or "").strip(),
                 "country": ""}
        if not place["name"]:
            try:
                data = fetch_json("https://api.bigdatacloud.net/data/reverse-geocode-client?" +
                                  urlencode({"latitude": place["lat"], "longitude": place["lon"],
                                                          "localityLanguage": "en"}))
                place["name"] = data.get("city") or data.get("locality") or ""
                place["country"] = data.get("countryCode", "")
            except Exception:
                pass
    elif spec.lower() == "auto":
        for url, parse in (
                ("https://ipinfo.io/json", lambda d: (*d["loc"].split(","), d.get("city"), d.get("country"))),
                ("https://ipapi.co/json/", lambda d: (d["latitude"], d["longitude"], d.get("city"),
                                                      d.get("country_code"))),
                ("http://ip-api.com/json/", lambda d: (d["lat"], d["lon"], d.get("city"), d.get("countryCode")))):
            try:
                lat, lon, city, country = parse(fetch_json(url, timeout=8))
                place = {"lat": float(lat), "lon": float(lon), "name": city or "", "country": country or ""}
                break
            except Exception:
                continue
    else:
        name, _, country = spec.partition(",")
        data = fetch_json("https://geocoding-api.open-meteo.com/v1/search?" +
                          urlencode({"name": name.strip(), "count": 10, "language": "en"}))
        results = data.get("results") or []
        country = country.strip().upper()
        if country:
            results = [r for r in results if r.get("country_code", "").upper() == country or
                       r.get("country", "").upper() == country] or results
        if results:
            r = results[0]
            place = {"lat": r["latitude"], "lon": r["longitude"], "name": r.get("name", name),
                     "country": r.get("country_code", "")}
    if place is None:
        if cached:
            return cached
        raise RuntimeError("could not resolve location %r" % spec)
    place.update({"spec": spec, "time": time.time()})
    state["location"] = place
    return place


TWELVE_HOUR = False


def clock_text(epoch, offset):
    moment = time.gmtime(epoch + offset)
    if TWELVE_HOUR:
        return "%d:%s" % (int(time.strftime("%I", moment)), time.strftime("%M %p", moment).lower())
    return time.strftime("%H:%M", moment)


def summarize(current, hours, minutely, offset, units, now, unit=""):
    """One plain sentence about the next day, the way a person would put it."""
    wet_threshold = 0.012 if units == "imperial" else 0.3
    current_kind = describe(current["code"])[1]
    raining = current_kind in WET_KINDS or current.get("precip", 0) > 0
    clauses = []

    if minutely:
        if raining:
            for t, p in minutely:
                if t > now and p <= 0.0 and all(q <= 0.0 for tt, q in minutely if tt >= t):
                    clauses.append("%s stopping around %s" % (WET_KINDS.get(current_kind, "Rain"),
                                                             clock_text(t, offset)))
                    break
        else:
            for t, p in minutely:
                if t > now and p > 0.05:
                    clauses.append("Rain starting around %s" % clock_text(t, offset))
                    break

    upcoming = [h for h in hours if h["t"] >= now - 1800][:24]
    if not clauses and upcoming:
        if raining:
            for h in upcoming:
                if h["pop"] < 30 and h["precip"] < wet_threshold / 3:
                    clauses.append("%s easing around %s" % (WET_KINDS.get(current_kind, "Rain"),
                                                           clock_text(h["t"], offset)))
                    break
            else:
                clauses.append("%s for most of the day" % WET_KINDS.get(current_kind, "Rain"))
        else:
            for h in upcoming[1:16]:
                if h["pop"] >= 50 or h["precip"] >= wet_threshold:
                    kind = describe(h["code"])[1]
                    clauses.append("%s likely around %s" % (WET_KINDS.get(kind, "Rain"),
                                                            clock_text(h["t"], offset)))
                    break
            else:
                if all(h["pop"] < 25 for h in upcoming):
                    clauses.append("Dry for the next 24 hours")

    if upcoming:
        day = upcoming[:14]
        warmest = max(day, key=lambda h: h["temp"])
        coolest = min(upcoming, key=lambda h: h["temp"])
        if warmest["t"] > now + 3600 and warmest["temp"] > current["temp"] + 1:
            clauses.append("High of %d°%s at %s" % (round(warmest["temp"]), unit, clock_text(warmest["t"], offset)))
        elif coolest["temp"] < current["temp"] - 1:
            hour = int(time.strftime("%H", time.gmtime(coolest["t"] + offset)))
            when = "tonight" if hour >= 18 or hour < 9 else "at " + clock_text(coolest["t"], offset)
            clauses.append("Low of %d°%s %s" % (round(coolest["temp"]), unit, when))
    return " · ".join(clauses[:2])


def weather_step(args, cache, state, force=False):
    now = time.time()
    key = [args.location, args.units, args.clock, args.show_unit]
    fresh = state.get("weather_key") == key and now - state.get("weather_time", 0) < args.interval * 60
    retry_at = state.get("weather_retry", 0)
    if fresh and not force and os.path.isfile(os.path.join(cache, "weather.lua")):
        return False
    if now < retry_at and not force and state.get("weather_key") == key:
        return False

    try:
        place = locate(args.location, state)
        imperial = args.units == "imperial"
        query = {
            "latitude": place["lat"], "longitude": place["lon"], "timezone": "auto",
            "timeformat": "unixtime", "forecast_days": 3,
            "current": "temperature_2m,is_day,precipitation,weather_code",
            "hourly": "temperature_2m,precipitation_probability,precipitation,weather_code,is_day",
            "minutely_15": "precipitation", "forecast_minutely_15": 8,
        }
        if imperial:
            query.update({"temperature_unit": "fahrenheit", "wind_speed_unit": "mph",
                          "precipitation_unit": "inch"})
        data = fetch_json("https://api.open-meteo.com/v1/forecast?" + urlencode(query))
        offset = int(data.get("utc_offset_seconds", 0))
        c = data["current"]

        def num(value, default=0.0):
            return default if value is None else float(value)

        current = {
            "temp": num(c.get("temperature_2m")), "code": int(num(c.get("weather_code"))),
            "is_day": int(num(c.get("is_day"), 1)), "precip": num(c.get("precipitation")),
            "time": int(num(c.get("time"), now)),
        }
        desc, kind, level = describe(current["code"])
        current.update({"desc": desc, "kind": kind, "level": level})

        h = data["hourly"]
        hours = []
        for i, t in enumerate(h["time"]):
            if t < now - 2 * 3600 or t > now + 50 * 3600:
                continue
            code = int(num(h["weather_code"][i]))
            d, k, lv = describe(code)
            hours.append({"t": int(t), "temp": num(h["temperature_2m"][i]),
                          "pop": num(h["precipitation_probability"][i]),
                          "precip": num(h["precipitation"][i]), "code": code, "kind": k, "level": lv,
                          "day": int(num(h["is_day"][i], 1))})

        minutely = []
        m15 = data.get("minutely_15") or {}
        for t, p in zip(m15.get("time") or [], m15.get("precipitation") or []):
            if p is not None:
                minutely.append((int(t), float(p)))

        weather = {
            "fetched": int(now), "place": place.get("name") or "", "country": place.get("country") or "",
            "lat": place["lat"], "lon": place["lon"], "tz_offset": offset,
            "imperial": imperial,
            "units": {"temp": "°F" if imperial else "°C", "wind": "mph" if imperial else "km/h",
                      "precip": "in" if imperial else "mm"},
            "current": current, "hourly": hours,
            "summary": summarize(current, hours, minutely, offset, args.units, now,
                                 ("F" if imperial else "C") if args.show_unit else ""),
        }
        write_atomically(os.path.join(cache, "weather.lua"), "return " + lua_value(weather) + "\n")
        state["weather_time"] = now
        state["weather_key"] = key
        state.pop("weather_retry", None)
        state.pop("weather_error", None)
        log(cache, "weather: %s %.1f%s %s" % (weather["place"], current["temp"],
                                              weather["units"]["temp"], desc))
        return True
    except Exception as error:   # network down, API change: keep the old data, retry soon
        state["weather_retry"] = now + 300
        state["weather_error"] = str(error)[:200]
        write_atomically(os.path.join(cache, "weather_error.lua"),
                         "return " + lua_value({"error": str(error)[:120], "time": int(now)}) + "\n")
        log(cache, "weather failed: %s" % error)
        return True


# --------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--cache", default=os.path.join(os.environ.get(
        "XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "conky", "weather"))
    parser.add_argument("--location", default="auto")
    parser.add_argument("--units", default="metric", choices=("metric", "imperial"))
    parser.add_argument("--interval", type=float, default=15, help="weather refresh, minutes")
    parser.add_argument("--clock", default="24h", choices=("24h", "12h"))
    parser.add_argument("--show-unit", action="store_true", help='"12°C" rather than "12°"')
    parser.add_argument("--force", action="store_true", help="fetch now, however fresh the forecast is")
    args = parser.parse_args()

    cache = os.path.expanduser(args.cache)
    os.makedirs(cache, exist_ok=True)
    global TWELVE_HOUR
    TWELVE_HOUR = args.clock == "12h"

    # One run at a time: a slow network must not let runs pile up.
    lock = open(os.path.join(cache, "lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0

    state = load_state(cache)
    changed = False
    try:
        changed = weather_step(args, cache, state, force=args.force)
    except Exception as error:
        log(cache, "error: %r" % error)
        raise
    finally:
        save_state(cache, state)
        if changed:
            bump_serial(cache)
    return 0


if __name__ == "__main__":
    sys.exit(main())
