-- Claude usage widget fitted to the round spaceship window of the HDMI-A-1
-- wallpaper (claude.conf): the 5-hour and weekly limits are two short arcs
-- that follow the right side of the glass and fill from the bottom up. Each
-- arc's percentage continues the curve below it and its reset time above it;
-- the Claude logo sits beside them. Data: ~/.cache/claude-usage.json,
-- written by ~/.claude/statusline.sh.

local T = dofile(os.getenv('HOME') .. '/.config/conky/lua/theme.lua')

local CACHE = os.getenv('HOME') .. '/.cache/claude-usage.json'

-- The wallpaper's window in this conky window's coordinates: glass centred at
-- (960, 540) on HDMI-A-1, radius ~391 (see lua/media.lua); claude.conf
-- puts this window's top-left at (900, 120) on that monitor.
local CX, CY  = T.glass.x - 900, T.glass.y - 120
local GLASS_R = T.glass.r

-- Arcs (angles: 0 = right, -90 = top). They fill from the bottom end up.
local ARC_MID  = math.rad(-43)
local ARC_HALF = math.rad(12.5)
local A_START  = ARC_MID + ARC_HALF      -- bottom end, where the fill starts
local A_END    = ARC_MID - ARC_HALF      -- top end
local BARS = {
    { key = 'five_hour', title = '5-hour', r = GLASS_R - 21, color = T.colors.accent },   -- outer, lavender
    { key = 'seven_day', title = 'Weekly', r = GLASS_R - 41, color = T.colors.accent2 },  -- inner, light blue
}

-- Claude logo, centred on this point, left of the arcs
local BLOCK_A, BLOCK_R = math.rad(-43), 320

local FONT, FONT_MEDIUM = T.font, T.font_medium
local S = T.extend(T.sizes, { value = 13 })

local C = T.extend(T.colors, {
    muted = T.colors.muted_light,
    track = 'ffffff',   -- at low alpha
    logo  = 'e07a52',
})

-- ---------------------------------------------------------------- helpers
local rgba, font_options, advance, set_font, backdrop, window_surface = T.rgba, T.font_options, T.advance, T.set_font, T.backdrop, T.window_surface

local function width_of(cr, str, size, family, spacing)
    set_font(cr, size, family)
    return advance(cr, str) + (spacing or 0) * ((utf8.len(str) or #str) - 1)
end

-- Text with a soft dark shadow, for legibility over the wallpaper.
-- opts: family, spacing, align ('left' | 'center' | 'right'). Returns the width.
local function text(cr, str, x, y, size, hex, alpha, opts)
    opts = opts or {}
    local sp = opts.spacing or 0
    local w = width_of(cr, str, size, opts.family, sp)
    if opts.align == 'center' then x = x - w / 2
    elseif opts.align == 'right' then x = x - w end
    local function draw(dx, dy, r, g, b, a)
        cairo_set_source_rgba(cr, r, g, b, a)
        local px = x + dx
        if sp == 0 then
            cairo_move_to(cr, px, y + dy)
            cairo_show_text(cr, str)
        else
            for ch in str:gmatch(utf8.charpattern) do
                cairo_move_to(cr, px, y + dy)
                cairo_show_text(cr, ch)
                px = px + advance(cr, ch) + sp
            end
        end
    end
    for _, o in ipairs({ { 0, 1.5, 0.35 }, { 1, 1, 0.25 }, { -1, 1, 0.25 } }) do
        draw(o[1], o[2], 0, 0, 0.05, o[3])
    end
    draw(0, 0, rgba(hex, alpha))
    return w
end

local function arc_point(a, r)
    return CX + r * math.cos(a), CY + r * math.sin(a)
end

-- Draws parts ({ str, size, hex, family, spacing } ...) as one run of text
-- centred on angle `a` of radius `r`, upright and following the tangent.
local function text_on_arc(cr, parts, a, r)
    local w = 0
    for i, p in ipairs(parts) do
        p.w = width_of(cr, p[1], p[2], p[4], p[5])
        w = w + p.w + (i > 1 and 6 or 0)
    end
    local x, y = arc_point(a, r)
    cairo_save(cr)
    cairo_translate(cr, x, y)
    cairo_rotate(cr, a + math.pi / 2)
    local px = -w / 2
    for _, p in ipairs(parts) do
        text(cr, p[1], px, 4, p[2], p[3], 1, { family = p[4], spacing = p[5] })
        px = px + p.w + 6
    end
    cairo_restore(cr)
    return w
end

-- ---------------------------------------------------------------- data
local function read_usage()
    local f = io.open(CACHE, 'r')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    local now, out = os.time(), {}
    for _, b in ipairs(BARS) do
        local block = s:match('"' .. b.key .. '"%s*:%s*(%b{})')
        local pct   = block and tonumber(block:match('"used_percentage"%s*:%s*([%d%.]+)'))
        local reset = block and tonumber(block:match('"resets_at"%s*:%s*([%d%.]+)'))
        if pct and reset and reset > now then
            out[b.key] = { pct = math.min(pct, 100), reset = reset, left = reset - now }
        else
            out[b.key] = { pct = 0 }   -- window expired or unknown
        end
    end
    out.ts = tonumber(s:match('"ts"%s*:%s*([%d%.]+)'))
    return out
end

local DAYS = { 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat' }

local function reset_label(key, d)
    if not d.left then return '' end
    if key == 'seven_day' then
        local t = math.floor(d.reset)
        return DAYS[tonumber(os.date('%w', t)) + 1] .. os.date(' %H:%M', t)
    end
    local s = math.floor(d.left)
    if s >= 3600 then
        return string.format('%dh %dm', s // 3600, (s % 3600) // 60)
    end
    return string.format('%dm', math.max(1, s // 60))
end

-- ---------------------------------------------------------------- drawing
local function draw_logo(cr, cx, cy, r)
    cairo_new_path(cr)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_width(cr, 2.4)
    local lens = { 1.0, 0.82, 0.95, 0.78, 1.0, 0.86, 0.92, 0.8, 1.0, 0.84, 0.96, 0.8 }
    for i = 0, 11 do
        local a = i * math.pi / 6 + 0.13
        local l = r * lens[i + 1]
        cairo_move_to(cr, cx + 0.28 * r * math.cos(a), cy + 0.28 * r * math.sin(a))
        cairo_line_to(cr, cx + l * math.cos(a), cy + l * math.sin(a))
    end
    cairo_set_source_rgba(cr, rgba(C.logo, 1))
    cairo_stroke(cr)
end

local function draw_bar(cr, b, d)
    local av = A_START + (A_END - A_START) * d.pct / 100
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)

    cairo_set_line_width(cr, 8)          -- dark underlay for bright spots
    cairo_new_path(cr)
    cairo_arc_negative(cr, CX, CY, b.r, A_START, A_END)
    cairo_set_source_rgba(cr, 0.02, 0.03, 0.08, 0.35)
    cairo_stroke(cr)

    cairo_set_line_width(cr, 4)
    cairo_new_path(cr)
    cairo_arc_negative(cr, CX, CY, b.r, A_START, A_END)
    cairo_set_source_rgba(cr, rgba(C.track, 0.22))
    cairo_stroke(cr)

    if d.pct > 0 then
        cairo_new_path(cr)
        cairo_arc_negative(cr, CX, CY, b.r, A_START, av)
        cairo_set_source_rgba(cr, rgba(b.color, 1))
        cairo_stroke(cr)
    end

    local kx, ky = arc_point(av, b.r)
    cairo_new_path(cr)
    cairo_arc(cr, kx, ky, 7, 0, 2 * math.pi)
    cairo_set_source_rgba(cr, rgba(b.color, 0.25))
    cairo_fill(cr)
    cairo_arc(cr, kx, ky, 3.8, 0, 2 * math.pi)
    cairo_set_source_rgba(cr, rgba(b.color, 1))
    cairo_fill(cr)

    -- percentage continues the curve past the bottom end, reset time past the top
    local gap = 14
    local pct = { { string.format('%d%%', math.floor(d.pct + 0.5)), S.value, C.text, FONT_MEDIUM } }
    local pw = width_of(cr, pct[1][1], S.value, FONT_MEDIUM)
    text_on_arc(cr, pct, A_START + (gap + pw / 2) / b.r, b.r)
    local reset = reset_label(b.key, d)
    if reset ~= '' then
        local rw = width_of(cr, reset, S.small)
        text_on_arc(cr, { { reset, S.small, C.muted } }, A_END - (gap + rw / 2) / b.r, b.r)
    end
end

-- Claude logo, centred on (BLOCK_A, BLOCK_R)
local function draw_block(cr)
    local bx, by = arc_point(BLOCK_A, BLOCK_R)
    draw_logo(cr, bx, by, 11)
end

function conky_draw_claude()
    if conky_window == nil then return end
    local cs, owns_surface = window_surface()
    local cr = cairo_create(cs)
    cairo_set_antialias(cr, CAIRO_ANTIALIAS_BEST)
    cairo_set_font_options(cr, font_options())

    local data = read_usage() or {}
    for _, b in ipairs(BARS) do data[b.key] = data[b.key] or { pct = 0 } end

    local gx, gy = arc_point(ARC_MID - math.rad(3), 270)
    backdrop(cr, gx, gy, 200, 140)
    for _, b in ipairs(BARS) do draw_bar(cr, b, data[b.key]) end
    draw_block(cr)

    cairo_destroy(cr)
    if owns_surface then cairo_surface_destroy(cs) end
end
