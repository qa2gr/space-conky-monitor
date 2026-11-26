--[[ ==========================================================================
  Conky-Mirage, reduced to the next-24-hours forecast.

  Draws the temperature curve, rain chances, icons and a one-line summary
  for the next 24 hours, straight onto conky's transparent window. scripts/weather.py
  (run detached every few seconds) fetches the forecast from Open-Meteo,
  which needs no API key, and leaves it in the cache; this script paints it.

  The full widget is Conky Mirage in https://github.com/alexsson-xexpanderx/Conky-themes

  Start with:   conky -c ~/.config/conky/weather.conf
============================================================================ ]]

-- Shared fonts, palette and helpers (see lua/theme.lua)
local T = dofile(os.getenv('HOME') .. '/.config/conky/lua/theme.lua')

---------------- USER CONFIGURATION ----------------

-- Where to get the weather for. "auto" finds it from your internet
-- connection. Or write a city ("Cluj-Napoca"), a city and country
-- ("Paris, FR"), or coordinates ("46.77, 23.59, Home").
-- Set with WEATHER_LOCATION and WEATHER_UNITS in .env.
location = T.env.WEATHER_LOCATION or "auto"

units = T.env.WEATHER_UNITS or "metric"   -- "metric" (°C, km/h) or "imperial" (°F, mph)
show_temperature_unit = "Yes"    -- "Yes" shows 10°C, "No" shows 10°
weather_refresh_minutes = 15     -- how often to get a new forecast

clock_format = "24h"             -- "24h" or "12h"

-- Fonts: the shared ones from lua/theme.lua. Any installed font works.
font_regular = T.font
font_medium  = T.font_medium

-- Sizes. If you change text_size or widget_width, update base_width and
-- base_height in weather.conf to match:
--   base_width  = widget_width + 56
--   base_height = 150 * text_size + 56
text_size        = 1.20          -- all text (the widget grows to fit)
caption_size     = 1.00          -- the NEXT 24 HOURS title
widget_width     = 728           -- how wide the whole widget is
tile_padding     = 22            -- space around the forecast

-- Frames per second. Set fps in weather.conf to the same number.
target_fps = 1

---------------- DON'T EDIT BELOW IF YOU DO NOT KNOW WHAT YOU ARE DOING ----------------

local conky_window_surface = T.window_surface

local sin, cos, floor = math.sin, math.cos, math.floor
local sqrt, max, min, pi = math.sqrt, math.max, math.min, math.pi
local TAU = 2 * pi

local function yes(value) return tostring(value):lower() == "yes" end
local function clamp(v, low, high)
  if v < low then return low elseif v > high then return high end
  return v
end
local function lerp(a, b, t) return a + (b - a) * t end
local function round(v) return floor(v + 0.5) end
local function number_or(value, default) return tonumber(value) or default end

local TEXT = clamp(number_or(text_size, 1), 0.6, 2)
local CAPTION = clamp(number_or(caption_size, 1), 0.6, 2)
local TWELVE_HOUR = tostring(clock_format):lower() == "12h"

local SCRIPT_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local CACHE = (os.getenv("XDG_CACHE_HOME") or ((os.getenv("HOME") or "/tmp") .. "/.cache")) .. "/conky/weather"

local function read_first_line(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local line = file:read("*l")
  file:close()
  return line
end

local function read_all(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

-- The cache files are Lua tables written by scripts/weather.py. They are loaded into
-- an empty environment, so even a corrupted one can only fail to load.
local function load_table(path)
  local chunk = loadfile(path, "t", {})
  if not chunk then return nil end
  local ok, value = pcall(chunk)
  if ok and type(value) == "table" then return value end
  return nil
end

---------------- COLOURS ----------------

-- From the palette in lua/theme.lua, as {r, g, b} in 0..1
local function rgb(hex) local r, g, b = T.rgba(hex); return {r, g, b} end
local P = {
  ink = rgb(T.colors.weather_ink), cloud = rgb(T.colors.weather_cloud),
  sun = rgb(T.colors.weather_sun), rain = rgb(T.colors.weather_rain),
  -- Cold to hot, in Celsius: {temperature, r, g, b}.
  temperature = {},
}
for i, stop in ipairs(T.colors.temperature) do
  local r, g, b = T.rgba(stop[2])
  P.temperature[i] = {stop[1], r, g, b}
end
-- The colour clouds are shaded towards, underneath.
local SHADOW = rgb(T.colors.weather_shadow)

local function mixc(a, b, t)
  return {a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t}
end

local function source(cr, c, alpha)
  cairo_set_source_rgba(cr, c[1], c[2], c[3], alpha or 1)
end

-- Opacity tiers for ink. Hierarchy comes from these, not from more colours.
local STRONG, SOFT, MUTED, HAIR = 0.96, 0.74, 0.54, 0.12

local function ink(cr, alpha) source(cr, P.ink, alpha) end

local weather = nil            -- the helper's forecast, once it has arrived

-- Temperatures are coloured on a fixed scale in Celsius, so 20° looks the
-- same whatever the units -- the stops come harmonised from the helper.
local function temperature_color(value)
  if weather and weather.imperial then value = (value - 32) * 5 / 9 end
  local stops = P.temperature
  if value <= stops[1][1] then return {stops[1][2], stops[1][3], stops[1][4]} end
  for i = 2, #stops do
    local b = stops[i]
    if value <= b[1] then
      local a = stops[i - 1]
      local t = (value - a[1]) / (b[1] - a[1])
      return {lerp(a[2], b[2], t), lerp(a[3], b[3], t), lerp(a[4], b[4], t)}
    end
  end
  local last = stops[#stops]
  return {last[2], last[3], last[4]}
end

---------------- TYPE ----------------

local font_options = nil

-- Greyscale antialiasing: subpixel rendering on a transparent window leaves
-- colour fringes once the compositor blends it over the desktop. Metrics are
-- unhinted so text measures the same at every scale.
local function prepare(cr)
  if font_options == nil then
    font_options = cairo_font_options_create()
    cairo_font_options_set_antialias(font_options, CAIRO_ANTIALIAS_GRAY)
    cairo_font_options_set_hint_style(font_options, CAIRO_HINT_STYLE_SLIGHT)
    cairo_font_options_set_hint_metrics(font_options, CAIRO_HINT_METRICS_OFF)
  end
  cairo_set_font_options(cr, font_options)
  cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
  cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
end

local function face(cr, family, size)
  cairo_select_font_face(cr, family, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
  cairo_set_font_size(cr, size)
end

local extents = nil
local function advance(cr, text)
  extents = extents or cairo_text_extents_t:create()
  cairo_text_extents(cr, text, extents)
  return extents.x_advance
end

-- align: 0 left, 0.5 centre, 1 right. Returns the width drawn.
local function text(cr, s, x, y, align)
  local w = advance(cr, s)
  cairo_move_to(cr, x - w * (align or 0), y)
  cairo_show_text(cr, s)
  return w
end

-- Small capitals with letter-spacing: the one typographic device that marks
-- a caption as a caption without making it louder.
local function tracked(cr, s, x, y, spacing, align)
  local width, chars = 0, {}
  for ch in s:gmatch(utf8.charpattern) do
    local a = advance(cr, ch)
    chars[#chars + 1] = {ch, a}
    width = width + a + spacing
  end
  width = width - spacing
  x = x - width * (align or 0)
  for _, c in ipairs(chars) do
    cairo_move_to(cr, x, y)
    cairo_show_text(cr, c[1])
    x = x + c[2] + spacing
  end
  return width
end

-- string.upper only knows ASCII, and day names and places come in the
-- user's language. This also covers Latin-1 and Latin Extended-A, which is
-- every accented letter in most European languages.
local function upper(s)
  local out = {}
  for _, c in utf8.codes(s) do
    if (c >= 0x61 and c <= 0x7A) or (c >= 0xE0 and c <= 0xFE and c ~= 0xF7) then c = c - 0x20
    elseif c >= 0x100 and c <= 0x17F and c ~= 0x131 and c ~= 0x138 and c ~= 0x149 then
      -- Pairs are upper/lower in that order, but the run 0x139-0x148 and
      -- 0x179-0x17E is shifted by one.
      local odd_lower = (c >= 0x139 and c <= 0x148) or (c >= 0x179 and c <= 0x17E)
      if (c % 2 == 1) ~= odd_lower then c = c - 1 end
    end
    out[#out + 1] = utf8.char(c)
  end
  return table.concat(out)
end


local function tracked_width(cr, s, spacing)
  local width, count = 0, 0
  for ch in s:gmatch(utf8.charpattern) do
    width, count = width + advance(cr, ch), count + 1
  end
  return width + spacing * max(count - 1, 0)
end

-- The width a tile's contents have, for anything that must not run out of
-- it. Set before each tile draws.
local room = 300

local function caption(cr, s, x, y, align, alpha)
  local ok, shouted = pcall(upper, s)
  s = ok and shouted or s
  -- A large caption in a narrow tile shrinks rather than running out of it.
  local size = 10 * CAPTION
  face(cr, font_medium, size)
  local width = tracked_width(cr, s, 1.5 * CAPTION)
  local most = room - 2 * (tonumber(tile_padding) or 22)
  if width > most then
    size = size * most / width
    face(cr, font_medium, size)
  end
  ink(cr, alpha or MUTED)
  return tracked(cr, s, x, y, 1.5 * size / 10, align)
end

-- Fit a string into a width, trimming it a character at a time. Whole
-- characters: half of a two-byte "°" is invalid UTF-8, and cairo answers
-- invalid text by putting the context into an error state that silently
-- drops everything drawn after it.
local function fit(cr, s, width)
  if advance(cr, s) <= width then return s end
  while #s > 0 and advance(cr, s .. "…") > width do
    local last = utf8.offset(s, -1)
    if not last then break end
    s = s:sub(1, last - 1)
  end
  return s .. "…"
end

local SHOW_UNIT = yes(show_temperature_unit)

-- The number alone, with a real minus sign rather than a hyphen.
local function signed(value)
  local v = round(value)
  return v < 0 and ("−" .. -v) or tostring(v)
end

-- The unit a temperature is in: the forecast's, unless one is given -- the
-- machine's sensors always report Celsius, whatever the forecast uses.
local function unit_of(unit)
  return "°" .. (SHOW_UNIT and (unit or (weather and weather.imperial and "F" or "C")) or "")
end

local function degrees(value, unit)
  return signed(value) .. unit_of(unit)
end


local function hour_label(t, offset)
  if TWELVE_HOUR then
    local h = tonumber(os.date("!%I", t + offset))
    return h .. os.date("!%p", t + offset):sub(1, 1):lower()
  end
  return os.date("!%H", t + offset) .. "h"
end

---------------- SHAPES ----------------

-- A rounded bar along its longer side.
local function capsule(cr, x, y, w, h)
  cairo_new_path(cr)
  if w >= h then
    local r = h / 2
    cairo_arc(cr, x + w - r, y + r, r, -pi / 2, pi / 2)
    cairo_arc(cr, x + r, y + r, r, pi / 2, 3 * pi / 2)
  else
    local r = w / 2
    cairo_arc(cr, x + r, y + r, r, pi, TAU)
    cairo_arc(cr, x + r, y + h - r, r, 0, pi)
  end
  cairo_close_path(cr)
end

local function disc(cr, x, y, r)
  cairo_new_path(cr)
  cairo_arc(cr, x, y, r, 0, TAU)
end

local function glow(cr, x, y, r, c, alpha)
  local g = cairo_pattern_create_radial(x, y, 0, x, y, r)
  cairo_pattern_add_color_stop_rgba(g, 0, c[1], c[2], c[3], alpha)
  cairo_pattern_add_color_stop_rgba(g, 0.4, c[1], c[2], c[3], alpha * 0.35)
  cairo_pattern_add_color_stop_rgba(g, 1, c[1], c[2], c[3], 0)
  cairo_set_source(cr, g)
  disc(cr, x, y, r)
  cairo_fill(cr)
  cairo_pattern_destroy(g)
end

---------------- WEATHER ICONS ----------------
-- Drawn, not loaded: they take the palette like everything else, scale to any
-- size, and the big one moves. Every icon is laid out on a 24-unit grid.

local function with_cutout(cr, back, front_path, gap)
  -- Draw `back`, then knock a gap round where the front shape will go, so a
  -- cloud reads as in front of the sun rather than pasted onto it.
  cairo_push_group(cr)
  back()
  cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR)
  front_path()
  cairo_set_line_width(cr, gap)
  cairo_stroke_preserve(cr)
  cairo_fill(cr)
  cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
  cairo_pop_group_to_source(cr)
  cairo_paint(cr)
end

local function cloud_path(cr, cx, cy, size)
  local u = size / 24
  local function blob(x, y, r)
    cairo_new_sub_path(cr)
    cairo_arc(cr, cx + (x - 12) * u, cy + (y - 12) * u, r * u, 0, TAU)
  end
  cairo_new_path(cr)
  blob(7.6, 14.4, 4.4)
  blob(12.6, 10.8, 6.0)
  blob(17.6, 14.0, 4.8)
  cairo_new_sub_path(cr)
  cairo_rectangle(cr, cx + (7.6 - 12) * u, cy + (13.0 - 12) * u, 10.0 * u, 5.8 * u)
end

local function fill_cloud(cr, cx, cy, size, shade)
  local u = size / 24
  local top, bottom = mixc(P.cloud, SHADOW, shade or 0), mixc(P.cloud, SHADOW, (shade or 0) + 0.22)
  local g = cairo_pattern_create_linear(0, cy - 7 * u, 0, cy + 7 * u)
  cairo_pattern_add_color_stop_rgba(g, 0, top[1], top[2], top[3], 1)
  cairo_pattern_add_color_stop_rgba(g, 1, bottom[1], bottom[2], bottom[3], 1)
  cloud_path(cr, cx, cy, size)
  cairo_set_source(cr, g)
  cairo_fill(cr)
  cairo_pattern_destroy(g)
end

local function sun_icon(cr, cx, cy, size, t, halo)
  local u = size / 24
  if halo then glow(cr, cx, cy, 13 * u, P.sun, 0.30 + 0.05 * sin(t * 1.3)) end
  cairo_set_line_width(cr, 1.8 * u)
  source(cr, P.sun, 1)
  local turn = t * 0.10
  cairo_new_path(cr)
  for i = 0, 7 do
    local a = turn + i * TAU / 8
    cairo_move_to(cr, cx + cos(a) * 7.6 * u, cy + sin(a) * 7.6 * u)
    cairo_line_to(cr, cx + cos(a) * 10.0 * u, cy + sin(a) * 10.0 * u)
  end
  cairo_stroke(cr)
  local hot = mixc(P.sun, {1, 1, 1}, 0.45)
  local g = cairo_pattern_create_radial(cx - 1.5 * u, cy - 1.5 * u, 0, cx, cy, 5.2 * u)
  cairo_pattern_add_color_stop_rgb(g, 0, hot[1], hot[2], hot[3])
  cairo_pattern_add_color_stop_rgb(g, 1, P.sun[1], P.sun[2], P.sun[3])
  cairo_set_source(cr, g)
  disc(cr, cx, cy, 5.2 * u)
  cairo_fill(cr)
  cairo_pattern_destroy(g)
end

-- A crescent: the disc, minus a second disc clipped to it (even-odd inside a
-- clip needs no intermediate surface).
local function moon_icon(cr, cx, cy, size, t, halo)
  local u = size / 24
  local moon = mixc(P.cloud, P.sun, 0.18)
  if halo then glow(cr, cx, cy, 12 * u, moon, 0.20 + 0.04 * sin(t * 1.1)) end
  cairo_save(cr)
  disc(cr, cx, cy, 7.4 * u)
  cairo_clip(cr)
  cairo_new_path(cr)
  cairo_arc(cr, cx, cy, 7.4 * u, 0, TAU)
  cairo_new_sub_path(cr)
  cairo_arc(cr, cx + 4.4 * u, cy - 3.4 * u, 6.4 * u, 0, TAU)
  cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD)
  source(cr, moon, 1)
  cairo_fill(cr)
  cairo_restore(cr)
  if halo then
    source(cr, moon, 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2.1)))
    disc(cr, cx + 7.5 * u, cy - 7 * u, 0.8 * u); cairo_fill(cr)
    source(cr, moon, 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 1.7 + 2)))
    disc(cr, cx + 10 * u, cy - 1.8 * u, 0.55 * u); cairo_fill(cr)
  end
end

local function celestial(cr, day, cx, cy, size, t, halo)
  if day then sun_icon(cr, cx, cy, size, t, halo) else moon_icon(cr, cx, cy, size, t, halo) end
end

-- Precipitation falls from under the cloud. Animated, each streak loops on
-- its own phase; static, they sit at staggered heights so they still read as
-- falling.
local function precipitation(cr, kind, level, cx, cy, size, t, live)
  local u = size / 24
  local count = (level or 2) >= 3 and 5 or ((level or 2) == 1 and 3 or 4)
  local spread = 11
  for i = 1, count do
    local x0 = cx + (-spread / 2 + spread * (i - 0.5) / count) * u + 0.6 * u
    local phase = live and ((t * (kind == "snow" and 0.45 or 1.15) + i * 0.37) % 1) or ((i * 0.37) % 1) * 0.6 + 0.2
    local fade = live and sin(phase * pi) or 1
    local snowy = kind == "snow" or (kind == "sleet" and i % 2 == 0)
    if snowy then
      local sway = live and sin(t * 1.4 + i) * 0.8 * u or 0
      source(cr, P.cloud, 0.95 * fade)
      disc(cr, x0 + sway - phase * 1.2 * u, cy + (7.2 + phase * 6) * u, 1.05 * u)
      cairo_fill(cr)
    else
      local len = kind == "drizzle" and 1.1 or 2.6
      local y = cy + (7.0 + phase * 6) * u
      local x = x0 - phase * 2.0 * u
      source(cr, P.rain, 0.95 * fade)
      cairo_set_line_width(cr, 1.5 * u)
      cairo_new_path(cr)
      cairo_move_to(cr, x, y)
      cairo_line_to(cr, x - 0.7 * u * len / 2.6, y + len * u)
      cairo_stroke(cr)
    end
  end
end

local function bolt(cr, cx, cy, size, t, live)
  local u = size / 24
  local flash = 1
  if live then
    local p = t % 4.2
    flash = (p < 0.12 or (p > 0.22 and p < 0.32)) and 1 or 0.55
    if flash == 1 then glow(cr, cx, cy + 6 * u, 10 * u, P.sun, 0.35) end
  end
  local pts = {{13.4, 14.6}, {9.8, 19.6}, {12.4, 19.6}, {10.8, 23.6}, {15.4, 17.6}, {12.8, 17.6}, {14.6, 14.6}}
  cairo_new_path(cr)
  for i, p in ipairs(pts) do
    local x, y = cx + (p[1] - 12) * u, cy + (p[2] - 12) * u
    if i == 1 then cairo_move_to(cr, x, y) else cairo_line_to(cr, x, y) end
  end
  cairo_close_path(cr)
  source(cr, P.sun, flash)
  cairo_fill(cr)
end

local function weather_icon(cr, kind, level, day, cx, cy, size, t, live)
  local u = size / 24
  t = live and t or 0
  local drift = live and sin(t * 0.5) * 0.7 * u or 0
  local gap = 1.6 * u
  day = day ~= false and day ~= 0

  if kind == "clear" then
    celestial(cr, day, cx, cy, size, t, size >= 40)

  elseif kind == "few" or kind == "partly" or kind == "showers" then
    local few = kind == "few"
    local bx, by = few and cx - 1.5 * u or cx - 3.6 * u, few and cy - 1.5 * u or cy - 3.8 * u
    local bs = few and size * 0.9 or size * 0.74
    local fx, fy, fs = few and cx + 4.2 * u or cx + 1.2 * u, few and cy + 4.4 * u or cy + 1.8 * u, few and size * 0.58 or size * 0.9
    if kind == "showers" then fy = fy - 2.2 * u end
    with_cutout(cr, function() celestial(cr, day, bx, by, bs, t, size >= 40) end,
                function() cloud_path(cr, fx + drift, fy, fs) end, gap)
    fill_cloud(cr, fx + drift, fy, fs)
    if kind == "showers" then precipitation(cr, "rain", level, fx + drift, fy, fs, t, live) end

  elseif kind == "cloudy" then
    with_cutout(cr, function() fill_cloud(cr, cx + 3.4 * u - drift * 0.6, cy - 3.0 * u, size * 0.72, 0.30) end,
                function() cloud_path(cr, cx - 1.0 * u + drift, cy + 1.6 * u, size * 0.94) end, gap)
    fill_cloud(cr, cx - 1.0 * u + drift, cy + 1.6 * u, size * 0.94)

  elseif kind == "fog" then
    fill_cloud(cr, cx + drift, cy - 2.6 * u, size * 0.86, 0.08)
    cairo_set_line_width(cr, 1.6 * u)
    for i, row in ipairs({{-7.5, 5.5, 6.2}, {-5.0, 7.5, 9.0}}) do
      local slide = live and sin(t * 0.7 + i * 1.7) * 1.2 * u or 0
      source(cr, P.cloud, 0.8)
      cairo_new_path(cr)
      cairo_move_to(cr, cx + row[1] * u + slide, cy + row[3] * u)
      cairo_line_to(cr, cx + row[2] * u + slide, cy + row[3] * u)
      cairo_stroke(cr)
    end

  else   -- drizzle, rain, sleet, snow, thunder
    local shade = kind == "thunder" and 0.28 or 0.06
    if kind == "thunder" then bolt(cr, cx + drift, cy - 2.4 * u, size * 0.95, t, live) end
    if kind ~= "thunder" or level >= 3 then
      precipitation(cr, kind == "thunder" and "rain" or kind, kind == "thunder" and 1 or level,
                    cx + drift, cy - 2.4 * u, size * 0.95, t, live)
    end
    fill_cloud(cr, cx + drift, cy - 2.4 * u, size * 0.95, shade)
  end
end

---------------- LAYOUT ----------------
-- Designed at 1440p; everything is drawn in these units and scaled to the
-- window conky actually made. One box: the next 24 hours.
-- Its height is in content units, which text_size zooms; its width is
-- widget_width.
local MARGIN = 28
local WIDTH = clamp(number_or(widget_width, 760), 480, 1600)
local HOURLY_HEIGHT = 150

local layout = nil

local LEFT_EXT   -- set below, from weather.conf

local function compute_layout(win_w, win_h)
  win_w = win_w - LEFT_EXT
  local height = HOURLY_HEIGHT * TEXT
  local base_h = 2 * MARGIN + height
  local base_w = WIDTH + 2 * MARGIN
  local s = min(win_w / base_w, win_h / base_h)
  local ox = (win_w - base_w * s) / 2

  -- cw, ch and cs are the tile in content units and the scale to draw them
  -- at: the layout's scale times text_size.
  local x0, y0 = LEFT_EXT + round(ox + MARGIN * s), round(MARGIN * s)
  local x1, y1 = LEFT_EXT + round(ox + (MARGIN + WIDTH) * s), round((MARGIN + height) * s)
  local tile = {name = "hourly", x = x0, y = y0, w = x1 - x0, h = y1 - y0,
                s = s, cs = s * TEXT, cw = (x1 - x0) / (s * TEXT), ch = (y1 - y0) / (s * TEXT)}
  tile.key = string.format("%d,%d,%d,%d", x0, y0, x1 - x0, y1 - y0)
  return {W = win_w + LEFT_EXT, H = win_h, s = s, tiles = {tile}, base_w = base_w, base_h = base_h}
end

---------------- TILES ----------------
-- Each tile draws in its own units, (0,0) at its top-left corner. `static`
-- is drawn into a cached surface and only redrawn when its key changes.

local TILES = {}
local PAD = clamp(number_or(tile_padding, 22), 10, 40)
local data_version = 0
local weather_error = nil

local function place_offset() return weather and weather.tz_offset or 0 end

local function no_weather(cr, w, h, title)   -- (the title is drawn with the frame)
  face(cr, font_regular, 13)
  ink(cr, MUTED)
  local message = weather_error and ("Weather unavailable: " .. weather_error.error) or "Fetching the forecast…"
  text(cr, fit(cr, message, w - 2 * PAD), PAD, h / 2 + 6)
end

-- hourly --------------------------------------------------------------------

-- Monotone cubic through the points (Fritsch-Carlson): smooth, but never
-- overshooting into a high or low that is not in the forecast.
local function monotone_path(cr, xs, ys, start_new)
  local n = #xs
  if n < 2 then return end
  local d, m = {}, {}
  for i = 1, n - 1 do d[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) end
  m[1], m[n] = d[1], d[n - 1]
  for i = 2, n - 1 do
    if d[i - 1] * d[i] <= 0 then m[i] = 0 else m[i] = (d[i - 1] + d[i]) / 2 end
  end
  for i = 1, n - 1 do
    if d[i] == 0 then m[i], m[i + 1] = 0, 0
    else
      local a, b = m[i] / d[i], m[i + 1] / d[i]
      local s = a * a + b * b
      if s > 9 then
        local t = 3 / sqrt(s)
        m[i], m[i + 1] = t * a * d[i], t * b * d[i]
      end
    end
  end
  if start_new then cairo_move_to(cr, xs[1], ys[1]) else cairo_line_to(cr, xs[1], ys[1]) end
  for i = 1, n - 1 do
    local h = (xs[i + 1] - xs[i]) / 3
    cairo_curve_to(cr, xs[i] + h, ys[i] + m[i] * h, xs[i + 1] - h, ys[i + 1] - m[i + 1] * h, xs[i + 1], ys[i + 1])
  end
end


-- Matches the system monitor (lua/system.lua): L-shaped brackets at the
-- tile's corners and a small line icon before the title, in its colours.
local BRACKET = {T.rgba(T.colors.bracket, T.card.bracket_alpha)}
local ICON_INK = {T.rgba(T.colors.accent, 0.9)}

-- Grain and sheen, as on the system monitor's cards: the shared noise tile
-- (T.grain) at screen-pixel size, plus a faint top-lit gradient.
-- GRAIN_ALPHA / SHEEN_ALPHA 0 turn them off. The box is cached and only
-- redrawn when the forecast or the minute changes, so this costs nothing per frame.
local GRAIN_ALPHA = 1.0
local SHEEN_ALPHA = T.card.sheen
local grain = T.grain

-- Sun peeking over a cloud, ~13 units wide, centred on (cx, cy)
local function title_icon(cr, cx, cy, cs)
  cairo_new_path(cr)
  cairo_new_sub_path(cr)
  cairo_arc(cr, cx - 1.5, cy - 1.8, 2.6, math.pi * 0.85, math.pi * 1.95)
  for i = 0, 3 do
    local a = math.pi * (1.0 + i * 0.3)
    cairo_move_to(cr, cx - 1.5 + 4.2 * math.cos(a), cy - 1.8 + 4.2 * math.sin(a))
    cairo_line_to(cr, cx - 1.5 + 5.6 * math.cos(a), cy - 1.8 + 5.6 * math.sin(a))
  end
  cairo_new_sub_path(cr)
  cairo_move_to(cr, cx - 3.5, cy + 4.5)
  cairo_arc(cr, cx - 3.2, cy + 2.3, 2.2, math.pi * 0.5, math.pi * 1.45)
  cairo_arc(cr, cx + 0.8, cy + 0.6, 3.1, math.pi * 1.1, math.pi * 1.95)
  cairo_arc(cr, cx + 4.1, cy + 2.6, 1.9, math.pi * 1.55, math.pi * 0.5)
  cairo_close_path(cr)
  cairo_set_line_width(cr, 1.2 / cs)
  cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
  cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
  cairo_set_source_rgba(cr, ICON_INK[1], ICON_INK[2], ICON_INK[3], ICON_INK[4])
  cairo_stroke(cr)
end
local TITLE_INDENT = 20

-- The box's frame, drawn in window pixels around the forecast tile: grain,
-- sheen and corner brackets as before, but its left side reaches out towards
-- the wallpaper's round window and curves around it, CURVE_GAP px outside the
-- glass frame (same geometry as lua/system.lua), with a faint line along it.
-- The window's place on the monitor comes from weather.conf.
-- CURVE = false gives the plain box again.
local CURVE = true
local GLASS_MX, GLASS_MY, FRAME_R, CURVE_GAP = T.glass.x, T.glass.y, T.glass.frame_r, 56   -- as the calendar card above
local LEFT_MX = 1240          -- leftmost the frame goes (monitor x), below the curve
local TITLE_PAD = 16          -- title's distance from the frame's left side (px)
local MON_W = T.monitor.w

local frame_conf = {}
do
  local f = io.open(os.getenv("HOME") .. "/.config/conky/weather.conf", "r")
  local t = f and f:read("a") or ""
  if f then f:close() end
  frame_conf.mx, frame_conf.my = t:match("local margin_x, margin_y = (%d+), (%d+)")
  frame_conf.mx, frame_conf.my = tonumber(frame_conf.mx) or 10, tonumber(frame_conf.my) or 68
  LEFT_EXT = tonumber(t:match("local left_ext = (%d+)")) or 0
end

-- Frame outline: a list of {x, y} points (window pixels), and the stretch of
-- its left side that follows the curve
local function frame_points(win_w, tile)
  local wx, wy = MON_W - frame_conf.mx - win_w, frame_conf.my   -- window on the monitor
  local cx, cy, r = GLASS_MX - wx, GLASS_MY - wy, FRAME_R + CURVE_GAP
  local xmin = LEFT_MX - wx
  local function left(y)
    local dy = y - cy
    if math.abs(dy) >= r then return xmin end
    return math.max(xmin, cx + math.sqrt(r * r - dy * dy))
  end
  return left, tile.x + tile.w, tile.y, tile.y + tile.h
end

local function draw_frame(cr, win_w, tile)
  local left, x2, y1, y2 = frame_points(win_w, tile)
  if not CURVE then left = function() return tile.x end end
  local function outline(inset)
    cairo_new_path(cr)
    cairo_move_to(cr, left(y1 + inset) + inset, y1 + inset)
    cairo_line_to(cr, x2 - inset, y1 + inset)
    cairo_line_to(cr, x2 - inset, y2 - inset)
    for y = y2 - inset, y1 + inset, -2 do cairo_line_to(cr, left(y) + inset, y) end
    cairo_close_path(cr)
  end
  -- grain and sheen
  if GRAIN_ALPHA > 0 then
    outline(1)
    cairo_set_source(cr, grain())
    cairo_fill(cr)
  end
  if SHEEN_ALPHA > 0 then
    outline(1)
    local g = cairo_pattern_create_linear(0, y1, 0, y2)
    cairo_pattern_add_color_stop_rgba(g, 0, 1, 1, 1, SHEEN_ALPHA)
    cairo_pattern_add_color_stop_rgba(g, 1, 1, 1, 1, 0)
    cairo_set_source(cr, g)
    cairo_fill(cr)
    cairo_pattern_destroy(g)
  end
  -- corner brackets; the left ones' vertical legs follow the (curved) side
  local l = T.card.bracket_len
  local t1, t2, xr = y1 + 0.5, y2 - 0.5, x2 - 0.5
  local function lx(y) return left(y) + 0.5 end
  local function trace(ya, yb, move)
    local step = ya < yb and 2 or -2
    local y = ya
    while (step > 0 and y < yb) or (step < 0 and y > yb) do
      if move then cairo_move_to(cr, lx(y), y); move = false else cairo_line_to(cr, lx(y), y) end
      y = y + step
    end
    cairo_line_to(cr, lx(yb), yb)
  end
  cairo_new_path(cr)
  cairo_set_line_width(cr, 1)
  cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
  cairo_set_line_join(cr, CAIRO_LINE_JOIN_MITER)
  cairo_move_to(cr, xr - l, t1); cairo_line_to(cr, xr, t1); cairo_line_to(cr, xr, t1 + l)
  cairo_move_to(cr, xr - l, t2); cairo_line_to(cr, xr, t2); cairo_line_to(cr, xr, t2 - l)
  cairo_move_to(cr, lx(t1) + l, t1); cairo_line_to(cr, lx(t1), t1); trace(t1, t1 + l)
  cairo_move_to(cr, lx(t2) + l, t2); cairo_line_to(cr, lx(t2), t2); trace(t2, t2 - l)
  cairo_set_source_rgba(cr, BRACKET[1], BRACKET[2], BRACKET[3], BRACKET[4])
  cairo_stroke(cr)
  -- faint line along the whole left side, between the brackets
  if CURVE then
    trace(t1 + l, t2 - l, true)
    cairo_set_source_rgba(cr, BRACKET[1], BRACKET[2], BRACKET[3], BRACKET[4] * 0.6)
    cairo_stroke(cr)
  end

  -- the title, TITLE_PAD from the left side at its height, in tile units
  local cs = tile.cs
  local ty = tile.y + 30 * cs
  local tx = ((CURVE and left(ty - 12) or tile.x) + TITLE_PAD - tile.x) / cs
  cairo_save(cr)
  prepare(cr)
  cairo_translate(cr, tile.x, tile.y)
  cairo_scale(cr, cs, cs)
  room = tile.cw
  title_icon(cr, tx + 6.5, 30 - 4.5, cs)
  caption(cr, "Weather / next 24h", tx + TITLE_INDENT, 30)
  cairo_restore(cr)
end


TILES.hourly = {
  key = function() return (weather and tostring(weather.fetched) or "none") .. os.date("%H%M") end,
  static = function(cr, w, h, tile)
    local cs = tile and tile.cs or 1
    -- the frame (grain, sheen, brackets) and the title are drawn by draw_frame;
    -- the title is only measured here, for the summary's room
    if not weather then return no_weather(cr, w, h, "Weather / next 24h") end
    local now, off = os.time(), place_offset()
    local cw = caption(cr, "Weather / next 24h", PAD + TITLE_INDENT, 30, nil, 0) + TITLE_INDENT
    -- Only the first clause ("Dry for the next 24 hours"), not "High of …"
    local summary = weather.summary and (weather.summary:match("^(.-) · ") or weather.summary)
    if summary and summary ~= "" then
      face(cr, font_regular, 12.5)
      ink(cr, SOFT)
      text(cr, fit(cr, summary, w - 2 * PAD - cw - 24), w - PAD, 30, 1)
    end

    local x0, x1 = PAD + 14, w - PAD - 14
    local t0, t1 = now, now + 24 * 3600
    local function X(t) return x0 + (x1 - x0) * (t - t0) / (t1 - t0) end
    local pts = {{t = now, temp = weather.current.temp}}
    local hours = {}
    for _, hr in ipairs(weather.hourly) do
      if hr.t > now and hr.t <= t1 + 3600 then pts[#pts + 1] = hr end
      if hr.t + 3600 > now and hr.t < t1 then hours[#hours + 1] = hr end
    end
    if #pts < 3 then return end

    local lo, hi = math.huge, -math.huge
    for _, p in ipairs(pts) do lo, hi = min(lo, p.temp), max(hi, p.temp) end
    local span = max(hi - lo, 4)
    local mid = (hi + lo) / 2
    lo, hi = mid - span / 2, mid + span / 2
    local top, bottom = 84, 113
    local function Y(v) return bottom - (bottom - top) * (v - lo) / (hi - lo) end

    -- Chance of rain, as low bars rising from the floor of the chart.
    cairo_save(cr)
    cairo_rectangle(cr, x0, 44, x1 - x0, h - 44)
    cairo_clip(cr)
    for _, hr in ipairs(hours) do
      if hr.pop >= 10 then
        local bh = 2 + 18 * hr.pop / 100
        source(cr, P.rain, 0.25 + 0.5 * hr.pop / 100)
        capsule(cr, X(hr.t + 1800) - 1.5, 122 - bh, 3, bh)
        cairo_fill(cr)
      end
    end
    cairo_restore(cr)

    local xs, ys = {}, {}
    for _, p in ipairs(pts) do xs[#xs + 1] = X(p.t); ys[#ys + 1] = Y(p.temp) end

    local grad = cairo_pattern_create_linear(x0, 0, x1, 0)
    for _, p in ipairs(pts) do
      local c = temperature_color(p.temp)
      local at = clamp((X(p.t) - x0) / (x1 - x0), 0, 1)
      cairo_pattern_add_color_stop_rgb(grad, at, c[1], c[2], c[3])
    end

    cairo_save(cr)
    cairo_rectangle(cr, x0 - 4, 40, x1 - x0 + 8, h)
    cairo_clip(cr)
    -- Area under the curve: the temperature gradient, fading downwards.
    cairo_push_group(cr)
    cairo_new_path(cr)
    monotone_path(cr, xs, ys, true)
    cairo_line_to(cr, xs[#xs], 122)
    cairo_line_to(cr, xs[1], 122)
    cairo_close_path(cr)
    cairo_set_source(cr, grad)
    cairo_fill(cr)
    cairo_pop_group_to_source(cr)
    local fade = cairo_pattern_create_linear(0, top - 6, 0, 122)
    cairo_pattern_add_color_stop_rgba(fade, 0, 0, 0, 0, 0.30)
    cairo_pattern_add_color_stop_rgba(fade, 1, 0, 0, 0, 0.0)
    cairo_mask(cr, fade)
    cairo_pattern_destroy(fade)

    cairo_new_path(cr)
    monotone_path(cr, xs, ys, true)
    cairo_set_source(cr, grad)
    cairo_set_line_width(cr, 2.4)
    cairo_stroke(cr)
    cairo_restore(cr)
    cairo_pattern_destroy(grad)

    -- Every third hour: icon above, temperature on the curve, hour below.
    -- A mark is drawn only where its labels clear the ones before it, the
    -- "now" labels included. They are measured, not guessed at: with the
    -- unit shown "10°C" is twice the width of "10°", and a mark an hour after
    -- now printed on top of the current temperature.
    face(cr, font_medium, 12)
    local temp_right = x0 + advance(cr, degrees(weather.current.temp)) / 2
    face(cr, font_medium, 11)
    local hour_right = x0 + advance(cr, "Now") / 2
    local icon_x = x0 - 100
    for _, hr in ipairs(weather.hourly) do
      local local_hour = tonumber(os.date("!%H", hr.t + off))
      if hr.t > now and hr.t < t1 - 1200 and local_hour % 3 == 0 then
        local x = X(hr.t)
        local temperature, hour = degrees(hr.temp), hour_label(hr.t, off)
        face(cr, font_regular, 12)
        local tw = advance(cr, temperature)
        face(cr, font_regular, 11)
        local hw = advance(cr, hour)
        if x - tw / 2 >= temp_right + 6 and x - hw / 2 >= hour_right + 6 and x - icon_x >= 24 then
          weather_icon(cr, hr.kind, hr.level, hr.day == 1, x, 53, 18, 0, false)
          face(cr, font_regular, 12)
          ink(cr, SOFT)
          text(cr, temperature, x, Y(hr.temp) - 8, 0.5)
          face(cr, font_regular, 11)
          ink(cr, MUTED)
          text(cr, hour, x, h - 15, 0.5)
          ink(cr, HAIR)
          disc(cr, x, Y(hr.temp), 1.6)
          cairo_fill(cr)
          temp_right, hour_right, icon_x = x + tw / 2, x + hw / 2, x
        end
      end
    end

    face(cr, font_medium, 11)
    ink(cr, SOFT)
    text(cr, "Now", x0, h - 15, 0.5)
    face(cr, font_medium, 12)
    ink(cr, STRONG)
    text(cr, degrees(weather.current.temp), x0, ys[1] - 9, 0.5)
  end,
}

---------------- THE HELPER ----------------

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function choice(value, allowed, default)
  value = tostring(value):lower()
  for _, a in ipairs(allowed) do if value == a then return a end end
  return default
end

-- A number for weather.py's command line. string.format follows the locale
-- conky sets (LC_NUMERIC), so with e.g. fr_FR it writes "0,00", which
-- Python's argparse rejects as a float. Always use a dot here.
local function arg_num(fmt, value)
  return (string.format(fmt, value):gsub(",", "."))
end

local function helper_command()
  local parts = {
    "python3", shell_quote(SCRIPT_DIR .. "/../scripts/weather.py"),
    "--cache", shell_quote(CACHE), "--location", shell_quote(location),
    "--units", choice(units, {"metric", "imperial"}, "metric"),
    "--interval", arg_num("%.1f", number_or(weather_refresh_minutes, 15)),
    "--clock", TWELVE_HOUR and "12h" or "24h",
    SHOW_UNIT and "--show-unit" or nil,
  }
  return table.concat(parts, " ")
end


local next_helper = 0
-- Seconds between helper runs. A run with nothing to do costs a few
-- milliseconds: it only fetches when the forecast is older than
-- weather_refresh_minutes.
local HELPER_EVERY = 10
local cache_made = false

local function run_helper(now)
  if now < next_helper then return end
  next_helper = now + HELPER_EVERY
  if not cache_made then
    os.execute("mkdir -p " .. shell_quote(CACHE))
    cache_made = true
  end
  local command = helper_command() .. " >/dev/null 2>>" .. shell_quote(CACHE .. "/helper.err")
  os.execute(command .. " &")
end

---------------- ONE COPY ----------------
-- Two copies of the weather widget would share the cache, so the newest copy wins: each
-- writes its pid to `owner` as it starts, and a copy that finds another live
-- owner there closes. weather.conf relies on this when the size
-- changes: it starts a fresh copy, which takes over.

local check_owner
do
  local MY_PID = tonumber((read_first_line("/proc/self/stat") or ""):match("^(%d+)"))
  local owner_claimed = false

  local function is_conky(pid)
    local cmd = read_all("/proc/" .. pid .. "/cmdline") or ""
    return cmd:find("conky", 1, true) ~= nil
  end

  local function claim_ownership()
    local file = io.open(CACHE .. "/owner", "w")
    if file then
      file:write(tostring(MY_PID), "\n")
      file:close()
    end
  end

  local function step_down(why)
    io.stderr:write("weather: " .. why .. "\n")
    os.exit(0)
  end

  function check_owner()
    if not MY_PID then return end
    if not owner_claimed then
      claim_ownership()
      owner_claimed = true
      return
    end
    local owner = tonumber(read_first_line(CACHE .. "/owner") or "")
    if owner and owner ~= MY_PID and is_conky(owner) then
      step_down("a newer copy of the weather widget is running (pid " .. owner .. "), so this one is closing")
    elseif owner ~= MY_PID then
      claim_ownership()          -- the owner has gone; carry on as the one copy
    end
  end
end

local serial_seen = nil
local next_poll = 0
local first_poll = nil

-- If the helper never writes anything, it is not running at all -- no
-- python3, say -- and whatever it printed on the way out is the explanation.
local function helper_failure()
  local last = nil
  for line in (read_all(CACHE .. "/helper.err") or ""):gmatch("[^\n]+") do last = line end
  return last and {error = last:gsub("^%w*Error: ", "")} or {error = "weather.py didn't run. Is Python 3 installed?"}
end

local function poll_cache(now)
  if now < next_poll then return end
  next_poll = now + 1
  check_owner()
  first_poll = first_poll or now
  local serial = read_first_line(CACHE .. "/serial")
  if serial == nil and not weather_error and now - first_poll > 20 then
    weather_error = helper_failure()
    data_version = data_version + 1
  end
  if serial == nil or serial == serial_seen then return end
  serial_seen = serial
  local w = load_table(CACHE .. "/weather.lua")
  if w and (not weather or w.fetched ~= weather.fetched) then
    weather = w
    data_version = data_version + 1
  end
  weather_error = not weather and load_table(CACHE .. "/weather_error.lua") or nil
  data_version = data_version + 1
end

---------------- DRAWING ----------------

-- The forecast only changes when new data arrives or the minute turns over,
-- so it is drawn into a cached surface and that is painted each frame.
local function draw_static(cr, target_surface, tile, spec)
  local key = (spec.key and spec.key() or "") .. "|" .. data_version
  if tile.cache_key ~= key then
    if tile.cache == nil then
      tile.cache = cairo_surface_create_similar(target_surface, CAIRO_CONTENT_COLOR_ALPHA, tile.w, tile.h)
    end
    local c = cairo_create(tile.cache)
    cairo_set_operator(c, CAIRO_OPERATOR_CLEAR)
    cairo_paint(c)
    cairo_set_operator(c, CAIRO_OPERATOR_OVER)
    prepare(c)
    cairo_scale(c, tile.cs, tile.cs)
    room = tile.cw
    spec.static(c, tile.cw, tile.ch, tile)
    cairo_destroy(c)
    tile.cache_key = key
  end
  cairo_set_source_surface(cr, tile.cache, tile.x, tile.y)
  cairo_paint(cr)
end

local function drop_layout()
  if not layout then return end
  if layout.frame then cairo_surface_destroy(layout.frame) end
  for _, tile in ipairs(layout.tiles) do
    if tile.cache then cairo_surface_destroy(tile.cache) end
  end
end

function conky_draw_weather()
  if conky_window == nil then return end
  -- conky_window is not usable for the first few updates; wait about a
  -- second whatever the frame rate.
  if number_or(conky_parse("${updates}"), 0) <= target_fps then return end

  local now = os.time()
  local W, H = conky_window.width, conky_window.height
  if W < 40 or H < 40 then return end
  if not layout or layout.W ~= W or layout.H ~= H then
    drop_layout()
    layout = compute_layout(W, H)
  end

  run_helper(now)
  poll_cache(now)

  local cs, owns_surface = conky_window_surface()
  local cr = cairo_create(cs)
  if not layout.frame then
    layout.frame = cairo_surface_create_similar(cs, CAIRO_CONTENT_COLOR_ALPHA, W, H)
    local c = cairo_create(layout.frame)
    draw_frame(c, W, layout.tiles[1])
    cairo_destroy(c)
  end
  cairo_set_source_surface(cr, layout.frame, 0, 0)
  cairo_paint(cr)
  for _, tile in ipairs(layout.tiles) do
    draw_static(cr, cs, tile, TILES[tile.name])
  end
  cairo_destroy(cr)
  if owns_surface then cairo_surface_destroy(cs) end
end
