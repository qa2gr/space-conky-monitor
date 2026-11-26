-- Earth: taken from the wallpaper. The atmosphere's cyan as the main accent
-- (a little softer than the rim, so the widgets don't compete with it), the
-- sunlit land's warm sand as the second, on cool blue-grey neutrals.
-- Hex 'rrggbb'; alpha is given where a colour is used.
-- Select it with PALETTE in lua/theme.lua.
return {
    -- text and neutrals
    text        = 'e4ecf4',
    muted       = '7d8ca0',
    muted_light = 'a3b3c4',   -- for text straight over the busy wallpaper
    bracket     = 'b9c8d8',   -- card corner brackets
    line        = 'ffffff',   -- dividers and grid, at very low alpha

    -- accents, and the dark fills under their graphs / bars
    accent      = '7cc8e6',   -- atmosphere cyan
    accent2     = 'e2c4a6',   -- sunlit sand
    fill        = '1e4a5e',   -- under accent graphs
    fill2       = '4a3f36',   -- under accent2 graphs
    track       = '1f3044',   -- empty part of bars and gauges
    placeholder = '1f2c40',   -- media cover when there is none

    -- status
    up          = '7fe0bf',   -- mint
    down        = 'ff8f7e',   -- coral
    pending     = 'f0c674',   -- amber
    unknown     = '5a6a7e',

    -- VPS stars
    star           = 'ffffff',
    star_glow      = 'a8e4f7',
    star_down      = 'ff8f7e',
    star_down_text = 'ff9a8a',
    star_name      = 'dfe9f2',
    dust           = 'd6ecf7',

    -- weather
    weather_ink    = 'f2f6fa',
    weather_cloud  = 'e6edf3',
    weather_sun    = 'ffc98f',
    weather_rain   = '6fc0ee',
    weather_shadow = '0b1626',   -- clouds are shaded towards this underneath
    -- temperature curve, cold to hot: cyan, pale, sand, coral. { °C, colour }
    temperature = {
        { -25, 'bfe6fb' }, { -10, '8fd6f5' }, { 0, '7cc8e6' }, { 8, '9fd3e6' }, { 15, 'd8d6c8' },
        { 21, 'e2c4a6' }, { 27, 'f0ad8a' }, { 33, 'ff8f7e' }, { 42, 'ff7466' },
    },
}
