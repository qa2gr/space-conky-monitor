-- VPS status as a small constellation in the top-left of the round spaceship
-- window on the HDMI-A-1 wallpaper (vps.conf). Each server is a star:
-- the lower its latency, the bigger and brighter it shines; an offline server
-- is a dim reddish point.
--
-- Reads ~/.cache/conky/vps-status ("name up|down LATENCY" per line): the
-- output of scripts/vps.sh (Tailscale pings), saved every 30 s by
-- vps.conf. Names are shown in capitals.

local T = dofile(os.getenv('HOME') .. '/.config/conky/lua/theme.lua')

local STATE = os.getenv('HOME') .. '/.cache/conky/vps-status'

-- The wallpaper's glass: centre (960, 540) on HDMI-A-1, radius ~391 (see
-- lua/media.lua). vps.conf puts this window's top-left at (620, 200).
local CX, CY  = T.glass.x - 620, T.glass.y - 200
local GLASS_R = T.glass.r

-- Where each server's star sits, relative to the glass centre (names as
-- scripts/vps.sh prints them). Servers missing here are placed below the last.
-- They sit on an arc STAR_R from the centre (~70 px inside the glass's edge),
-- evenly spaced STAR_STEP degrees apart starting at STAR_FIRST (angles: 0 =
-- right, -90 = top, -180 = left).
local STAR_R, STAR_FIRST, STAR_STEP = 322, -115, -25
local STARS = {}
for i, name in ipairs(T.env_list('VPS_HOSTS')) do   -- from .env
    local a = math.rad(STAR_FIRST + (i - 1) * STAR_STEP)
    STARS[i] = { name = name, x = math.floor(STAR_R * math.cos(a) + 0.5),
                              y = math.floor(STAR_R * math.sin(a) + 0.5) }
end

-- Latency (ms) at which a star is at its smallest; below 10 ms it is at its biggest
local SLOW_MS = 150

local FONT, FONT_MEDIUM = T.font, T.font_medium
local S = { name = T.sizes.small, track = 1.9, ms = T.sizes.small }

local function rgb(hex) return { T.rgba(hex) } end
local C = {
    star      = rgb(T.colors.star),
    glow      = rgb(T.colors.star_glow),   -- halo
    down      = rgb(T.colors.star_down),
    down_text = T.colors.star_down_text,
    name      = T.colors.star_name,
    muted     = T.colors.muted,
    dust      = T.colors.dust,
}

-- ---------------------------------------------------------------- helpers
local rgba, font_options, advance, window_surface = T.rgba, T.font_options, T.advance, T.window_surface

-- Draws str at (x, y) with letter spacing sp; returns the width
local function text(cr, str, x, y, size, family, hex, alpha, sp)
    cairo_select_font_face(cr, family, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    sp = sp or 0
    local x0 = x
    for _, pass in ipairs({ { 0, 1.2, 0, 0, 0.05, 0.45 }, { 0, 0, rgba(hex, alpha) } }) do
        cairo_set_source_rgba(cr, pass[3], pass[4], pass[5], pass[6])
        x = x0 + pass[1]
        for ch in str:gmatch(utf8.charpattern) do
            cairo_move_to(cr, x, y + pass[2])
            cairo_show_text(cr, ch)
            x = x + advance(cr, ch) + sp
        end
    end
    return x - x0 - sp
end

-- ---------------------------------------------------------------- data
local function read_status()
    local out = {}
    local f = io.open(STATE, 'r')
    if not f then return out end
    for line in f:lines() do
        local name, st, ms = line:match('^(%S+)%s+(%S+)%s+(%S+)')
        if name then out[#out + 1] = { name = name, up = st == 'up', ms = tonumber(ms) } end
    end
    f:close()
    return out
end

-- ---------------------------------------------------------------- drawing
-- Faint background stars, fixed positions inside the glass's top-left
local dust
local function draw_dust(cr)
    if not dust then
        dust = {}
        math.randomseed(7)
        while #dust < 26 do
            local x, y = math.random(-330, -40), math.random(-340, 0)
            if x * x + y * y < (GLASS_R - 30) ^ 2 then
                dust[#dust + 1] = { x, y, 0.15 + math.random() * 0.35, 0.5 + math.random() * 0.5 }
            end
        end
    end
    for _, d in ipairs(dust) do
        cairo_new_path(cr)
        cairo_arc(cr, CX + d[1], CY + d[2], d[4], 0, 2 * math.pi)
        cairo_set_source_rgba(cr, rgba(C.dust, d[3]))
        cairo_fill(cr)
    end
end

-- A four-pointed star: soft halo, thin cross flare, bright core.
-- k (0..1) scales size and brightness.
local function draw_star(cr, x, y, k, up)
    local col = up and C.star or C.down
    local glow = up and C.glow or C.down

    if up then
        local hr = 8 + 14 * k
        local g = cairo_pattern_create_radial(x, y, 0, x, y, hr)
        cairo_pattern_add_color_stop_rgba(g, 0, glow[1], glow[2], glow[3], 0.35 + 0.2 * k)
        cairo_pattern_add_color_stop_rgba(g, 0.4, glow[1], glow[2], glow[3], 0.12 + 0.1 * k)
        cairo_pattern_add_color_stop_rgba(g, 1, glow[1], glow[2], glow[3], 0)
        cairo_set_source(cr, g)
        cairo_arc(cr, x, y, hr, 0, 2 * math.pi)
        cairo_fill(cr)
        cairo_pattern_destroy(g)

        -- flare: lines fading out from the centre
        local fl = 4 + 5 * k        -- length of the four points
        cairo_set_line_width(cr, 1)
        for _, dir in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            local ex, ey = x + dir[1] * fl, y + dir[2] * fl
            local lg = cairo_pattern_create_linear(x, y, ex, ey)
            cairo_pattern_add_color_stop_rgba(lg, 0, col[1], col[2], col[3], 0.9)
            cairo_pattern_add_color_stop_rgba(lg, 1, col[1], col[2], col[3], 0)
            cairo_set_source(cr, lg)
            cairo_new_path(cr)
            cairo_move_to(cr, x, y)
            cairo_line_to(cr, ex, ey)
            cairo_stroke(cr)
            cairo_pattern_destroy(lg)
        end
    end

    cairo_new_path(cr)
    cairo_arc(cr, x, y, up and (1.6 + 1.2 * k) or 1.8, 0, 2 * math.pi)
    cairo_set_source_rgba(cr, col[1], col[2], col[3], up and 1 or 0.55)
    cairo_fill(cr)
end

local function brightness(s)
    if not s.up or not s.ms then return 0 end
    local t = (math.log(math.max(s.ms, 10)) - math.log(10)) / (math.log(SLOW_MS) - math.log(10))
    return 1 - 0.75 * math.min(1, math.max(0, t))
end

function conky_draw_vps()
    if conky_window == nil then return end
    local cs, owns_surface = window_surface()
    local cr = cairo_create(cs)
    cairo_set_antialias(cr, CAIRO_ANTIALIAS_BEST)
    cairo_set_font_options(cr, font_options())

    draw_dust(cr)

    -- place servers: known names at their STARS spot, others stacked below
    local pos = {}
    for _, p in ipairs(STARS) do pos[p.name] = p end
    local placed, extra_y = {}, nil
    for _, s in ipairs(read_status()) do
        local p = pos[s.name]
        if not p then
            local last = STARS[#STARS]
            extra_y = (extra_y or last.y) + 60
            p = { x = last.x + 10, y = extra_y }
        end
        placed[#placed + 1] = { s = s, x = CX + p.x, y = CY + p.y }
    end
    for _, p in ipairs(placed) do
        local s = p.s
        local k = brightness(s)
        draw_star(cr, p.x, p.y, k, s.up)
        local lx = p.x + 12 + 6 * k
        local w = text(cr, s.name:upper(), lx, p.y + 4, S.name, FONT_MEDIUM, C.name, s.up and 1 or 0.6, S.track)
        local info = s.up and s.ms and string.format('%d ms', math.floor(s.ms + 0.5)) or 'offline'
        text(cr, info, lx + w + 9, p.y + 4, S.ms, FONT, s.up and C.muted or C.down_text, 1)
    end

    cairo_destroy(cr)
    if owns_surface then cairo_surface_destroy(cs) end
end
