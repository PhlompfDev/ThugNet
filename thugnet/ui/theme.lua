-- Dark modern theme: the single owner of colors. UI code uses theme.tokens
-- (palette slots) and theme.fg_bg(token, token); raw colors.* belongs only
-- in this file (and user-chosen editor element colors).
local core = require("graphics.core")

local theme = {}

-- palette: slot -> 24-bit hex
theme.palette = {
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
}

-- semantic tokens -> palette slots
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

-- apply the palette to a terminal/monitor target
function theme.apply(target)
    for slot, hex in pairs(theme.palette) do
        target.setPaletteColor(slot, hex)
    end
    target.setTextColor(theme.tokens.text)
    target.setBackgroundColor(theme.tokens.bg)
    target.clear()
    target.setCursorPos(1, 1)
end

return theme
