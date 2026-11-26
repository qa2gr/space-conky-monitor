-- The whole system.conf widget (kernel/uptime, memory, processor, GPU, disks, network), drawn with cairo.
-- Layout follows the mock-up: big percentage on the left, bar or 60 s graph
-- on the right; VRAM bar under the GPU graph.
-- Palette, fonts and sizes come from lua/theme.lua.
--
-- system.conf has no visible text; its minimum_height sets the window height
-- the cards are spread over.
--
-- Data comes straight from the kernel, sampled once per conky update (1 s):
--   /proc/stat                     CPU usage
--   /proc/meminfo                  memory (used = total - available)
--   /sys/class/drm/card*/device    GPU busy %, VRAM (the card with most VRAM)
--   hwmon                          CPU Tctl (k10temp); GPU edge and VRAM (mem) temperatures
--   /sys/class/net/*/statistics    network rates, summed over physical interfaces
--   df                             disk usage of DISKS, every 30 s

local T = dofile(os.getenv('HOME') .. '/.config/conky/lua/theme.lua')

-- Offset of the block below conky's text area
local ANCHOR_Y = 0

local FONT, FONT_MEDIUM = T.font, T.font_medium
local S = T.extend(T.sizes, { value = 28 })

local C = T.extend(T.colors, {
    upload      = T.colors.accent2,   -- upload graph
    upload_fill = T.colors.fill2,
})

-- Geometry, relative to the block's top-left corner
local W_BASE  = 400       -- content width without CURVE (and for measuring)
local W       = W_BASE
local GX      = 95        -- left edge of bars and graphs
local GRAPH_H = 56
local HIST    = 60        -- samples kept = seconds shown

-- Each section sits in a card outlined by L-shaped brackets at the corners
-- (no background). CARD_PX/PY is the padding inside. The cards are spread
-- evenly over the window's height (minimum_size in system.conf), at least
-- CARD_GAP apart.
local CARD_PX, CARD_PY, CARD_GAP = 16, 14, 18
local BRACKET, BRACKET_ALPHA, BRACKET_LEN = T.colors.bracket, T.card.bracket_alpha, T.card.bracket_len

-- Partitions shown in the DISKS section: SYSTEM_DISKS in .env, name:mount
-- pairs (root only when unset). color / fill: gauge colours; the first disk
-- is drawn as the upload graph, the others in the accent colour.
local DISKS = {}
for _, pair in ipairs(T.env_list('SYSTEM_DISKS')) do
    local name, mount = pair:match('^([^:]+):(.+)$')
    if name then DISKS[#DISKS + 1] = { name = name, mount = mount } end
end
if #DISKS == 0 then DISKS[1] = { name = 'root', mount = '/' } end
DISKS[1].color, DISKS[1].fill = C.upload, C.upload_fill

-- ---------------------------------------------------------------- helpers
local rgba, font_options, advance, grain, window_surface = T.rgba, T.font_options, T.advance, T.grain, T.window_surface

-- opts: family, align ('left' | 'center' | 'right'), spacing (px per letter)
-- Returns the drawn width.
local function text(cr, str, x, y, size, hex, alpha, opts)
    opts = opts or {}
    cairo_select_font_face(cr, opts.family or FONT, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    local sp = opts.spacing or 0
    local width = advance(cr, str) + sp * ((utf8.len(str) or #str) - 1)
    if opts.align == 'center' then x = x - width / 2
    elseif opts.align == 'right' then x = x - width end
    cairo_set_source_rgba(cr, rgba(hex, alpha))
    if sp == 0 then
        cairo_move_to(cr, x, y)
        cairo_show_text(cr, str)
    else
        for ch in str:gmatch(utf8.charpattern) do
            cairo_move_to(cr, x, y)
            cairo_show_text(cr, ch)
            x = x + advance(cr, ch) + sp
        end
    end
    return width
end

local function caption(cr, str, x, y, align)
    text(cr, str, x, y, S.caption, C.muted, 1, { family = FONT_MEDIUM, spacing = S.track, align = align })
end

-- ---------------------------------------------------------------- icons
-- Small line icons for the section titles, drawn around (cx, cy), ~12 px.
local function rrect(cr, x, y, w, h, r)
    cairo_new_sub_path(cr)
    cairo_arc(cr, x + w - r, y + r,     r, -math.pi / 2, 0)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
    cairo_arc(cr, x + r,     y + h - r, r, math.pi / 2, math.pi)
    cairo_arc(cr, x + r,     y + r,     r, math.pi, 3 * math.pi / 2)
    cairo_close_path(cr)
end

local ICONS = {
    kernel = function(cr, cx, cy)        -- terminal: window with a prompt
        rrect(cr, cx - 6, cy - 5, 12, 10, 1.5)
        cairo_move_to(cr, cx - 3.5, cy - 2); cairo_line_to(cr, cx - 1, cy); cairo_line_to(cr, cx - 3.5, cy + 2)
        cairo_move_to(cr, cx + 0.5, cy + 2.5); cairo_line_to(cr, cx + 3.5, cy + 2.5)
    end,
    uptime = function(cr, cx, cy)        -- clock
        cairo_new_sub_path(cr)
        cairo_arc(cr, cx, cy, 5.5, 0, 2 * math.pi)
        cairo_move_to(cr, cx, cy - 3.2); cairo_line_to(cr, cx, cy); cairo_line_to(cr, cx + 2.4, cy + 1.4)
    end,
    cpu = function(cr, cx, cy)           -- chip with pins on all sides
        rrect(cr, cx - 4, cy - 4, 8, 8, 1)
        cairo_rectangle(cr, cx - 1.5, cy - 1.5, 3, 3)
        for _, o in ipairs({ -2, 0, 2 }) do
            cairo_move_to(cr, cx + o, cy - 4); cairo_line_to(cr, cx + o, cy - 6.5)
            cairo_move_to(cr, cx + o, cy + 4); cairo_line_to(cr, cx + o, cy + 6.5)
            cairo_move_to(cr, cx - 4, cy + o); cairo_line_to(cr, cx - 6.5, cy + o)
            cairo_move_to(cr, cx + 4, cy + o); cairo_line_to(cr, cx + 6.5, cy + o)
        end
    end,
    memory = function(cr, cx, cy)        -- RAM stick: chips on top, contacts below
        rrect(cr, cx - 6.5, cy - 3.5, 13, 6, 1)
        for _, o in ipairs({ -4, -0.5, 3 }) do cairo_rectangle(cr, cx + o - 0.5, cy - 1.5, 2, 2) end
        for i = -5, 5, 2 do cairo_move_to(cr, cx + i, cy + 2.5); cairo_line_to(cr, cx + i, cy + 4.5) end
    end,
    gpu = function(cr, cx, cy)           -- graphics card: board, fan, bracket
        cairo_move_to(cr, cx - 6.5, cy - 5); cairo_line_to(cr, cx - 6.5, cy + 5)
        rrect(cr, cx - 5, cy - 4, 11.5, 7, 1)
        cairo_new_sub_path(cr)
        cairo_arc(cr, cx + 2, cy - 0.5, 2.2, 0, 2 * math.pi)
        cairo_move_to(cr, cx - 3, cy + 3); cairo_line_to(cr, cx - 3, cy + 5); cairo_line_to(cr, cx + 1, cy + 5)
    end,
    disks = function(cr, cx, cy)         -- drive: stacked cylinder
        cairo_save(cr); cairo_translate(cr, cx, cy - 3.5); cairo_scale(cr, 1, 0.38)
        cairo_new_sub_path(cr); cairo_arc(cr, 0, 0, 5.5, 0, 2 * math.pi)
        cairo_restore(cr)
        cairo_move_to(cr, cx - 5.5, cy - 3.5); cairo_line_to(cr, cx - 5.5, cy + 3.5)
        cairo_move_to(cr, cx + 5.5, cy - 3.5); cairo_line_to(cr, cx + 5.5, cy + 3.5)
        for _, dy in ipairs({ 0, 3.5 }) do
            cairo_save(cr); cairo_translate(cr, cx, cy + dy); cairo_scale(cr, 1, 0.38)
            cairo_new_sub_path(cr); cairo_arc(cr, 0, 0, 5.5, 0, math.pi)
            cairo_restore(cr)
        end
    end,
    network = function(cr, cx, cy)       -- globe
        cairo_new_sub_path(cr)
        cairo_arc(cr, cx, cy, 5.5, 0, 2 * math.pi)
        cairo_save(cr); cairo_translate(cr, cx, cy); cairo_scale(cr, 0.45, 1)
        cairo_new_sub_path(cr); cairo_arc(cr, 0, 0, 5.5, 0, 2 * math.pi)
        cairo_restore(cr)
        cairo_move_to(cr, cx - 5.5, cy); cairo_line_to(cr, cx + 5.5, cy)
    end,
}
local ICON_W = 20   -- icon + space before the title

local function draw_icon(cr, name, cx, cy)
    cairo_new_path(cr)
    ICONS[name](cr, cx, cy)
    cairo_set_line_width(cr, 1.2)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
    cairo_set_source_rgba(cr, rgba(C.accent, 0.9))
    cairo_stroke(cr)
end

-- Section title, with its icon before it (also for right-aligned titles)
local function heading(cr, str, x, y, align, icon)
    local opts = { family = FONT_MEDIUM, spacing = S.heading_track, align = align }
    if icon then
        if align == 'right' then
            cairo_select_font_face(cr, FONT_MEDIUM, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
            cairo_set_font_size(cr, S.heading)
            local w = advance(cr, str) + S.heading_track * ((utf8.len(str) or #str) - 1)
            draw_icon(cr, icon, x - w - ICON_W + 6, y - 4)
        else
            draw_icon(cr, icon, x + 6, y - 4)
            x = x + ICON_W
        end
    end
    text(cr, str, x, y, S.heading, C.muted, 1, opts)
end

-- "main / rest", right-aligned at x: main in text colour, " / rest" muted
local function ratio(cr, main, rest, x, y)
    local w = text(cr, ' / ' .. rest, x, y, S.body, C.muted, 1, { align = 'right' })
    text(cr, main, x - w, y, S.body, C.text, 1, { align = 'right' })
end

-- Decimal comma, as in the mock-up
local function num(v, decimals)
    return (string.format('%.' .. decimals .. 'f', v):gsub('%.', ','))
end

local function hline(cr, x1, x2, y, alpha, dashed)
    cairo_new_path(cr)
    cairo_set_line_width(cr, 1)
    if dashed then cairo_set_dash(cr, { 2, 4 }, 2, 0) end
    cairo_move_to(cr, x1, math.floor(y) + 0.5)
    cairo_line_to(cr, x2, math.floor(y) + 0.5)
    cairo_set_source_rgba(cr, rgba(C.line, alpha))
    cairo_stroke(cr)
    if dashed then cairo_set_dash(cr, {}, 0, 0) end
end

local function knob(cr, x, y, color)
    color = color or C.accent
    cairo_new_path(cr)
    cairo_arc(cr, x, y, 7, 0, 2 * math.pi)
    cairo_set_source_rgba(cr, rgba(color, 0.22))
    cairo_fill(cr)
    cairo_arc(cr, x, y, 3.8, 0, 2 * math.pi)
    cairo_set_source_rgba(cr, rgba(color, 1))
    cairo_fill(cr)
end

local function bar(cr, x1, x2, y, pct)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_width(cr, 4)
    cairo_new_path(cr)
    cairo_move_to(cr, x1, y)
    cairo_line_to(cr, x2, y)
    cairo_set_source_rgba(cr, rgba(C.track, 1))
    cairo_stroke(cr)
    local xv = x1 + (x2 - x1) * math.max(0, math.min(pct, 100)) / 100
    if xv > x1 then
        cairo_new_path(cr)
        cairo_move_to(cr, x1, y)
        cairo_line_to(cr, xv, y)
        cairo_set_source_rgba(cr, rgba(C.accent, 1))
        cairo_stroke(cr)
    end
    knob(cr, xv, y)
end

-- "60 s … Now" labels under a graph, baseline at y
local function time_axis(cr, x1, x2, y)
    text(cr, '60 s', x1, y, S.small, C.muted, 1)
    for i, lbl in ipairs({ '45 s', '30 s', '15 s' }) do
        text(cr, lbl, x1 + (x2 - x1) * i / 4, y, S.small, C.muted, 1, { align = 'center' })
    end
    text(cr, 'Now', x2, y, S.small, C.muted, 1, { align = 'right' })
end

-- Area graph of `hist` (oldest first), right-aligned so "Now" is the last sample.
-- o: h (height), max (value at the top, default 100), color, fill,
--    grid (fractions from the top drawn as dashed lines), axis (draw time labels)
local function graph(cr, x1, x2, top, hist, o)
    o = o or {}
    local h, max = o.h or GRAPH_H, o.max or 100
    local color, fill = o.color or C.accent, o.fill or C.fill
    local bottom = top + h
    for _, f in ipairs(o.grid or { 0, 0.5 }) do hline(cr, x1, x2, top + h * f, 0.12, true) end
    hline(cr, x1, x2, bottom, 0.08)

    local n = #hist
    if n >= 2 then
        local step = (x2 - x1) / (HIST - 1)
        local x0 = x2 - (n - 1) * step
        local function py(v) return bottom - 2 - (h - 4) * math.min(v / max, 1) end

        cairo_new_path(cr)
        cairo_move_to(cr, x0, py(hist[1]))
        for i = 2, n do cairo_line_to(cr, x0 + (i - 1) * step, py(hist[i])) end
        local line = cairo_copy_path(cr)
        cairo_line_to(cr, x2, bottom)
        cairo_line_to(cr, x0, bottom)
        cairo_close_path(cr)
        local g = cairo_pattern_create_linear(0, top, 0, bottom)
        cairo_pattern_add_color_stop_rgba(g, 0, rgba(fill, 0.95))
        cairo_pattern_add_color_stop_rgba(g, 1, rgba(fill, 0.15))
        cairo_set_source(cr, g)
        cairo_fill(cr)
        cairo_pattern_destroy(g)

        cairo_new_path(cr)
        cairo_append_path(cr, line)
        cairo_path_destroy(line)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_set_line_width(cr, 1.6)
        cairo_set_source_rgba(cr, rgba(color, 1))
        cairo_stroke(cr)

        knob(cr, x2, py(hist[n]), color)
    end

    if o.axis ~= false then time_axis(cr, x1, x2, bottom + 16) end
end

local function push(hist, v)
    hist[#hist + 1] = v
    if #hist > HIST then table.remove(hist, 1) end
end

-- ---------------------------------------------------------------- data
local function read_file(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return s
end

local function cpu_name()
    local s = read_file('/proc/cpuinfo') or ''
    local name = s:match('model name%s*:%s*([^\n]+)') or 'CPU'
    return (name:gsub('%s+%d+%-Core Processor', ''):gsub('%s+$', ''))
end

-- The discrete GPU is the card with the most VRAM (card numbers can change between boots)
local function find_gpu()
    local best, best_total
    local p = io.popen('ls -d /sys/class/drm/card[0-9]*/device 2>/dev/null')
    for dev in p:lines() do
        if not dev:find('%-') then
            local total = tonumber(read_file(dev .. '/mem_info_vram_total') or '')
            if total and (not best_total or total > best_total) then best, best_total = dev, total end
        end
    end
    p:close()
    return best
end

local function gpu_name()
    local p = io.popen('amdgpu_top -d --single 2>/dev/null')
    local s = p and p:read('*a') or ''
    if p then p:close() end
    return s:match('device_name:%s*"([^"]+)"') or 'GPU'
end

-- { label = path of tempN_input } for the hwmon directories matching `glob`
local function temp_inputs(glob)
    local out = {}
    local p = io.popen('ls -d ' .. glob .. ' 2>/dev/null')
    for dir in p:lines() do
        out._name = out._name or {}
        out._name[dir] = (read_file(dir .. '/name') or ''):gsub('%s+$', '')
        local q = io.popen('ls ' .. dir .. ' 2>/dev/null')
        for f in q:lines() do
            local n = f:match('^temp(%d+)_label$')
            if n then
                local label = (read_file(dir .. '/' .. f) or ''):gsub('%s+$', '')
                out[out._name[dir] .. ':' .. label] = dir .. '/temp' .. n .. '_input'
            end
        end
        q:close()
    end
    p:close()
    out._name = nil
    return out
end

local function read_temp(path)
    local v = path and tonumber(read_file(path) or '')
    return v and string.format('%d °C', math.floor(v / 1000 + 0.5)) or nil
end

local static     -- names, GPU path and sensor paths, looked up once
local cpu_hist, gpu_hist, rx_hist, tx_hist = {}, {}, {}, {}
local prev_total, prev_idle

-- Returns cpu % since the previous call (all cores)
local function sample_cpu()
    local s = read_file('/proc/stat') or ''
    local fields, total = {}, 0
    for v in s:match('^cpu%s+([^\n]+)'):gmatch('%d+') do
        fields[#fields + 1] = tonumber(v)
        total = total + tonumber(v)
    end
    local idle = fields[4] + (fields[5] or 0)
    local pct = 0
    if prev_total and total > prev_total then
        pct = (1 - (idle - prev_idle) / (total - prev_total)) * 100
    end
    prev_total, prev_idle = total, idle
    return math.max(0, pct)
end

local function sample_mem()
    local s = read_file('/proc/meminfo') or ''
    local total = tonumber(s:match('MemTotal:%s*(%d+)')) or 1
    local avail = tonumber(s:match('MemAvailable:%s*(%d+)')) or 0
    local gib = 1024 * 1024
    return { pct = (total - avail) / total * 100, used = (total - avail) / gib,
             free = avail / gib, total = total / gib }
end

local function sample_gpu()
    local dev = static.gpu
    if not dev then return { pct = 0, used = 0, total = 0 } end
    local mib = 1024 * 1024
    return {
        pct   = tonumber(read_file(dev .. '/gpu_busy_percent') or '') or 0,
        used  = (tonumber(read_file(dev .. '/mem_info_vram_used') or '') or 0) / mib,
        total = (tonumber(read_file(dev .. '/mem_info_vram_total') or '') or 0) / mib,
    }
end

-- Physical interfaces (those backed by a device: eno1, wlan0, USB adapters...);
-- skips lo, bridges, docker/veth and VPN tunnels so traffic isn't counted twice.
local net_ifaces, net_scan_at = {}, -math.huge
local prev_rx, prev_tx, prev_t

local function uptime()
    return tonumber((read_file('/proc/uptime') or ''):match('^[%d%.]+')) or os.time()
end

-- Returns download and upload rates in bytes/s
local function sample_net()
    local now = uptime()
    if now - net_scan_at > 30 then   -- rescan now and then for hot-plugged adapters
        net_ifaces, net_scan_at = {}, now
        local p = io.popen('ls /sys/class/net')
        for i in p:lines() do
            if io.open('/sys/class/net/' .. i .. '/device/uevent', 'r') then net_ifaces[#net_ifaces + 1] = i end
        end
        p:close()
    end
    local rx, tx = 0, 0
    for _, i in ipairs(net_ifaces) do
        local d = '/sys/class/net/' .. i .. '/statistics/'
        rx = rx + (tonumber(read_file(d .. 'rx_bytes') or '') or 0)
        tx = tx + (tonumber(read_file(d .. 'tx_bytes') or '') or 0)
    end
    local down, up = 0, 0
    if prev_t and now > prev_t then
        down = math.max(0, rx - prev_rx) / (now - prev_t)
        up   = math.max(0, tx - prev_tx) / (now - prev_t)
    end
    prev_rx, prev_tx, prev_t = rx, tx, now
    return down, up
end

-- bytes/s -> "12,4", "MB/s" (decimal units)
-- One half of a mirrored graph (network): grows up (o.dir 1) or down
-- (o.dir -1) from the baseline at y = base, at most o.h px, scaled to o.max.
-- Same look as graph(): gradient fill, strongest at the outer edge, line and knob.
local function half_graph(cr, x1, x2, base, hist, o)
    local h, max, dir = o.h, o.max, o.dir
    local edge = base - dir * h
    hline(cr, x1, x2, edge, 0.12, true)

    local n = #hist
    if n < 2 then return end
    local step = (x2 - x1) / (HIST - 1)
    local x0 = x2 - (n - 1) * step
    -- 1 px off the baseline, so both lines show side by side when idle
    local function py(v) return base - dir * (1 + (h - 3) * math.min(v / max, 1)) end

    cairo_new_path(cr)
    cairo_move_to(cr, x0, py(hist[1]))
    for i = 2, n do cairo_line_to(cr, x0 + (i - 1) * step, py(hist[i])) end
    local line = cairo_copy_path(cr)
    cairo_line_to(cr, x2, base)
    cairo_line_to(cr, x0, base)
    cairo_close_path(cr)
    local g = cairo_pattern_create_linear(0, edge, 0, base)
    cairo_pattern_add_color_stop_rgba(g, 0, rgba(o.fill, 0.95))
    cairo_pattern_add_color_stop_rgba(g, 1, rgba(o.fill, 0.15))
    cairo_set_source(cr, g)
    cairo_fill(cr)
    cairo_pattern_destroy(g)

    cairo_new_path(cr)
    cairo_append_path(cr, line)
    cairo_path_destroy(line)
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
    cairo_set_line_width(cr, 1.6)
    cairo_set_source_rgba(cr, rgba(o.color, 1))
    cairo_stroke(cr)

    knob(cr, x2, py(hist[n]), o.color)
end

local function rate(v)
    local units = { 'B/s', 'KB/s', 'MB/s', 'GB/s' }
    local i = 1
    while v >= 1000 and i < #units do v, i = v / 1000, i + 1 end
    if i == 1 then return string.format('%d', math.floor(v + 0.5)), units[i] end
    return num(v, v < 100 and 1 or 0), units[i]
end

local function hist_max(hist, floor)
    local m = floor
    for _, v in ipairs(hist) do if v > m then m = v end end
    return m
end

-- { [mount] = { used, size, avail } } in bytes; percentage as df computes it (used / (used + avail))
local disk_stats, disk_at = {}, -math.huge
local function sample_disks()
    local now = uptime()
    if now - disk_at < 30 then return disk_stats end
    disk_at, disk_stats = now, {}
    local args = {}
    for _, d in ipairs(DISKS) do args[#args + 1] = "'" .. d.mount:gsub("'", "'\\''") .. "'" end
    local p = io.popen('df -B1 --output=size,used,avail,target ' .. table.concat(args, ' ') .. ' 2>/dev/null')
    for line in p:lines() do
        local size, used, avail, target = line:match('^%s*(%d+)%s+(%d+)%s+(%d+)%s+(.-)%s*$')
        if size then
            disk_stats[target] = { used = tonumber(used), size = tonumber(size), avail = tonumber(avail),
                                   pct = tonumber(used) / (tonumber(used) + tonumber(avail)) * 100 }
        end
    end
    p:close()
    return disk_stats
end

-- ---------------------------------------------------------------- sections
local function big_value(cr, x, y, pct, label)
    text(cr, string.format('%d%%', math.floor(pct + 0.5)), x, y, S.value, C.text, 1)
    text(cr, label, x, y + 16, S.small, C.muted, 1)
end

local function draw_memory(cr, x, y, m)
    heading(cr, 'MEMORY', x, y + 10, nil, 'memory')
    big_value(cr, x, y + 44, m.pct, 'in use')
    bar(cr, x + GX, x + W, y + 34, m.pct)
    text(cr, 'Used ' .. num(m.used, 1) .. ' GiB', x + GX, y + 56, S.body, C.text, 1)
    text(cr, num(m.total, 1) .. ' GiB', x + W, y + 56, S.body, C.muted, 1, { align = 'right' })   -- bar's max
    return 64
end

local function draw_cpu(cr, x, y, pct)
    heading(cr, 'PROCESSOR', x, y + 10, nil, 'cpu')
    local head = static.cpu .. ' · ' .. conky_parse('${freq_g}') .. ' GHz'
    local t = read_temp(static.t_cpu)
    if t then head = head .. ' · ' .. t end
    text(cr, head, x + W, y + 10, S.body, C.text, 1, { align = 'right' })
    big_value(cr, x, y + 60, pct, 'usage')
    graph(cr, x + GX, x + W, y + 26, cpu_hist)
    return 104
end

local function draw_network(cr, x, y)
    heading(cr, 'NETWORK', x, y + 10, nil, 'network')
    text(cr, 'Last 60 seconds', x + W, y + 10, S.body, C.text, 1, { align = 'right' })

    -- Two stacked graphs, download then upload, each growing up from its own
    -- baseline and scaled to its own peak (shown above the graph).
    local GH = 40
    local rows = {
        { hist = rx_hist, label = 'Download', dir = 1,  color = C.accent, fill = C.fill,        top = y + 36,
          base = y + 84 },
        { hist = tx_hist, label = 'Upload',   dir = -1, color = C.upload, fill = C.upload_fill, top = y + 100,
          base = y + 146 },
    }
    for _, r in ipairs(rows) do
        local max = hist_max(r.hist, 10e3)   -- at least 10 KB/s so idle noise stays flat
        local v, unit = rate(r.hist[#r.hist] or 0)

        -- value with small unit, then the arrow + label
        local vy = r.top + 24
        local w = text(cr, v, x, vy, S.value, C.text, 1)
        text(cr, unit, x + w + 4, vy, S.body, C.text, 1)
        -- arrow drawn with lines (the fonts' arrow glyphs aren't reliable through cairo's toy API)
        local ax, ay = x + 4, vy + 14 - 4                 -- centre, on the label's x-height
        local tip, tail = ay + 4.5 * r.dir, ay - 4.5 * r.dir   -- dir: arrow points down / up
        cairo_new_path(cr)
        cairo_set_line_width(cr, 1.3)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_move_to(cr, ax, tail)
        cairo_line_to(cr, ax, tip)
        cairo_move_to(cr, ax - 3, tip - 3 * r.dir)
        cairo_line_to(cr, ax, tip)
        cairo_line_to(cr, ax + 3, tip - 3 * r.dir)
        cairo_set_source_rgba(cr, rgba(r.color, 1))
        cairo_stroke(cr)
        text(cr, r.label, x + 14, vy + 18, S.small, C.muted, 1)

        local mv, mu = rate(max)
        text(cr, mv .. ' ' .. mu, x + W, r.base - GH - 6, S.small, C.muted, 1, { align = 'right' })
        hline(cr, x + GX, x + W, r.base, 0.08)
        half_graph(cr, x + GX, x + W, r.base, r.hist,
                   { h = GH, max = max, dir = 1, color = r.color, fill = r.fill })
    end
    time_axis(cr, x + GX, x + W, y + 166)
    return 170
end

-- Grain (T.grain, a repeating noise tile) over each card; GRAIN_ALPHA 0
-- turns it off.
local GRAIN_ALPHA = 1.0
local SHEEN_ALPHA = T.card.sheen   -- faint top-lit gradient over each card

-- Right edge following the round window: the cards extend to EDGE_MX and,
-- where that would come closer than CURVE_GAP to the glass frame, curve
-- around it (concentric with the glass). Monitor coordinates on HDMI-A-1;
-- turned into window coordinates with gap_x/gap_y read from system.conf.
-- CURVE = false gives plain rectangles W + padding wide.
local CURVE      = true
local GLASS_MX, GLASS_MY, FRAME_R = T.glass.x, T.glass.y, T.glass.frame_r   -- frame's outer edge
local CURVE_GAP  = 20
local EDGE_MX    = 548
-- Sections that reach further towards the window, so the curve shows along
-- more of their side (by title)
local EDGE_WIDE_MX = 600
-- (true = EDGE_WIDE_MX, or a number of px to pull that section back from it)
local WIDE = { KERNEL = true, PROCESSOR = true, DISKS = 36, NETWORK = true }
local MON_X, MON_Y = T.monitor.x, T.monitor.y

local curve       -- { cx, cy, r, xmax } in window coordinates, set once
local function curve_geometry()
    if not curve then
        local f = io.open(os.getenv('HOME') .. '/.config/conky/system.conf', 'r')
        local conf = f and f:read('*a') or ''
        if f then f:close() end
        local wx = (tonumber(conf:match('gap_x%s*=%s*(%d+)')) or MON_X) - MON_X
        local wy = (tonumber(conf:match('gap_y%s*=%s*(%d+)')) or MON_Y) - MON_Y
        curve = { cx = GLASS_MX - wx, cy = GLASS_MY - wy, r = FRAME_R + CURVE_GAP, xmax = EDGE_MX - wx, wide = EDGE_WIDE_MX - wx }
    end
    return curve
end

-- The card's right edge at height y
local cur_xmax   -- right limit of the card being drawn (window coordinates)
local function right_x(y)
    local c = curve
    local xmax = cur_xmax or c.xmax
    local dy = y - c.cy
    if math.abs(dy) >= c.r then return xmax end
    return math.min(xmax, c.cx - math.sqrt(c.r * c.r - dy * dy))
end

-- Outline of a card (x, y, w, h); with CURVE its right side follows right_x.
-- Returns the curved stretch (y from, y to) if it has one.
local function card_path(cr, x, y, w, h)
    cairo_new_path(cr)
    if not CURVE then
        cairo_rectangle(cr, x, y, w, h)
        return
    end
    local c = curve_geometry()
    local y1, y2 = y, y + h
    cairo_move_to(cr, x, y1)
    cairo_line_to(cr, right_x(y1), y1)
    -- where the circle is left of xmax
    local xmax = cur_xmax or c.xmax
    local half = (c.cx - xmax < c.r) and math.sqrt(c.r * c.r - (c.cx - xmax) ^ 2) or 0
    local s1, s2 = math.max(y1, c.cy - half), math.min(y2, c.cy + half)
    local curved
    if half > 0 and s1 < s2 then
        if s1 > y1 then cairo_line_to(cr, xmax, s1) end
        -- left side of the circle, going down = decreasing angle
        local t1 = math.pi - math.asin((s1 - c.cy) / c.r)
        local t2 = math.pi - math.asin((s2 - c.cy) / c.r)
        cairo_arc_negative(cr, c.cx, c.cy, c.r, t1, t2)
        curved = { s1, s2, t1, t2 }
    end
    cairo_line_to(cr, right_x(y2), y2)
    cairo_line_to(cr, x, y2)
    cairo_close_path(cr)
    return curved
end

-- L-shaped bracket at each corner of a card, over a subtle grain and sheen
local function card(cr, x, y, w, h)
    if GRAIN_ALPHA > 0 then
        card_path(cr, x + 1, y + 1, w - 2, h - 2)
        cairo_set_source(cr, grain())
        if GRAIN_ALPHA < 1 then
            cairo_save(cr); cairo_clip(cr); cairo_paint_with_alpha(cr, GRAIN_ALPHA); cairo_restore(cr)
        else
            cairo_fill(cr)
        end
    end
    local curved
    if SHEEN_ALPHA > 0 then
        curved = card_path(cr, x + 1, y + 1, w - 2, h - 2)
        local g = cairo_pattern_create_linear(0, y, 0, y + h)
        cairo_pattern_add_color_stop_rgba(g, 0, 1, 1, 1, SHEEN_ALPHA)
        cairo_pattern_add_color_stop_rgba(g, 1, 1, 1, 1, 0)
        cairo_set_source(cr, g)
        cairo_fill(cr)
        cairo_pattern_destroy(g)
    end

    local l = BRACKET_LEN
    local x1, y1, y2 = x + 0.5, y + 0.5, y + h - 0.5
    local function rx(yy) return (CURVE and right_x(yy) or x + w) - 0.5 end
    -- follows the right edge from ya to yb (curved or straight), 2 px steps
    local function trace(ya, yb, move)
        local step = ya < yb and 2 or -2
        local yy = ya
        while (step > 0 and yy < yb) or (step < 0 and yy > yb) do
            if move then cairo_move_to(cr, rx(yy), yy); move = false
            else cairo_line_to(cr, rx(yy), yy) end
            yy = yy + step
        end
        cairo_line_to(cr, rx(yb), yb)
    end

    cairo_new_path(cr)
    cairo_set_line_width(cr, 1)
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_MITER)
    cairo_move_to(cr, x1, y1 + l); cairo_line_to(cr, x1, y1); cairo_line_to(cr, x1 + l, y1)
    cairo_move_to(cr, x1, y2 - l); cairo_line_to(cr, x1, y2); cairo_line_to(cr, x1 + l, y2)
    -- right corners: the horizontal leg, then along the (possibly curved) edge
    cairo_move_to(cr, rx(y1) - l, y1); cairo_line_to(cr, rx(y1), y1); trace(y1, y1 + l)
    cairo_move_to(cr, rx(y2) - l, y2); cairo_line_to(cr, rx(y2), y2); trace(y2, y2 - l)
    cairo_set_source_rgba(cr, rgba(BRACKET, BRACKET_ALPHA))
    cairo_stroke(cr)

    -- on cards that curve: a faint line along the whole right side between
    -- the corner brackets (the curve and any straight part above/below it),
    -- echoing the window's frame
    if curved then
        local ya, yb = y1 + l, y2 - l
        if yb > ya then
            cairo_new_path(cr)
            trace(ya, yb, true)
            cairo_set_source_rgba(cr, rgba(BRACKET, BRACKET_ALPHA * 0.6))
            cairo_stroke(cr)
        end
    end
end

-- Kernel on the left, uptime on the right, as caption + value pairs
local function draw_system_info(cr, x, y)
    static.kernel = static.kernel or (read_file('/proc/sys/kernel/osrelease') or '?'):gsub('%s+$', '')
    local s = math.floor(uptime())
    local d, h, m = s // 86400, (s % 86400) // 3600, (s % 3600) // 60
    local up = d > 0 and string.format('%dd %dh %dm', d, h, m) or string.format('%dh %dm', h, m)
    heading(cr, 'KERNEL', x, y + 10, nil, 'kernel')
    text(cr, static.kernel, x, y + 29, S.body, C.text, 1)
    heading(cr, 'UPTIME', x + W, y + 10, 'right', 'uptime')
    text(cr, up, x + W, y + 29, S.body, C.text, 1, { align = 'right' })
    return 34
end

-- Circular gauge: soft fill inside, track, value arc and knob; the value
-- starts at the top and runs clockwise. The percentage sits inside it, the
-- name and free space below.
local GAUGE_R = 30
local function gauge(cr, cx, cy, pct, color, fill)
    color, fill = color or C.accent, fill or C.fill
    local a0 = -math.pi / 2
    local a1 = a0 + 2 * math.pi * math.max(0, math.min(pct, 100)) / 100

    cairo_new_path(cr)
    cairo_arc(cr, cx, cy, GAUGE_R, 0, 2 * math.pi)
    local g = cairo_pattern_create_linear(0, cy - GAUGE_R, 0, cy + GAUGE_R)
    cairo_pattern_add_color_stop_rgba(g, 0, rgba(fill, 0.9))
    cairo_pattern_add_color_stop_rgba(g, 1, rgba(fill, 0))
    cairo_set_source(cr, g)
    cairo_fill(cr)
    cairo_pattern_destroy(g)

    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_width(cr, 3)
    cairo_new_path(cr)
    cairo_arc(cr, cx, cy, GAUGE_R, 0, 2 * math.pi)
    cairo_set_source_rgba(cr, rgba(C.track, 1))
    cairo_stroke(cr)
    if pct > 0 then
        cairo_new_path(cr)
        cairo_arc(cr, cx, cy, GAUGE_R, a0, a1)
        cairo_set_source_rgba(cr, rgba(color, 1))
        cairo_stroke(cr)
    end
    knob(cr, cx + GAUGE_R * math.cos(a1), cy + GAUGE_R * math.sin(a1), color)
end

-- One gauge per disk, side by side: percentage and name inside, free space below
local function draw_disks(cr, x, y)
    local stats = sample_disks()
    heading(cr, 'DISKS', x, y + 10, nil, 'disks')
    local gib = 1024 ^ 3
    local cy = y + 30 + GAUGE_R
    -- Faint vertical line between root and the others, setting root apart
    local sx = math.floor(x + W / #DISKS) + 0.5
    cairo_new_path(cr)
    cairo_set_line_width(cr, 1)
    -- dashed as the graphs' grid lines, a bit stronger (they're at 0.12)
    cairo_set_dash(cr, { 2, 4 }, 2, 0)
    cairo_move_to(cr, sx, y + 2)
    cairo_line_to(cr, sx, cy + GAUGE_R + 40)
    cairo_set_source_rgba(cr, rgba(C.line, 0.22))
    cairo_stroke(cr)
    cairo_set_dash(cr, {}, 0, 0)
    for i, d in ipairs(DISKS) do
        local cx = x + W * (i - 0.5) / #DISKS
        local st = stats[d.mount]
        gauge(cr, cx, cy, st and st.pct or 0, d.color, d.fill)
        if st then
            text(cr, string.format('%d%%', math.floor(st.pct + 0.5)), cx, cy + 5, 15, C.text, 1,
                 { align = 'center' })
        end
        text(cr, d.name, cx, cy + GAUGE_R + 18, S.small, C.muted, 1, { align = 'center' })
        local below = st and string.format('%d GiB free', math.floor(st.avail / gib + 0.5)) or 'not mounted'
        text(cr, below, cx, cy + GAUGE_R + 36, S.body, C.text, 1, { align = 'center' })
    end
    return 30 + 2 * GAUGE_R + 40
end

local function draw_gpu(cr, x, y, g)
    heading(cr, 'GPU', x, y + 10, nil, 'gpu')
    local t = read_temp(static.t_gpu)
    text(cr, static.gpu_name .. (t and ' · ' .. t or ''), x + W, y + 10, S.body, C.text, 1, { align = 'right' })
    big_value(cr, x, y + 60, g.pct, 'usage')
    graph(cr, x + GX, x + W, y + 26, gpu_hist)
    hline(cr, x, x + W, y + 110, 0.08)
    caption(cr, 'VRAM', x, y + 128)
    local tv = read_temp(static.t_vram)
    ratio(cr, string.format('%d MiB', math.floor(g.used + 0.5)),
          string.format('%d MiB', math.floor(g.total + 0.5)) .. (tv and ' · ' .. tv or ''), x + W, y + 128)
    bar(cr, x + 4, x + W, y + 144, g.total > 0 and g.used / g.total * 100 or 0)
    return 150
end

local section_h   -- card heights, measured on the first frame

function conky_draw_system()
    if conky_window == nil then return end
    if not static then
        static = { cpu = cpu_name(), gpu = find_gpu(), gpu_name = gpu_name() }
        local cpu_t = temp_inputs('/sys/class/hwmon/hwmon*')
        local gpu_t = static.gpu and temp_inputs(static.gpu .. '/hwmon/hwmon*') or {}
        static.t_cpu  = cpu_t['k10temp:Tctl']
        static.t_gpu  = gpu_t['amdgpu:edge']
        static.t_vram = gpu_t['amdgpu:mem']
    end

    -- Sample once per update, even if conky redraws more often
    local cpu = sample_cpu()
    local mem, gpu = sample_mem(), sample_gpu()
    push(cpu_hist, cpu)
    push(gpu_hist, gpu.pct)
    local down, up = sample_net()
    push(rx_hist, down)
    push(tx_hist, up)

    local cs, owns_surface = window_surface()
    local cr = cairo_create(cs)
    cairo_set_antialias(cr, CAIRO_ANTIALIAS_BEST)
    cairo_set_font_options(cr, font_options())

    local sections = {
        { draw_system_info, nil, 'KERNEL' }, { draw_cpu, cpu, 'PROCESSOR' }, { draw_memory, mem },
        { draw_gpu, gpu }, { draw_disks, nil, 'DISKS' }, { draw_network, nil, 'NETWORK' },
    }
    -- Section heights are constant: measure them once by drawing offscreen
    if not section_h then
        section_h = {}
        cairo_push_group(cr)
        for i, sec in ipairs(sections) do section_h[i] = sec[1](cr, 0, 0, sec[2]) + 2 * CARD_PY end
        cairo_pattern_destroy(cairo_pop_group(cr))
    end

    -- Spread the cards over the window's height
    local x = conky_window.text_start_x + 1
    local y = conky_window.text_start_y + ANCHOR_Y
    local total = 0
    for _, h in ipairs(section_h) do total = total + h end
    local avail = conky_window.height - 2 * conky_window.text_start_y - ANCHOR_Y
    local gap = math.max(CARD_GAP, (avail - total) / (#sections - 1))

    for i, sec in ipairs(sections) do
        local h, cy = section_h[i], math.floor(y)
        -- With CURVE, each card's content is as wide as its frame allows:
        -- its narrowest point (where the curve comes in) minus padding.
        if CURVE then
            local c = curve_geometry()
            local wide = WIDE[sec[3] or '']
            cur_xmax = wide and (c.wide - (tonumber(wide) or 0)) or c.xmax
            local right = math.huge
            for yy = cy, cy + h, 4 do right = math.min(right, right_x(yy)) end
            W = math.floor(right - x - 2 * CARD_PX)
        end
        card(cr, x, cy, W + 2 * CARD_PX, h)
        sec[1](cr, x + CARD_PX, cy + CARD_PY, sec[2])
        y = y + h + gap
    end
    W, cur_xmax = W_BASE, nil

    cairo_destroy(cr)
    if owns_surface then cairo_surface_destroy(cs) end
end
