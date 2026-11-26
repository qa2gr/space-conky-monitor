-- Lavender: the original palette (pastel lavender and light blue on
-- grey-violet neutrals). Hex 'rrggbb'; alpha is given where a colour is used.
-- Select it with PALETTE in lua/theme.lua.
return {
    -- text and neutrals
    text        = 'eceaf6',
    muted       = '8b8da3',
    muted_light = 'a9abc0',   -- for text straight over the busy wallpaper
    bracket     = 'c9c8dc',   -- card corner brackets
    line        = 'ffffff',   -- dividers and grid, at very low alpha

    -- accents, and the dark fills under their graphs / bars
    accent      = 'b4b0f8',
    accent2     = '90caf9',
    fill        = '3b3a5a',   -- under accent graphs
    fill2       = '2a3b52',   -- under accent2 graphs
    track       = '2b2d44',   -- empty part of bars and gauges
    placeholder = '262a40',   -- media cover when there is none

    -- status
    up          = '7edca0',
    down        = 'f07a7a',
    pending     = 'f0c674',
    unknown     = '5d6079',

    -- VPS stars
    star           = 'ffffff',
    star_glow      = 'c7c2ff',
    star_down      = 'f27373',
    star_down_text = 'e88a8a',
    star_name      = 'e2e1f0',
    dust           = 'd9d9ff',

    -- weather
    weather_ink    = 'f4f4fd',
    weather_cloud  = 'eaeaf3',
    weather_sun    = 'ffc580',
    weather_rain   = '77beff',
    weather_shadow = '121723',   -- clouds are shaded towards this underneath
    -- temperature curve, cold to hot: { °C, colour }
    temperature = {
        { -25, 'a6d8fa' }, { -10, '71c8ff' }, { 0, '91c1ff' }, { 8, 'b1b6ff' }, { 15, 'dfa1fc' },
        { 21, 'fc98d5' }, { 27, 'ff9ea7' }, { 33, 'ffa475' }, { 42, 'ffa752' },
    },
}
