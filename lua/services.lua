-- Self-hosted services status (services.conf), top-right of HDMI-A-1:
-- one column per service with a vertical bar, green when up and red when
-- down, its name, latest ping and 24 h uptime. Same section style as the
-- system monitor and weather: corner brackets, grain, sheen, line icon.
--
-- Reads ~/.cache/conky/services, written every 60 s by scripts/services.sh
-- (Uptime Kuma status page set in .env). Data older than STALE
-- seconds turns the bars grey.

local T = dofile(os.getenv('HOME') .. '/.config/conky/lua/theme.lua')

local STATE = os.getenv('HOME') .. '/.cache/conky/services'
local STALE = 180

local FONT, FONT_MEDIUM = T.font, T.font_medium
local S = T.sizes

local C = T.colors

-- Placement, in HDMI-A-1 monitor pixels. services.conf puts the window's
-- top-left at WIN_MX, WIN_MY. The card spans CARD_Y1..CARD_Y2 (its top
-- level with the system monitor's, y 90) and ends at x CARD_MX2
-- (the weather box's right edge). Its left side follows the round window,
-- CURVE_GAP px outside the glass frame (as the weather and system widgets),
-- never further left than LEFT_MX.
local WIN_MX, WIN_MY = 1200, 70
local CARD_Y1, CARD_Y2, CARD_MX2 = 90, 178, 1888
local GLASS_MX, GLASS_MY, FRAME_R, CURVE_GAP = T.glass.x, T.glass.y, T.glass.frame_r, 56
local LEFT_MX = 1240
local PAD_X, PAD_Y = 16, 14

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

-- opts: family, align ('left' | 'right'), spacing. Returns the width.
local function text(cr, str, x, y, size, hex, alpha, opts)
    opts = opts or {}
    cairo_select_font_face(cr, opts.family or FONT, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    local sp = opts.spacing or 0
    local width = advance(cr, str) + sp * ((utf8.len(str) or #str) - 1)
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
-- Same as lua/system.lua: grain (T.grain), sheen, corner brackets.
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
    local l = 8
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

-- Server rack: three stacked units with a status light each, ~12 px
local function icon(cr, cx, cy)
    cairo_new_path(cr)
    for i = -1, 1 do
        local y = cy + i * 4.2 - 1.6
        cairo_new_sub_path(cr)
        cairo_rectangle(cr, cx - 6, y, 12, 3.2)
        cairo_move_to(cr, cx + 3, y + 1.6); cairo_line_to(cr, cx + 3.6, y + 1.6)
    end
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
            local name, st, ping, up = line:match('^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)')
            if name then
                out.list[#out.list + 1] = { name = name, status = tonumber(st) or -1,
                                            ping = tonumber(ping), uptime = tonumber(up) }
            end
        end
    end
    f:close()
    return out
end

local function color_of(s, stale)
    if stale or s.status < 0 then return C.unknown end
    if s.status == 1 then return C.up end
    if s.status == 0 then return C.down end
    return C.pending
end

-- ---------------------------------------------------------------- drawing
-- Status marker before each service: 'dot' (beside the name) or 'bar'
-- (vertical, beside name and detail)
local STATUS_STYLE = 'dot'

local function status_dot(cr, x, y, hex)
    -- soft halo, then the dot, centred on (x, y)
    cairo_new_path(cr)
    cairo_arc(cr, x, y, 7, 0, 2 * math.pi)
    cairo_set_source_rgba(cr, rgba(hex, 0.16))
    cairo_fill(cr)
    cairo_new_path(cr)
    cairo_arc(cr, x, y, 3.5, 0, 2 * math.pi)
    cairo_set_source_rgba(cr, rgba(hex, 1))
    cairo_fill(cr)
end

local function status_bar(cr, x, y, h, hex)
    -- soft halo, then the bar
    cairo_new_path(cr)
    cairo_rectangle(cr, x - 2, y - 1, 7, h + 2)
    cairo_set_source_rgba(cr, rgba(hex, 0.12))
    cairo_fill(cr)
    cairo_new_path(cr)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_width(cr, 3)
    cairo_move_to(cr, x + 1.5, y + 1.5)
    cairo_line_to(cr, x + 1.5, y + h - 1.5)
    cairo_set_source_rgba(cr, rgba(hex, 1))
    cairo_stroke(cr)
end

function conky_draw_services()
    if conky_window == nil then return end
    local cs, owns_surface = window_surface()
    local cr = cairo_create(cs)
    cairo_set_antialias(cr, CAIRO_ANTIALIAS_BEST)
    cairo_set_font_options(cr, font_options())

    local y = CARD_Y
    card(cr)

    local st = read_state()
    local stale = not st or not st.ts or os.time() - st.ts > STALE
    local list = st and st.list or {}

    -- header: icon + SERVICES, summary on the right
    local hy = y + PAD_Y + 10
    local hx = left_x(hy - 10) + PAD_X
    icon(cr, hx + 6, hy - 4)
    text(cr, 'SERVICES', hx + 20, hy, S.heading, C.muted, 1, { family = FONT_MEDIUM, spacing = S.heading_track })
    local bad = 0
    for _, s in ipairs(list) do
        if s.status == 0 then bad = bad + 1 end
    end
    local summary, scol
    if stale then summary, scol = 'no recent data', C.muted
    elseif bad > 0 then summary, scol = bad .. ' down', C.down
    end   -- all up: nothing, the green markers say it
    if summary then text(cr, summary, CARD_X2 - PAD_X, hy, S.body, scol, 1, { align = 'right' }) end

    -- one column per service
    -- columns start PAD_X right of the curved side, at its rightmost along them
    local top = y + PAD_Y + 26
    local x0 = math.max(left_x(top), left_x(top + 32)) + PAD_X
    local n = math.max(#list, 1)
    local cw = (CARD_X2 - PAD_X - x0) / n
    for i, s in ipairs(list) do
        local cx = math.floor(x0 + (i - 1) * cw)
        if STATUS_STYLE == 'dot' then
            status_dot(cr, cx + 4, top + 9, color_of(s, stale))   -- middle of the name's lowercase
        else
            status_bar(cr, cx, top, 32, color_of(s, stale))
        end
        text(cr, s.name, cx + 14, top + 13, S.body, C.text, stale and 0.6 or 1)
        local detail
        if s.status == 0 then detail = 'down'
        elseif s.status < 0 then detail = 'not on status page'
        else
            detail = (s.ping and string.format('%d ms', s.ping) or '–')
            if s.uptime then detail = detail .. ' · ' .. string.format('%g%%', math.floor(s.uptime * 1000 + 0.5) / 10) end
        end
        text(cr, detail, cx + 14, top + 29, S.small, s.status == 0 and C.down or C.muted, 1)
    end

    cairo_destroy(cr)
    if owns_surface then cairo_surface_destroy(cs) end
end
