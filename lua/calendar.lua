-- Next calendar events (calendar.conf), bottom-right of HDMI-A-1, above the
-- weather card: one row per event with the day (on the first event of each
-- day), the time and the title, a dot in the calendar's colour before it.
-- Same card style as the services widget: its left side follows the round
-- window, corner brackets, grain, sheen, line icon.
--
-- Reads ~/.cache/conky/calendar, written every 60 s by scripts/calendar.py.
-- Data older than STALE seconds is shown dimmed.

local T = dofile(os.getenv('HOME') .. '/.config/conky/lua/theme.lua')

local STATE = os.getenv('HOME') .. '/.cache/conky/calendar'
local STALE = 300
local MAX_ROWS = 5

local FONT, FONT_MEDIUM = T.font, T.font_medium
local S = T.sizes
local C = T.colors

-- Placement, in HDMI-A-1 monitor pixels. calendar.conf puts the window's
-- top-left at WIN_MX, WIN_MY. The card spans CARD_Y1..CARD_Y2 (the darkest
-- stretch of the wallpaper beside the round window, 20 px above the weather
-- card) and ends at x CARD_MX2, as the services and weather cards. Its left side follows the round window
-- like the services card's, never further left than LEFT_MX.
local WIN_MX, WIN_MY = 1200, 665
local CARD_Y1, CARD_Y2, CARD_MX2 = 706, 877, 1888
local GLASS_MX, GLASS_MY, FRAME_R, CURVE_GAP = T.glass.x, T.glass.y, T.glass.frame_r, 56
local LEFT_MX = 1240
local PAD_X, PAD_Y = 16, 14
-- extra indent of the event rows, right of PAD_X
local ROWS_INDENT = 38
local ROW_H = 21
-- column widths: day label, time
local DAY_W, TIME_W = 104, 96

-- the same in window coordinates
local GCX, GCY, GR = GLASS_MX - WIN_MX, GLASS_MY - WIN_MY, FRAME_R + CURVE_GAP
local CARD_Y, CARD_H, CARD_X2 = CARD_Y1 - WIN_MY, CARD_Y2 - CARD_Y1, CARD_MX2 - WIN_MX
local XMIN = LEFT_MX - WIN_MX

-- the card's left side at height y (window coordinates)
local function left_x(y)
    local dy = y - GCY
    if math.abs(dy) >= GR then return XMIN end
    return math.max(XMIN, GCX + math.sqrt(GR * GR - dy * dy))
end

-- ---------------------------------------------------------------- helpers
local rgba, font_options, advance, grain, window_surface = T.rgba, T.font_options, T.advance, T.grain, T.window_surface

local function set_font(cr, size, family)
    cairo_select_font_face(cr, family or FONT, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
end

-- opts: family, align ('left' | 'right'), spacing, max (width: cut with …)
-- Returns the width.
local function text(cr, str, x, y, size, hex, alpha, opts)
    opts = opts or {}
    set_font(cr, size, opts.family)
    local sp = opts.spacing or 0
    local function width_of(s) return advance(cr, s) + sp * ((utf8.len(s) or #s) - 1) end
    if opts.max and width_of(str) > opts.max then
        local chars = {}
        for ch in str:gmatch(utf8.charpattern) do chars[#chars + 1] = ch end
        while #chars > 0 and width_of(table.concat(chars) .. '…') > opts.max do chars[#chars] = nil end
        str = table.concat(chars):gsub('%s+$', '') .. '…'
    end
    local width = width_of(str)
    if opts.align == 'right' then x = x - width end
    cairo_set_source_rgba(cr, rgba(hex, alpha))
    for ch in str:gmatch(utf8.charpattern) do
        cairo_move_to(cr, x, y)
        cairo_show_text(cr, ch)
        x = x + advance(cr, ch) + sp
    end
    return width
end

-- ---------------------------------------------------------------- card style
-- Same as lua/services.lua: grain (T.grain), sheen, corner brackets.
local SHEEN_ALPHA = T.card.sheen

local function card(cr)
    local y1, y2, x2 = CARD_Y, CARD_Y + CARD_H, CARD_X2
    local function outline(inset)
        cairo_new_path(cr)
        cairo_move_to(cr, left_x(y1 + inset) + inset, y1 + inset)
        cairo_line_to(cr, x2 - inset, y1 + inset)
        cairo_line_to(cr, x2 - inset, y2 - inset)
        for yy = y2 - inset, y1 + inset, -2 do cairo_line_to(cr, left_x(yy) + inset, yy) end
        cairo_close_path(cr)
    end
    outline(1)
    cairo_set_source(cr, grain())
    cairo_fill(cr)

    outline(1)
    local g = cairo_pattern_create_linear(0, y1, 0, y2)
    cairo_pattern_add_color_stop_rgba(g, 0, 1, 1, 1, SHEEN_ALPHA)
    cairo_pattern_add_color_stop_rgba(g, 1, 1, 1, 1, 0)
    cairo_set_source(cr, g)
    cairo_fill(cr)
    cairo_pattern_destroy(g)

    -- corner brackets; the left ones' vertical legs follow the curved side,
    -- and a faint line runs along it between them
    local l = T.card.bracket_len
    local t1, t2, xr = y1 + 0.5, y2 - 0.5, x2 - 0.5
    local function lx(yy) return left_x(yy) + 0.5 end
    local function trace(ya, yb, move)
        local step = ya < yb and 2 or -2
        local yy = ya
        while (step > 0 and yy < yb) or (step < 0 and yy > yb) do
            if move then cairo_move_to(cr, lx(yy), yy); move = false else cairo_line_to(cr, lx(yy), yy) end
            yy = yy + step
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
    cairo_set_source_rgba(cr, rgba(C.bracket, T.card.bracket_alpha))
    cairo_stroke(cr)
    trace(t1 + l, t2 - l, true)
    cairo_set_source_rgba(cr, rgba(C.bracket, T.card.bracket_alpha * 0.6))
    cairo_stroke(cr)
end

-- Calendar page: frame, header line and two rings, ~12 px
local function icon(cr, cx, cy)
    cairo_new_path(cr)
    cairo_rectangle(cr, cx - 6, cy - 4.5, 12, 10.5)
    cairo_move_to(cr, cx - 6, cy - 1); cairo_line_to(cr, cx + 6, cy - 1)
    cairo_move_to(cr, cx - 3, cy - 6.5); cairo_line_to(cr, cx - 3, cy - 3)
    cairo_move_to(cr, cx + 3, cy - 6.5); cairo_line_to(cr, cx + 3, cy - 3)
    cairo_set_line_width(cr, 1.1)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
    cairo_set_source_rgba(cr, rgba(C.accent, 0.9))
    cairo_stroke(cr)
end

-- ---------------------------------------------------------------- data
local function read_state()
    local f = io.open(STATE, 'r')
    if not f then return nil end
    local out = { list = {} }
    for line in f:lines() do
        local ts = line:match('^ts%s+(%d+)')
        if ts then out.ts = tonumber(ts)
        else
            local s, e, allday, color, title = line:match('^(%d+)\t(%d+)\t([01])\t#(%x+)\t(.*)$')
            if s then
                out.list[#out.list + 1] = { s = tonumber(s), e = tonumber(e), allday = allday == '1',
                                            color = color, title = title }
            end
        end
    end
    f:close()
    return out
end

-- English names, whatever conky's locale
local DAYS = { 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday' }
local MONTHS = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' }

local function midnight(t)
    local d = os.date('*t', t)
    return os.time({ year = d.year, month = d.month, day = d.day, hour = 0 })
end

-- 'Today', 'Tomorrow', 'Saturday' (this week) or 'Sat 9 Jan'
local function day_label(t, now)
    local days = math.floor((midnight(t) - midnight(now)) / 86400 + 0.5)
    local d = os.date('*t', t)
    if days <= 0 then return 'Today', true end
    if days == 1 then return 'Tomorrow' end
    if days < 7 then return DAYS[d.wday] end
    return string.format('%s %d %s', DAYS[d.wday]:sub(1, 3), d.day, MONTHS[d.month])
end

local function hm(t) return os.date('%H:%M', t) end

local function time_label(ev, now)
    if ev.allday then
        if ev.e - ev.s > 86400 then
            local last = os.date('*t', ev.e - 1)
            return 'until ' .. DAYS[last.wday]:sub(1, 3) .. ' ' .. last.day
        end
        return 'all day'
    end
    if ev.s <= now then return 'until ' .. hm(ev.e) end
    if ev.e == ev.s then return hm(ev.s) end
    return hm(ev.s) .. ' – ' .. hm(ev.e)
end

-- ---------------------------------------------------------------- drawing
local function dot(cr, x, y, hex, alpha)
    cairo_new_path(cr)
    cairo_arc(cr, x, y, 6, 0, 2 * math.pi)
    cairo_set_source_rgba(cr, rgba(hex, 0.16 * alpha))
    cairo_fill(cr)
    cairo_new_path(cr)
    cairo_arc(cr, x, y, 3, 0, 2 * math.pi)
    cairo_set_source_rgba(cr, rgba(hex, alpha))
    cairo_fill(cr)
end

function conky_draw_calendar()
    if conky_window == nil then return end
    local cs, owns_surface = window_surface()
    local cr = cairo_create(cs)
    cairo_set_antialias(cr, CAIRO_ANTIALIAS_BEST)
    cairo_set_font_options(cr, font_options())

    card(cr)

    local now = os.time()
    local st = read_state()
    local stale = not st or not st.ts or now - st.ts > STALE
    local list = {}
    for _, ev in ipairs(st and st.list or {}) do
        if ev.e > now or (ev.e == ev.s and ev.s >= now) then list[#list + 1] = ev end
    end

    -- header: icon + AGENDA, today's date on the right
    local hy = CARD_Y + PAD_Y + 10
    local hx = left_x(hy - 10) + PAD_X
    icon(cr, hx + 6, hy - 4)
    text(cr, 'AGENDA', hx + 20, hy, S.heading, C.muted, 1, { family = FONT_MEDIUM, spacing = S.heading_track })
    local d = os.date('*t', now)
    local right = stale and 'no recent data' or string.format('%s %d %s', DAYS[d.wday], d.day, MONTHS[d.month])
    text(cr, right, CARD_X2 - PAD_X, hy, S.body, C.muted, 1, { align = 'right' })

    -- rows start PAD_X right of the curved side, at its rightmost along them
    local top = CARD_Y + PAD_Y + 26
    local rows = math.min(#list, MAX_ROWS)
    local x0 = math.max(left_x(top), left_x(top + rows * ROW_H)) + PAD_X + ROWS_INDENT
    local alpha = stale and 0.6 or 1
    if #list == 0 then
        text(cr, 'Nothing planned', x0, top + 14, S.body, C.muted, alpha)
    end
    local last_day
    for i = 1, rows do
        local ev = list[i]
        local y = top + (i - 1) * ROW_H + 14
        local day, today = day_label(ev.s, now)
        if ev.s < now then day, today = 'Today', true end   -- started earlier, still on
        if day ~= last_day then
            text(cr, day, x0, y, S.body, today and C.accent or C.text, alpha)
            last_day = day
        end
        local on = ev.s <= now
        text(cr, time_label(ev, now), x0 + DAY_W, y, S.small, on and C.accent or C.muted, alpha)
        local tx = x0 + DAY_W + TIME_W
        dot(cr, tx + 3, y - 4, ev.color:lower(), alpha)
        text(cr, ev.title, tx + 14, y, S.body, C.text, alpha, { max = CARD_X2 - PAD_X - tx - 14 })
    end

    cairo_destroy(cr)
    if owns_surface then cairo_surface_destroy(cs) end
end
