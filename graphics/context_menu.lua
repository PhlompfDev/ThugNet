--
-- graphics/context_menu.lua
--
-- Pixel-saving overlay context menu manager.
-- Draws a right-click popup directly onto a terminal window, saving and
-- restoring the pixels underneath. Freezes the flasher while open so
-- animated elements don't overwrite the menu.
--
-- Usage:
--   local ctx = require("graphics.context_menu")
--   ctx.open(term.current(), x, y, {
--       { text = "Option A", callback = function() ... end },
--       { text = "Option B", callback = function() ... end },
--   })
--   -- In event loop: if ctx.is_active() then ctx.handle_mouse(ev) end
--

local flasher = require("graphics.flasher")
local core    = require("graphics.core")

local MOUSE_CLICK = core.events.MOUSE_CLICK

local ctx = {}

-- ── State ────────────────────────────────────────────────────────────────────

local active       = false
local menu_win     = nil      -- the terminal window we draw on
local menu_x       = 0        -- top-left x of menu (absolute, 1-based)
local menu_y       = 0        -- top-left y of menu (absolute, 1-based)
local menu_w       = 0        -- total width including border
local menu_h       = 0        -- total height including border
local options      = {}       -- list of { text, callback }
local saved_pixels = {}       -- row -> { text, fg, bg }
local highlighted  = nil      -- 1-based option index currently highlighted
local pressed_inside = false  -- a mouse-DOWN has occurred inside since opening;
                              -- gates selection so the trailing UP of the
                              -- opening right-click can't auto-select an option

-- ── Colors ───────────────────────────────────────────────────────────────────

-- Dark theme (thugnet v2): the theme palette maps these slots to
-- bg/raised/text/accent, giving dark menus everywhere (incl. the editor).
local OUTER_BG   = colors.black      -- color outside the menu (surrounding UI bg)
local BORDER_FG  = colors.cyan       -- thin border line color
local OPTION_FG  = colors.white      -- normal item text
local OPTION_BG  = colors.gray       -- normal item background
local HILITE_FG  = colors.black      -- highlighted item text
local HILITE_BG  = colors.cyan       -- highlighted item background

-- blit color char lookup (CC:T uses hex digits 0-f for 2^0 through 2^15)
local function blit_char(color)
    return core.cpair(color, color).blit_fgd
end

-- ── Pixel Save / Restore ─────────────────────────────────────────────────────

local function save_region()
    saved_pixels = {}
    for row = menu_y, menu_y + menu_h - 1 do
        local text, fg, bg = menu_win.getLine(row)
        saved_pixels[row] = {
            text = text:sub(menu_x, menu_x + menu_w - 1),
            fg   = fg:sub(menu_x, menu_x + menu_w - 1),
            bg   = bg:sub(menu_x, menu_x + menu_w - 1),
        }
    end
end

local function restore_region()
    for row, data in pairs(saved_pixels) do
        menu_win.setCursorPos(menu_x, row)
        menu_win.blit(data.text, data.fg, data.bg)
    end
    saved_pixels = {}
end

-- ── Menu Drawing ─────────────────────────────────────────────────────────────

local function draw_menu()
    local xb = blit_char(OUTER_BG)   -- outside / surrounding UI color
    local bf = blit_char(BORDER_FG)  -- thin border line color
    local ob = blit_char(OPTION_BG)  -- option background (white)
    local of = blit_char(OPTION_FG)  -- option text color
    local hf = blit_char(HILITE_FG)
    local hb = blit_char(HILITE_BG)

    local inner_w = menu_w - 2

    -- Top border: solid filled bar, same approach as Box.lua's header row.
    -- All spaces with FG=gray, BG=gray → full gray row, no pixel bleed.
    menu_win.setCursorPos(menu_x, menu_y)
    menu_win.blit(string.rep(" ", menu_w), string.rep(bf, menu_w), string.rep(bf, menu_w))

    -- Top padding row: mirrors the bottom padding row, white fill with side borders.
    local pad_line   = "\x95" .. string.rep(" ", inner_w) .. "\x95"
    local pad_fg_str = bf .. string.rep(of, inner_w) .. ob
    local pad_bg_str = ob .. string.rep(ob, inner_w) .. bf
    menu_win.setCursorPos(menu_x, menu_y + 1)
    menu_win.blit(pad_line, pad_fg_str, pad_bg_str)

    -- Option rows: left border | padded text | right border
    -- Left  \x95: FG=gray(line), BG=white(inside) → left-half=gray, right-half=white
    -- Right \x95: FG=white(inside), BG=gray(line) → left-half=white, right-half=gray
    for i = 1, #options do
        local row_y = menu_y + i + 1
        local text = options[i].text or ""
        if #text > inner_w - 1 then
            text = text:sub(1, inner_w - 2) .. "\x1a"
        end
        local padded = " " .. text .. string.rep(" ", inner_w - #text - 1)

        local is_hilite = (i == highlighted)
        local fg_c = is_hilite and hf or of
        local bg_c = is_hilite and hb or ob

        local line   = "\x95" .. padded .. "\x95"
        -- Left border:  FG=gray(line), BG=item-bg  → left-half=gray line, right-half=item-bg (inside)
        -- Inner cells:  FG=text, BG=item-bg
        -- Right border: FG=item-bg(inside), BG=gray(line) → left-half=item-bg, right-half=gray line
        -- Note: outer face of right border is the rightmost pixel of BG=gray, not OUTER_BG.
        -- Since the right border cell IS the last column of the menu this is the menu edge — acceptable.
        local fg_str = bf .. string.rep(fg_c, inner_w) .. bg_c
        local bg_str = ob .. string.rep(bg_c, inner_w) .. bf

        menu_win.setCursorPos(menu_x, row_y)
        menu_win.blit(line, fg_str, bg_str)
    end

    -- Padding row: side borders only, white fill, no text
    local pad_line   = "\x95" .. string.rep(" ", inner_w) .. "\x95"
    local pad_fg_str = bf .. string.rep(of, inner_w) .. ob
    local pad_bg_str = ob .. string.rep(ob, inner_w) .. bf
    menu_win.setCursorPos(menu_x, menu_y + #options + 2)
    menu_win.blit(pad_line, pad_fg_str, pad_bg_str)

    -- Bottom border: Box.lua chars with FG=white(interior), BG=blue(border).
    -- \x8a/\x8f/\x85 have lit pixels in the top+mid rows (FG=white, faces the interior above)
    -- and unlit pixels only in the bottom row (BG=blue, the exterior border line).
    local bot = "\x8a" .. string.rep("\x8f", inner_w) .. "\x85"
    menu_win.setCursorPos(menu_x, menu_y + menu_h - 1)
    menu_win.blit(bot, string.rep(ob, menu_w), string.rep(bf, menu_w))
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Open a context menu at absolute screen position.
---@param win table terminal window (term.current())
---@param x integer desired x position (menu appears to the right of click)
---@param y integer desired y position
---@param opts table list of { text=string, callback=function }
function ctx.open(win, x, y, opts)
    if active then ctx.close() end

    menu_win = win
    options  = opts or {}
    if #options == 0 then return end

    -- Compute dimensions
    local max_text = 0
    for _, opt in ipairs(options) do
        local len = #(opt.text or "")
        if len > max_text then max_text = len end
    end
    menu_w = max_text + 4   -- 1 border + 1 padding each side
    menu_h = #options + 3   -- top border + top pad + options + bot pad + bot border

    -- Clamp to screen
    local sw, sh = win.getSize()
    menu_x = x
    menu_y = y
    if menu_x + menu_w - 1 > sw then menu_x = sw - menu_w + 1 end
    if menu_y + menu_h - 1 > sh then menu_y = sh - menu_h + 1 end
    if menu_x < 1 then menu_x = 1 end
    if menu_y < 1 then menu_y = 1 end

    highlighted = nil
    pressed_inside = false
    save_region()
    draw_menu()

    active = true
    flasher.pause()
end

--- Close the context menu and restore pixels.
function ctx.close()
    if not active then return end
    restore_region()
    active = false
    highlighted = nil
    flasher.resume()
end

--- Check if a context menu is currently open.
---@return boolean
function ctx.is_active()
    return active
end

-- test support
--- Get the live list of options in the currently open menu ({ text, callback }).
--- For tests that need to inspect menu contents without clicking.
---@return table options
function ctx.options()
    return options
end

--- Redraw the menu on top of whatever is currently on screen.
--- Call this whenever an underlying element may have redrawn itself.
function ctx.redraw()
    if active then draw_menu() end
end

--- Handle a mouse event while the menu is active.
--- Returns true if the event was consumed.
---@param event mouse_interaction
---@return boolean consumed
function ctx.handle_mouse(event)
    if not active then return false end

    local x = event.current.x
    local y = event.current.y

    -- Check if inside menu bounds
    local in_menu = x >= menu_x and x <= menu_x + menu_w - 1
                and y >= menu_y and y <= menu_y + menu_h - 1

    if in_menu then
        -- Which option row? top border + top pad = 2 rows, so options start at menu_y+2
        local opt_idx = y - menu_y - 1
        if opt_idx >= 1 and opt_idx <= #options then
            if event.type == MOUSE_CLICK.DOWN then
                -- press inside: arm selection + highlight the row
                pressed_inside = true
                highlighted = opt_idx
                draw_menu()
            elseif event.type == MOUSE_CLICK.TAP then
                -- atomic tap (monitor touch): select immediately
                local cb = options[opt_idx].callback
                ctx.close()
                if type(cb) == "function" then cb() end
            elseif event.type == MOUSE_CLICK.UP then
                -- only a release paired with a press inside selects; this
                -- discards the trailing UP of the opening right-click gesture
                if pressed_inside then
                    local cb = options[opt_idx].callback
                    ctx.close()
                    if type(cb) == "function" then cb() end
                end
            end
        end
        return true
    else
        -- Click outside: dismiss the menu (on a press, not the trailing UP)
        if event.type == MOUSE_CLICK.DOWN or event.type == MOUSE_CLICK.TAP then
            ctx.close()
        end
        return true
    end
end

return ctx
