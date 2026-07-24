-- The single owner of colors. UI code uses theme.tokens (semantic slots) and
-- theme.fg_bg(token, token); raw colors.* belongs only in this file (and
-- user-chosen editor element colors).
--
-- Two named palettes -- dark (default) and light -- are two 24-bit hex maps
-- over the SAME 16 CC palette slots. The token->slot assignments never change,
-- so every page is theme-agnostic by construction: switching theme reassigns
-- the hexes behind the slots the tokens already point at. theme.set(name)
-- selects the active palette; theme.apply() writes it to a target.
local core = require("graphics.core")

local theme = {}

-- semantic tokens -> palette slots (identical for every theme)
theme.tokens = {
    bg          = colors.black,
    panel       = colors.brown,
    raised      = colors.gray,
    dim         = colors.lightGray,
    text        = colors.white,
    accent      = colors.cyan,
    accent2     = colors.orange,
    ok          = colors.green,
    ok_bright   = colors.lime,
    warn        = colors.yellow,
    alert       = colors.red,
    info        = colors.lightBlue,
    info_strong = colors.blue,
}

-- palette maps: slot -> 24-bit hex. Both cover the same slots; only the hexes
-- differ. In light mode the slot Lua-names ("black", "white") are historical --
-- the "black" (bg) slot holds a light color and the "white" (text) slot a dark
-- one. That inversion is exactly how CC palette remapping re-skins everything.
theme.palettes = {
    dark = {
        [colors.black]     = 0x121212,  -- bg
        [colors.brown]     = 0x1c1c20,  -- panel
        [colors.gray]      = 0x2a2a31,  -- raised
        [colors.lightGray] = 0x9a9aa2,  -- dim text
        [colors.white]     = 0xececf1,  -- text
        [colors.cyan]      = 0x4fd1c5,  -- accent
        [colors.green]     = 0x48bb78,  -- ok
        [colors.lime]      = 0x7ce7a2,  -- ok bright (LED on)
        [colors.yellow]    = 0xecc94b,  -- warn
        [colors.red]       = 0xf56565,  -- alert
        [colors.orange]    = 0xf6ad55,  -- accent2
        [colors.lightBlue] = 0x63b3ed,  -- info
        [colors.blue]      = 0x4a9fe3,  -- info strong
        -- user-pickable colors for editor elements
        [colors.purple]    = 0x9f7aea,
        [colors.magenta]   = 0xed64a6,
        [colors.pink]      = 0xf8b4d9,
    },
    light = {
        [colors.black]     = 0xe9e9ee,  -- bg (light)
        [colors.brown]     = 0xdcdce4,  -- panel
        [colors.gray]      = 0xc7c8d2,  -- raised
        [colors.lightGray] = 0x5a5a66,  -- dim text
        [colors.white]     = 0x1b1b22,  -- text (dark ink)
        [colors.cyan]      = 0x0d8f84,  -- accent
        [colors.green]     = 0x2f855a,  -- ok
        [colors.lime]      = 0x38a169,  -- ok bright
        [colors.yellow]    = 0xb7791f,  -- warn
        [colors.red]       = 0xc53030,  -- alert
        [colors.orange]    = 0xc05621,  -- accent2
        [colors.lightBlue] = 0x2b6cb0,  -- info
        [colors.blue]      = 0x2c5282,  -- info strong
        -- editor element colors: kept vivid, they read on either background
        [colors.purple]    = 0x805ad5,
        [colors.magenta]   = 0xd53f8c,
        [colors.pink]      = 0xd67aa8,
    },
}

theme.name = "dark"
-- active palette pointer (kept named `palette` for any legacy reader)
theme.palette = theme.palettes.dark

-- select the active theme; an unknown name falls back to dark
---@param name string "dark" | "light"
function theme.set(name)
    theme.palette = theme.palettes[name] or theme.palettes.dark
    theme.name = theme.palettes[name] and name or "dark"
end

-- severity -> token slot (events/toasts)
theme.severity = {
    info  = theme.tokens.info,
    warn  = theme.tokens.warn,
    alert = theme.tokens.alert,
}

-- cpair from token names, e.g. theme.fg_bg("text", "panel")
function theme.fg_bg(fg_token, bg_token)
    return core.cpair(theme.tokens[fg_token], theme.tokens[bg_token])
end

-- apply the ACTIVE palette to a terminal/monitor target
function theme.apply(target)
    theme.repalette(target)
    target.setTextColor(theme.tokens.text)
    target.setBackgroundColor(theme.tokens.bg)
    target.clear()
    target.setCursorPos(1, 1)
end

-- Re-tint the palette slots WITHOUT clearing. CC palette slots are indexed, so
-- reassigning a slot's hex recolors every cell already using it -- the whole
-- surface changes theme live, with no redraw and no flicker. The wizard's Look
-- step uses this to preview the theme the instant it is picked.
function theme.repalette(target)
    for slot, hex in pairs(theme.palette) do
        target.setPaletteColor(slot, hex)
    end
end

return theme
