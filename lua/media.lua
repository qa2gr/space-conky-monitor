-- Media widget fitted to the round spaceship window of the HDMI-A-1 wallpaper
-- (media.conf). The progress bar is an arc that follows the bottom of the
-- window's glass, with the elapsed and total times continuing along the same
-- curve; the cover, title, artist and album sit above it.
--
-- Reads the state written by scripts/media.py. Drawn in full while
-- something plays; when paused only the cover and "PAUSED" remain, for
-- HIDE_AFTER seconds, then nothing.

local T = dofile(os.getenv('HOME') .. '/.config/conky/lua/theme.lua')

local STATE      = os.getenv('HOME') .. '/.cache/conky/media-state'
local HIDE_AFTER = 60

-- The wallpaper's window, in this conky window's coordinates. On HDMI-A-1 the
-- glass is a circle centred at (960, 540) with radius ~391 px (measured from a
-- screenshot); media.conf puts this window's top-left at (560, 600) on that
-- monitor. If you move the window, move CX/CY the opposite way.
local CX, CY  = T.glass.x - 560, T.glass.y - 600
local GLASS_R = T.glass.r
local ARC_R   = GLASS_R - 21            -- progress arc, just inside the frame
-- The arc slides along the glass: ARC_MID is where its middle sits
-- (angles: 0 = right, 90 = bottom, smaller = further right), ARC_HALF its half-span.
local ARC_MID  = math.rad(78)
local ARC_HALF = math.rad(18)
local A_START  = ARC_MID + ARC_HALF      -- left end
local A_END    = ARC_MID - ARC_HALF      -- right end

local FONT, FONT_MEDIUM = T.font, T.font_medium
local S = T.extend(T.sizes, { title = 16 })

local C = T.extend(T.colors, {
    muted       = T.colors.muted_light,   -- busy background
    track       = 'ffffff',   -- drawn at low alpha so the earth shows through
})

-- Content block above the arc
local ART      = 72
local COVER_DY  = 20      -- cover only, lower than the text column by this much
local BLOCK_DX  = -25     -- shift of the cover + text block from the arc's middle (left < 0)
local BLOCK_GAP = 114     -- from the cover's top down to the arc's middle
-- The cover + text block is centred above the arc's middle
local MID_X   = CX + ARC_R * math.cos(ARC_MID)
local BLOCK_Y = CY + ARC_R * math.sin(ARC_MID) - BLOCK_GAP
local TEXT_GAP = 16
local TEXT_MAX = 220     -- longer titles/albums are cut with "…" so they stay clear of the end time

-- ---------------------------------------------------------------- helpers
local rgba, font_options, advance, set_font, backdrop, window_surface = T.rgba, T.font_options, T.advance, T.set_font, T.backdrop, T.window_surface

local function fit(cr, str, width)
    if advance(cr, str) <= width then return str end
    local chars = {}
    for ch in str:gmatch(utf8.charpattern) do chars[#chars + 1] = ch end
    while #chars > 0 do
        chars[#chars] = nil
        local s = table.concat(chars):gsub('%s+$', '') .. '…'
        if advance(cr, s) <= width then return s end
    end
    return '…'
end

-- Text with a soft dark shadow, for legibility over the wallpaper.
-- opts: family, spacing, max. Returns the drawn width.
local function text(cr, str, x, y, size, hex, alpha, opts)
    opts = opts or {}
    set_font(cr, size, opts.family)
    if opts.max then str = fit(cr, str, opts.max) end
    local sp = opts.spacing or 0
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
    return advance(cr, str) + sp * ((utf8.len(str) or #str) - 1)
end

local function width_of(cr, str, size, family, max)
    set_font(cr, size, family)
    if max then str = fit(cr, str, max) end
    return advance(cr, str)
end

local function rounded_rect(cr, x, y, w, h, r)
    cairo_new_path(cr)
    cairo_arc(cr, x + w - r, y + r,     r, -math.pi / 2, 0)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
    cairo_arc(cr, x + r,     y + h - r, r, math.pi / 2, math.pi)
    cairo_arc(cr, x + r,     y + r,     r, math.pi, 3 * math.pi / 2)
    cairo_close_path(cr)
end

local function fmt_time(s)
    s = math.max(0, math.floor(s or 0))
    if s >= 3600 then
        return string.format('%d:%02d:%02d', s // 3600, (s % 3600) // 60, s % 60)
    end
    return string.format('%d:%02d', s // 60, s % 60)
end

-- ---------------------------------------------------------------- data
local function read_state()
    local f = io.open(STATE, 'r')
    if not f then return nil end
    local l = {}
    for line in f:lines() do l[#l + 1] = line end
    f:close()
    if not l[1] or l[1] == '' then return nil end
    return { status = l[1], title = l[2] or '', artist = l[3] or '',
             pos = tonumber(l[4]) or 0, len = tonumber(l[5]) or 0, art = l[6] or '',
             album = l[7] or '' }
end

local cover_path, cover_surface
local function cover(path)
    if path == '' then return nil end
    if path ~= cover_path then
        if cover_surface then cairo_surface_destroy(cover_surface) end
        cover_surface, cover_path = nil, nil
        local s = cairo_image_surface_create_from_png(path)
        if cairo_surface_status(s) == CAIRO_STATUS_SUCCESS then
            cover_surface, cover_path = s, path
        else
            cairo_surface_destroy(s)
        end
    end
    return cover_surface
end

-- ---------------------------------------------------------------- drawing

local function draw_note(cr, cx, cy)
    cairo_set_line_width(cr, 2.4)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
    cairo_set_source_rgba(cr, rgba(C.muted, 0.9))
    cairo_new_path(cr)
    cairo_arc(cr, cx - 8, cy + 8, 4, 0, 2 * math.pi)
    cairo_stroke(cr)
    cairo_new_path(cr)
    cairo_arc(cr, cx + 7, cy + 5, 4, 0, 2 * math.pi)
    cairo_stroke(cr)
    cairo_move_to(cr, cx - 4, cy + 8)
    cairo_line_to(cr, cx - 4, cy - 10)
    cairo_line_to(cr, cx + 11, cy - 13)
    cairo_line_to(cr, cx + 11, cy + 5)
    cairo_stroke(cr)
end

local function draw_cover(cr, x, y, art)
    -- shadow, then the cover clipped to a rounded square
    rounded_rect(cr, x - 1, y + 2, ART + 2, ART + 2, 11)
    cairo_set_source_rgba(cr, 0, 0, 0.05, 0.35)
    cairo_fill(cr)
    rounded_rect(cr, x, y, ART, ART, 10)
    local img = cover(art)
    if img then
        cairo_save(cr)
        cairo_clip(cr)
        local sc = ART / cairo_image_surface_get_width(img)
        cairo_translate(cr, x, y)
        cairo_scale(cr, sc, sc)
        cairo_set_source_surface(cr, img, 0, 0)
        cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_BEST)
        cairo_paint(cr)
        cairo_restore(cr)
    else
        cairo_set_source_rgba(cr, rgba(C.placeholder, 0.95))
        cairo_fill(cr)
        draw_note(cr, x + ART / 2, y + ART / 2)
    end
end

local function arc_point(a, r)
    return CX + r * math.cos(a), CY + r * math.sin(a)
end

-- Draws str centred on angle `a`, rotated to follow the circle's tangent
local function text_on_arc(cr, str, a, r, size, hex)
    set_font(cr, size)
    local w = advance(cr, str)
    local x, y = arc_point(a, r)
    cairo_save(cr)
    cairo_translate(cr, x, y)
    cairo_rotate(cr, a - math.pi / 2)
    text(cr, str, -w / 2, size * 0.36, size, hex, 1)
    cairo_restore(cr)
    return w
end

local function draw_progress(cr, st)
    local live = st.len < 0          -- live stream: no duration, no knob
    local frac = st.len > 0 and math.min(1, st.pos / st.len) or 0
    local av = A_START - (A_START - A_END) * frac

    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    -- dark underlay so the arc reads over bright spots, then track, then value
    cairo_set_line_width(cr, 8)
    cairo_new_path(cr)
    cairo_arc_negative(cr, CX, CY, ARC_R, A_START, A_END)
    cairo_set_source_rgba(cr, 0.02, 0.03, 0.08, 0.35)
    cairo_stroke(cr)

    cairo_set_line_width(cr, 4)
    cairo_new_path(cr)
    cairo_arc_negative(cr, CX, CY, ARC_R, A_START, A_END)
    cairo_set_source_rgba(cr, rgba(C.track, 0.22))
    cairo_stroke(cr)

    if frac > 0 then
        cairo_new_path(cr)
        cairo_arc_negative(cr, CX, CY, ARC_R, A_START, av)
        cairo_set_source_rgba(cr, rgba(C.accent, 1))
        cairo_stroke(cr)
    end

    if live then
        cairo_new_path(cr)
        cairo_arc_negative(cr, CX, CY, ARC_R, A_START, A_END)
        cairo_set_source_rgba(cr, rgba(C.accent, 0.55))
        cairo_stroke(cr)
    end

    local kx, ky = arc_point(av, ARC_R)
    if not live then
        cairo_new_path(cr)
        cairo_arc(cr, kx, ky, 8, 0, 2 * math.pi)
        cairo_set_source_rgba(cr, rgba(C.accent, 0.25))
        cairo_fill(cr)
        cairo_arc(cr, kx, ky, 4.5, 0, 2 * math.pi)
        cairo_set_source_rgba(cr, rgba(C.accent, 1))
        cairo_fill(cr)
    end

    -- times continue the curve past each end
    local gap = 16
    local function at_end(str, a0, dir, hex)
        set_font(cr, S.small)
        local w = advance(cr, str)
        text_on_arc(cr, str, a0 + dir * (gap + w / 2) / ARC_R, ARC_R, S.small, hex or C.text)
    end
    at_end(fmt_time(st.pos), A_START, 1)
    if live then
        at_end('LIVE', A_END, -1, C.accent)
    elseif st.len > 0 then
        at_end(fmt_time(st.len), A_END, -1)
    end
end

local last_playing = nil

function conky_draw_media()
    if conky_window == nil then return end
    local st = read_state()
    local now = os.time()
    if st and st.status == 'Playing' then last_playing = now end
    if not st or not last_playing or now - last_playing > HIDE_AFTER then return end
    local playing = st.status == 'Playing'

    local cs, owns_surface = window_surface()
    local cr = cairo_create(cs)
    cairo_set_antialias(cr, CAIRO_ANTIALIAS_BEST)
    cairo_set_font_options(cr, font_options())

    local label = playing and 'NOW PLAYING' or 'PAUSED'
    local lines = {}
    if playing then
        lines = {
            { st.title,  S.title, C.text,   nil, 25 },
            { st.artist, S.body,  C.accent, nil, 21 },
            { st.album ~= st.title and st.album or '', S.body, C.muted, nil, 19 },
        }
    end

    -- centre the cover + text block on the window's axis
    local tw = width_of(cr, label, S.caption, FONT_MEDIUM) + S.track * #label
    for _, l in ipairs(lines) do
        if l[1] ~= '' then tw = math.max(tw, width_of(cr, l[1], l[2], l[4], TEXT_MAX)) end
    end
    tw = math.min(tw, TEXT_MAX)
    local bw = ART + TEXT_GAP + tw
    local x0 = math.floor(MID_X + BLOCK_DX - bw / 2)
    local tx = x0 + ART + TEXT_GAP

    backdrop(cr, MID_X + BLOCK_DX / 2, BLOCK_Y + ART / 2 + 30, bw / 2 + 110, ART / 2 + 110)
    draw_cover(cr, x0, BLOCK_Y + COVER_DY, st.art)

    -- vertically centre the text column on the cover
    local th = 14
    for _, l in ipairs(lines) do if l[1] ~= '' then th = th + l[5] end end
    local y = BLOCK_Y + (ART - th) / 2 + 10
    text(cr, label, tx, y, S.caption, C.muted, 1, { family = FONT_MEDIUM, spacing = S.track })
    for _, l in ipairs(lines) do
        if l[1] ~= '' then
            y = y + l[5]
            text(cr, l[1], tx, y, l[2], l[3], 1, { family = l[4], max = TEXT_MAX })
        end
    end

    if playing then draw_progress(cr, st) end

    cairo_destroy(cr)
    if owns_surface then cairo_surface_destroy(cs) end
end
