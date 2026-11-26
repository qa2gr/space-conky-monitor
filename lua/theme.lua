-- Shared look for every widget: fonts, text sizes, palette, card style, the
-- wallpaper's round window, and the small cairo helpers they all use.
--
-- Each widget loads it at the top with
--   local T = dofile(os.getenv('HOME') .. '/.config/conky/lua/theme.lua')
-- and takes what it needs; a widget that needs a different value overrides
-- it locally (e.g. T.extend(T.colors, { muted = T.colors.muted_light })).
--
-- Conky only reloads a widget when its own files change: after editing this
-- file, re-run start.sh to see the change everywhere.

require 'cairo'
-- Conky moved cairo_xlib_surface_create into its own module; older builds
-- still export it from 'cairo', so a missing module here is harmless.
pcall(require, 'cairo_xlib')

local T = {}

-- ---------------------------------------------------------------- fonts
T.font        = 'Noto Sans'
T.font_medium = 'Noto Sans Medium'

-- Text sizes (px) and letter spacing (track, px per letter) for captions
-- (small caps-like labels) and section headings.
T.sizes = {
    caption = 9.6,  track = 1.44,
    heading = 11.5, heading_track = 1.8,
    body    = 12.0,
    small   = 10.6,
}

-- ---------------------------------------------------------------- palette
-- Colours come from lua/palettes/<PALETTE>.lua: 'earth' (from the wallpaper)
-- or 'lavender' (the original). To make another, copy one and rename it.
local PALETTE = 'earth'
T.colors = dofile(os.getenv('HOME') .. '/.config/conky/lua/palettes/' .. PALETTE .. '.lua')

-- ---------------------------------------------------------------- cards
-- The boxes of the system, services and weather widgets: a grain texture
-- and a faint top-lit sheen, outlined by L-shaped brackets at the corners.
T.card = {
    sheen         = 0.035,    -- sheen alpha at the top (0 = off)
    bracket_alpha = 0.4,
    bracket_len   = 8,        -- px
}

-- ---------------------------------------------------------------- wallpaper
-- The monitor the widgets live on, on the XWayland screen, and the round
-- window of its wallpaper in that monitor's pixels: the glass (measured from
-- a screenshot) and the outer edge of its frame.
T.monitor = { x = 2560, y = 360, w = 1920, h = 1080 }
T.glass   = { x = 960, y = 540, r = 391, frame_r = 423 }

-- ---------------------------------------------------------------- helpers
-- A copy of base with the keys of over replacing or adding to it.
function T.extend(base, over)
    local t = {}
    for k, v in pairs(base) do t[k] = v end
    for k, v in pairs(over or {}) do t[k] = v end
    return t
end

-- 'rrggbb' (+ alpha) -> r, g, b, a for cairo_set_source_rgba
function T.rgba(hex, a)
    return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255,
           tonumber(hex:sub(5, 6), 16) / 255, a or 1
end

local fopts
function T.font_options()
    if not fopts then
        fopts = cairo_font_options_create()
        cairo_font_options_set_antialias(fopts, CAIRO_ANTIALIAS_GRAY)
        cairo_font_options_set_hint_style(fopts, CAIRO_HINT_STYLE_SLIGHT)
        cairo_font_options_set_hint_metrics(fopts, CAIRO_HINT_METRICS_OFF)
    end
    return fopts
end

function T.set_font(cr, size, family)
    cairo_select_font_face(cr, family or T.font, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
end

-- Width of str in the current font
local ext
function T.advance(cr, str)
    ext = ext or cairo_text_extents_t:create()
    cairo_text_extents(cr, str, ext)
    return ext.x_advance
end

-- An xlib surface on the window's drawable, made for this draw: the caller
-- destroys it (second value). Not conky_surface(), the cached surface newer
-- conky hands out: with it, a widget sometimes draws fine but its window stays
-- empty for good (random at each start; conky 1.26.3, KWin/XWayland).
function T.window_surface()
    return cairo_xlib_surface_create(conky_window.display, conky_window.drawable,
                                     conky_window.visual, conky_window.width,
                                     conky_window.height), true
end

-- Grain: a small noise tile made once (a few thousand 1 px dots, light and
-- dark), returned as a repeating pattern, so texturing a card costs one fill.
local GRAIN_SIZE, GRAIN_DOTS = 128, 2600
local grain_pattern
function T.grain()
    if not grain_pattern then
        local surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, GRAIN_SIZE, GRAIN_SIZE)
        local g = cairo_create(surf)
        math.randomseed(42)
        for _ = 1, GRAIN_DOTS do
            local x, y = math.random(0, GRAIN_SIZE - 1), math.random(0, GRAIN_SIZE - 1)
            if math.random() < 0.5 then
                cairo_set_source_rgba(g, 1, 1, 1, 0.025 + math.random() * 0.045)
            else
                cairo_set_source_rgba(g, 0, 0, 0.02, 0.06 + math.random() * 0.08)
            end
            cairo_rectangle(g, x, y, 1, 1)
            cairo_fill(g)
        end
        cairo_destroy(g)
        grain_pattern = cairo_pattern_create_for_surface(surf)
        cairo_pattern_set_extend(grain_pattern, CAIRO_EXTEND_REPEAT)
        cairo_surface_destroy(surf)   -- the pattern keeps its own reference
    end
    return grain_pattern
end

-- Soft dark elliptical shade behind text drawn over the wallpaper
function T.backdrop(cr, cx, cy, rx, ry)
    cairo_save(cr)
    cairo_translate(cr, cx, cy)
    cairo_scale(cr, rx, ry)
    local g = cairo_pattern_create_radial(0, 0, 0, 0, 0, 1)
    cairo_pattern_add_color_stop_rgba(g, 0,    0.02, 0.03, 0.08, 0.55)
    cairo_pattern_add_color_stop_rgba(g, 0.55, 0.02, 0.03, 0.08, 0.35)
    cairo_pattern_add_color_stop_rgba(g, 1,    0.02, 0.03, 0.08, 0)
    cairo_set_source(cr, g)
    cairo_arc(cr, 0, 0, 1, 0, 2 * math.pi)
    cairo_fill(cr)
    cairo_pattern_destroy(g)
    cairo_restore(cr)
end

-- Settings from ~/.config/conky/.env (see .env.default): KEY="value" lines,
-- $HOME expanded. T.env.KEY is nil when unset or empty.
T.env = {}
do
    local home = os.getenv('HOME')
    local f = io.open(home .. '/.config/conky/.env', 'r')
    if f then
        for line in f:lines() do
            local k, v = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
            if k then
                v = v:match('^"(.*)"$') or v:match("^'(.*)'$") or v
                v = v:gsub('%$%{?HOME%}?', home)
                if v ~= '' then T.env[k] = v end
            end
        end
        f:close()
    end
end

-- A space-separated .env value as a list
function T.env_list(key)
    local out = {}
    for w in (T.env[key] or ''):gmatch('%S+') do out[#out + 1] = w end
    return out
end

return T
