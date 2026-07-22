--
-- graphics/text_prompt.lua
--
-- Pixel-saving overlay text input prompt with live autocomplete suggestions.
-- Draws a floating input dialog directly onto a terminal window, saving and
-- restoring the pixels underneath. Styled to match the context menu.
--
-- Layout when N suggestions match (N = 0..MAX_SUGGESTIONS):
--   row 0:         solid blue title bar
--   row 1:         white padding row            — only when N > 0
--   row 2..N+1:    suggestion rows (filtered prefix matches)
--   row N+2:       separator (thin blue line)   — only when N > 0
--   row N+3:       white padding row
--   row N+4:       label row  "  <label>  "
--   row N+5:       input row  "[ <value_>  ]"
--   row N+6:       white padding row
--   row N+7:       bottom border
--
-- Total height = 7 + N  (N=0 → identical to original 6-row layout, no separator/pad)
-- The region saved at open() is always MAX_H = 8+MAX_SUGGESTIONS rows so the
-- overlay can grow/shrink without touching pixels outside the saved area.
--
-- Keys:
--   Tab         → highlight first suggestion (or next; wraps)
--   Shift+Tab   → highlight previous suggestion (wraps)
--   Down arrow  → highlight next suggestion (or deselect if at top going up)
--   Up arrow    → highlight previous (deselects when going past first)
--   Enter       → if suggestion highlighted: fill + confirm; else confirm typed text
--   Escape      → if suggestion highlighted: deselect only; else close prompt
--   Any char    → clears highlight, inserts character, refreshes suggestions
--
-- Usage:
--   local prompt = require("graphics.text_prompt")
--   prompt.open(win, x, y, "Rename foo", "foo",
--       function(val) ... end,
--       function() return {"StopServer","Rename","Custom"} end)
--

local core = require("graphics.core")

local KEY_CLICK = core.events.KEY_CLICK
local MOUSE_CLICK = core.events.MOUSE_CLICK

local MAX_SUGGESTIONS = 5   -- max rows shown in the suggestion area

local prompt = {}

-- ── State ─────────────────────────────────────────────────────────────────────

local active          = false
local p_win           = nil     -- terminal window
local p_x             = 0       -- top-left x (absolute, 1-based)
local p_y             = 0       -- top-left y (absolute, 1-based)
local p_w             = 0       -- total width
local p_label         = ""
local p_value         = ""      -- current input string
local p_cursor        = 1       -- 1 = before first char, #p_value+1 = after last
local p_frame_s       = 1       -- visible window start index into p_value
local p_on_confirm    = nil     -- function(value)
local p_suggestions_fn = nil    -- function() → {string,...} | nil
local p_suggestions   = {}      -- current filtered list
local p_sugg_sel      = nil     -- 1-based index of highlighted suggestion (nil = none)
local saved_pixels    = {}      -- row -> { text, fg, bg }
local p_save_h        = 6       -- how many rows were saved (MAX_H at open time)

-- ── Colors ────────────────────────────────────────────────────────────────────

-- Dark theme (thugnet v2): palette maps these slots to bg/raised/text/accent.
local BORDER_FG   = colors.cyan
local OPTION_BG   = colors.gray
local OPTION_FG   = colors.white
local INPUT_BG    = colors.black
local INPUT_FG    = colors.white
local CURSOR_FG   = colors.lightGray
local SUGG_BG     = colors.gray      -- normal suggestion background
local SUGG_SEL_BG = colors.cyan      -- highlighted suggestion background
local SUGG_SEL_FG = colors.black     -- highlighted suggestion text

local function bc(c) return colors.toBlit(c) end

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- inner field width (between the [ and ] delimiters)
local function field_w() return p_w - 4 end

-- Recompute filtered suggestions from the current input value
local function update_suggestions()
    p_suggestions = {}
    if not p_suggestions_fn then return end
    local all = p_suggestions_fn() or {}
    local lower = p_value:lower()
    for _, s in ipairs(all) do
        if #lower > 0 and s:lower():sub(1, #lower) == lower then
            table.insert(p_suggestions, s)
            if #p_suggestions >= MAX_SUGGESTIONS then break end
        end
    end
    -- Keep selection in range or clear it
    if p_sugg_sel and p_sugg_sel > #p_suggestions then
        p_sugg_sel = #p_suggestions > 0 and #p_suggestions or nil
    end
end

-- ── Pixel Save / Restore ──────────────────────────────────────────────────────

local function save_region()
    saved_pixels = {}
    for row = p_y, p_y + p_save_h - 1 do
        local text, fg, bg = p_win.getLine(row)
        saved_pixels[row] = {
            text = text:sub(p_x, p_x + p_w - 1),
            fg   = fg:sub(p_x, p_x + p_w - 1),
            bg   = bg:sub(p_x, p_x + p_w - 1),
        }
    end
end

local function restore_region()
    for row, data in pairs(saved_pixels) do
        p_win.setCursorPos(p_x, row)
        p_win.blit(data.text, data.fg, data.bg)
    end
    saved_pixels = {}
end

-- ── Drawing ───────────────────────────────────────────────────────────────────

local function draw()
    local bf  = bc(BORDER_FG)
    local ob  = bc(OPTION_BG)
    local of  = bc(OPTION_FG)
    local ib  = bc(INPUT_BG)
    local inf = bc(INPUT_FG)
    local cur = bc(CURSOR_FG)
    local sg  = bc(SUGG_BG)
    local sb  = bc(SUGG_SEL_BG)
    local sf  = bc(SUGG_SEL_FG)

    local inner_w  = p_w - 2
    local n_sugg   = #p_suggestions
    local has_sugg = n_sugg > 0

    -- Row 0: solid blue title bar (always at the very top)
    p_win.setCursorPos(p_x, p_y)
    p_win.blit(string.rep(" ", p_w), string.rep(bf, p_w), string.rep(bf, p_w))

    -- Shared side-bordered row builder (white interior, blue side borders)
    local function side_row(content_text, fg_str, bg_str, row)
        local line = "\x95" .. content_text .. "\x95"
        p_win.setCursorPos(p_x, row)
        p_win.blit(line, bf .. fg_str .. ob, ob .. bg_str .. bf)
    end

    -- When suggestions are present, add a white padding row above them
    if has_sugg then
        side_row(string.rep(" ", inner_w), string.rep(ob, inner_w), string.rep(ob, inner_w), p_y + 1)
    end

    -- Rows 2..n_sugg+1: suggestion rows (shifted down 1 by the top padding row)
    for i = 1, n_sugg do
        local s        = p_suggestions[i]
        local is_sel   = (i == p_sugg_sel)
        local prefix   = is_sel and "> " or "  "
        local txt      = (prefix .. s):sub(1, inner_w)
        local padded   = txt .. string.rep(" ", inner_w - #txt)
        local row_fg   = is_sel and sf or of
        local row_bg   = is_sel and sb or sg
        local fg_str   = string.rep(row_fg, inner_w)
        local bg_str   = string.rep(row_bg, inner_w)
        side_row(padded, fg_str, bg_str, p_y + 1 + i)
    end

    -- Row n_sugg+2: separator (thin blue line) — only when suggestions present
    if has_sugg then
        local sep_row = p_y + n_sugg + 2
        -- \x8f chars with FG=white (interior), BG=blue (line) — same as bottom border style
        local sep_text = string.rep("\x8f", inner_w)
        local sep_line = "\x95" .. sep_text .. "\x95"
        p_win.setCursorPos(p_x, sep_row)
        p_win.blit(sep_line,
            bf .. string.rep(ob, inner_w) .. ob,
            ob .. string.rep(bf, inner_w) .. bf)
    end

    -- Offset for all rows below the suggestion area (1 pad + N sugg + 1 sep = N+2 when has_sugg)
    local off = has_sugg and (n_sugg + 2) or 0

    -- Row off+1: top white padding
    side_row(string.rep(" ", inner_w), string.rep(ob, inner_w), string.rep(ob, inner_w), p_y + off + 1)

    -- Row off+2: label row
    local label_text   = " " .. p_label
    if #label_text > inner_w then label_text = label_text:sub(1, inner_w) end
    local label_padded = label_text .. string.rep(" ", inner_w - #label_text)
    side_row(label_padded, string.rep(of, inner_w), string.rep(ob, inner_w), p_y + off + 2)

    -- Row off+3: input row — "[" + scrolling field + "]"
    local fw = field_w()

    if p_cursor < p_frame_s then
        p_frame_s = p_cursor
    elseif p_cursor > p_frame_s + fw - 1 then
        p_frame_s = p_cursor - fw + 1
    end
    if p_frame_s < 1 then p_frame_s = 1 end

    local vis        = p_value:sub(p_frame_s, p_frame_s + fw - 1)
    local vis_cursor = p_cursor - p_frame_s + 1

    local field_text = vis .. string.rep(" ", fw - #vis)
    local field_fg   = {}
    local field_bg   = {}
    for i = 1, fw do
        field_fg[i] = inf
        field_bg[i] = ib
    end
    if vis_cursor <= fw then
        if vis_cursor <= #vis then
            -- cursor on a char: invert
            field_fg[vis_cursor] = ib
            field_bg[vis_cursor] = inf
        else
            -- cursor past end: gray tint on the space
            field_fg[vis_cursor] = cur
        end
    end

    local input_text    = "[" .. field_text .. "]"
    local full_input    = "\x95" .. input_text .. "\x95"
    local full_input_fg = bf .. of .. table.concat(field_fg) .. of .. ob
    local full_input_bg = ob .. ob .. table.concat(field_bg) .. ob .. bf
    p_win.setCursorPos(p_x, p_y + off + 3)
    p_win.blit(full_input, full_input_fg, full_input_bg)

    -- Row off+4: bottom white padding
    side_row(string.rep(" ", inner_w), string.rep(ob, inner_w), string.rep(ob, inner_w), p_y + off + 4)

    -- Row off+5: plain bottom border (no hint text)
    local bot_text = "\x8a" .. string.rep("\x8f", inner_w) .. "\x85"
    local bot_fg   = string.rep(ob, p_w)
    local bot_bg   = string.rep(bf, p_w)

    p_win.setCursorPos(p_x, p_y + off + 5)
    p_win.blit(bot_text, bot_fg, bot_bg)

    -- Erase any leftover rows in the saved region that are no longer used
    -- (happens when suggestions shrink — paint those rows back from saved_pixels)
    local used_h  = off + 6  -- title(1) + [pad+suggs+sep = off] + pad+label+input+pad+border(5)
    for row = p_y + used_h, p_y + p_save_h - 1 do
        local data = saved_pixels[row]
        if data then
            p_win.setCursorPos(p_x, row)
            p_win.blit(data.text, data.fg, data.bg)
        end
    end
end

-- ── Input Helpers ─────────────────────────────────────────────────────────────

local function insert_char(ch)
    p_sugg_sel = nil  -- typing clears the selection
    p_value    = p_value:sub(1, p_cursor - 1) .. ch .. p_value:sub(p_cursor)
    p_cursor   = p_cursor + 1
    update_suggestions()
    draw()
end

local function do_backspace()
    p_sugg_sel = nil
    if p_cursor > 1 then
        p_value  = p_value:sub(1, p_cursor - 2) .. p_value:sub(p_cursor)
        p_cursor = p_cursor - 1
        update_suggestions()
        draw()
    end
end

local function do_delete()
    p_sugg_sel = nil
    if p_cursor <= #p_value then
        p_value = p_value:sub(1, p_cursor - 1) .. p_value:sub(p_cursor + 1)
        update_suggestions()
        draw()
    end
end

local function select_sugg(idx)
    if #p_suggestions == 0 then
        p_sugg_sel = nil
    else
        p_sugg_sel = ((idx - 1) % #p_suggestions) + 1
    end
    draw()
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Open a text input prompt near screen position (x, y).
---@param win table terminal window
---@param x integer preferred x position
---@param y integer preferred y position
---@param label string prompt label shown above the input field
---@param initial string initial value pre-filled in the input
---@param on_confirm function called with (value) when Enter is pressed
---@param suggestions_fn? function returns {string,...} of possible completions
function prompt.open(win, x, y, label, initial, on_confirm, suggestions_fn)
    if active then prompt.close() end

    p_win           = win
    p_label         = label or ""
    p_value         = initial or ""
    p_cursor        = #p_value + 1
    p_frame_s       = 1
    p_on_confirm    = on_confirm
    p_suggestions_fn = suggestions_fn
    p_suggestions   = {}
    p_sugg_sel      = nil

    -- Width
    local MIN_W   = 24
    local label_w = #p_label + 4
    p_w = math.max(MIN_W, label_w)

    -- Save MAX_H rows upfront so we never read outside saved region as suggestions grow
    -- At max suggestions: off = MAX_SUGGESTIONS+2, used_h = off+6 = MAX_SUGGESTIONS+8
    p_save_h = 8 + MAX_SUGGESTIONS

    -- Clamp to screen (use max possible height for clamping)
    local sw, sh = win.getSize()
    p_x = x
    p_y = y
    if p_x + p_w - 1 > sw then p_x = sw - p_w + 1 end
    if p_y + p_save_h - 1 > sh then p_y = sh - p_save_h + 1 end
    if p_x < 1 then p_x = 1 end
    if p_y < 1 then p_y = 1 end

    update_suggestions()

    active = true
    save_region()
    draw()
end

--- Close and restore pixels.
function prompt.close()
    if not active then return end
    active = false
    p_on_confirm     = nil
    p_suggestions_fn = nil
    p_suggestions    = {}
    p_sugg_sel       = nil
    restore_region()
end

---@return boolean
function prompt.is_active() return active end

--- Redraw on top of whatever is currently on screen (call after timer events).
function prompt.redraw()
    if active then draw() end
end

--- Handle a key event while the prompt is active.
---@param event key_interaction
---@return boolean consumed
function prompt.handle_key(event)
    if not active then return false end
    if not event then return true end  -- modifier-only keys (Shift/Ctrl/Alt) return nil

    if event.type == KEY_CLICK.CHAR then
        insert_char(event.name)

    elseif event.type == KEY_CLICK.DOWN or event.type == KEY_CLICK.HELD then
        local k = event.key

        if k == keys.tab then
            -- Tab: advance selection (Shift+Tab = backwards)
            if #p_suggestions > 0 then
                if event.shift then
                    select_sugg((p_sugg_sel or 1) - 1)
                else
                    select_sugg((p_sugg_sel or 0) + 1)
                end
            end

        elseif k == keys.up then
            if p_sugg_sel then
                if p_sugg_sel > 1 then
                    p_sugg_sel = p_sugg_sel - 1
                else
                    p_sugg_sel = nil  -- deselect when going past top
                end
                draw()
            else
                -- No suggestion selected: move cursor to start
                p_cursor = 1
                draw()
            end

        elseif k == keys.down then
            if #p_suggestions > 0 then
                if p_sugg_sel then
                    if p_sugg_sel < #p_suggestions then
                        p_sugg_sel = p_sugg_sel + 1
                    else
                        p_sugg_sel = 1  -- wrap to top
                    end
                else
                    p_sugg_sel = 1
                end
                draw()
            else
                -- No suggestions: move cursor to end
                p_cursor = #p_value + 1
                draw()
            end

        elseif k == keys.left then
            if p_cursor > 1 then
                p_cursor = p_cursor - 1
                draw()
            end

        elseif k == keys.right then
            if p_cursor <= #p_value then
                p_cursor = p_cursor + 1
                draw()
            end

        elseif k == keys.home then
            p_cursor = 1
            draw()

        elseif k == keys["end"] then
            p_cursor = #p_value + 1
            draw()

        elseif k == keys.backspace then
            do_backspace()

        elseif k == keys.delete then
            do_delete()

        elseif k == keys.enter then
            if p_sugg_sel and p_suggestions[p_sugg_sel] then
                -- Accept highlighted suggestion
                p_value    = p_suggestions[p_sugg_sel]
                p_cursor   = #p_value + 1
                p_sugg_sel = nil
                update_suggestions()
                draw()
                -- Confirm immediately
                local cb  = p_on_confirm
                local val = p_value
                prompt.close()
                if type(cb) == "function" then cb(val) end
            else
                -- Confirm typed text
                local cb  = p_on_confirm
                local val = p_value
                prompt.close()
                if type(cb) == "function" then cb(val) end
            end

        elseif k == keys.escape then
            if p_sugg_sel then
                -- First Escape: just deselect suggestion
                p_sugg_sel = nil
                draw()
            else
                -- Second Escape (or no selection): close
                prompt.close()
            end
        end
    end

    return true
end

-- current on-screen height (title + optional pad/suggestions/sep + pad+label+input+pad+border)
local function used_height()
    local off = #p_suggestions > 0 and (#p_suggestions + 2) or 0
    return off + 6
end

--- Whether an absolute screen position falls inside the visible prompt.
---@param x integer
---@param y integer
---@return boolean
function prompt.contains(x, y)
    if not active then return false end
    return x >= p_x and x <= p_x + p_w - 1
       and y >= p_y and y <= p_y + used_height() - 1
end

--- Handle a mouse event while the prompt is active. A click outside the
--- prompt's bounds dismisses it; clicks inside interact (suggestion rows
--- confirm like Enter, the input row repositions the cursor) instead of
--- closing — the prompt is modal, so everything is consumed either way.
---@param event mouse_interaction
---@return boolean consumed
function prompt.handle_mouse(event)
    if not active then return false end
    if not event or event.type ~= MOUSE_CLICK.DOWN then return true end

    local x, y = event.current.x, event.current.y
    if not prompt.contains(x, y) then
        prompt.close()
        return true
    end

    -- suggestion rows sit at p_y+2 .. p_y+1+N (below the title + pad rows)
    local n = #p_suggestions
    if n > 0 and y >= p_y + 2 and y <= p_y + 1 + n then
        local idx = y - p_y - 1
        local s = p_suggestions[idx]
        if s then
            p_value = s
            local cb = p_on_confirm
            prompt.close()
            if type(cb) == "function" then cb(s) end
        end
        return true
    end

    -- input row: place the cursor at the clicked character
    local off = n > 0 and (n + 2) or 0
    if y == p_y + off + 3 then
        local rel = x - (p_x + 1)   -- 1-based index into the visible field
        if rel >= 1 and rel <= field_w() then
            p_cursor = math.max(1, math.min(#p_value + 1, p_frame_s + rel - 1))
            draw()
        end
    end
    return true
end

--- Handle a paste event — replaces current value.
---@param text string
---@return boolean
function prompt.handle_paste(text)
    if not active then return false end
    p_sugg_sel = nil
    p_value    = text
    p_cursor   = #p_value + 1
    p_frame_s  = 1
    update_suggestions()
    draw()
    return true
end

--- Return list of current domain names for use as a suggestions_fn.
--- Pass the shared._domains domain_leds table (keys are domain names).
---@param domain_leds table domain_name → LED element
---@return function
function prompt.domain_suggestions(domain_leds)
    return function()
        local list = {}
        for name, _ in pairs(domain_leds) do
            table.insert(list, name)
        end
        table.sort(list)
        return list
    end
end

return prompt
