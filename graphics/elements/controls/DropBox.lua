-- DropBox (Dropdown) Control Element
--
-- A clickable button that reveals a dropdown panel of selectable options.
-- When clicked, the panel appears below the button with a list of options
-- rendered as individually clickable rows. Selecting an option closes the
-- dropdown and fires the option's callback (and the parent callback).
--
-- The dropdown panel is a child window created with a higher z-order
-- (later creation time) so it draws on top of sibling elements.

local tcd     = require("scada-common.tcd")
local element = require("graphics.element")
local core    = require("graphics.core")

local ALIGN = core.ALIGN
local MOUSE_CLICK = core.events.MOUSE_CLICK

---@class dropbox_option
---@field text string option display text
---@field callback? function called when this option is selected

---@class dropbox_args
---@field text string button label text
---@field options? dropbox_option[] initial list of options
---@field callback? function called with (option_text, option_index) on selection
---@field min_width? integer minimum button width
---@field alignment? ALIGN text alignment on the button face
---@field fg_bg? cpair button foreground/background colors
---@field active_fg_bg? cpair colors when button is pressed / dropdown is open
---@field drop_fg_bg? cpair dropdown panel foreground/background colors
---@field drop_height? integer max visible rows (default: #options, capped at 6)
---@field parent graphics_element
---@field id? string element id
---@field x? integer 1 if omitted
---@field y? integer auto incremented if omitted
---@field width? integer computed from text if omitted
---@field hidden? boolean true to hide on initial draw

---@param args dropbox_args
---@return DropBox element, element_id id
return function (args)
    element.assert(type(args.text) == "string", "text is a required field")

    local text_width = string.len(args.text)
    local alignment  = args.alignment or ALIGN.CENTER

    -- The button itself is always 1 row tall.
    args.height = 1
    args.can_focus = true
    args.min_width = args.min_width or 0
    if args.width == nil then
        args.width = math.max(text_width, args.min_width) + 2
    end

    -- create new graphics element base object
    local e = element.new(args --[[@as graphics_args]])

    -- ── State ───────────────────────────────────────────────────────────────
    local options    = args.options or {}   -- current option list
    local is_open    = false
    local drop_panel = nil                 -- dropdown Div (created lazily)
    local opt_windows = {}                 -- per-option sub-windows inside drop_panel

    local btn_fg_bg    = e.fg_bg
    local active_fg_bg = args.active_fg_bg
    local drop_fg_bg   = args.drop_fg_bg or core.cpair(colors.white, colors.gray)

    -- ── Button drawing ──────────────────────────────────────────────────────
    local function draw_button(pressed)
        local fg_bg = (pressed and active_fg_bg) and active_fg_bg or btn_fg_bg
        e.w_set_fgd(fg_bg.fgd)
        e.w_set_bkg(fg_bg.bkg)
        e.window.clear()

        local label = args.text
        -- Append a down-arrow indicator
        local arrow = is_open and " \x1e" or " \x1f"
        local display = label .. arrow
        local len = string.len(display)

        if alignment == ALIGN.CENTER then
            e.w_set_cur(math.floor((e.frame.w - len) / 2) + 1, 1)
        elseif alignment == ALIGN.RIGHT then
            e.w_set_cur((e.frame.w - len) + 1, 1)
        else
            e.w_set_cur(1, 1)
        end

        e.w_write(display)
    end

    -- ── Dropdown panel ──────────────────────────────────────────────────────

    -- Compute visible height for the dropdown.
    local function drop_h()
        local n = #options
        if n == 0 then n = 1 end
        local max_h = args.drop_height or 6
        return math.min(n, max_h)
    end

    -- Destroy existing dropdown panel and option windows.
    local function destroy_panel()
        if drop_panel then
            drop_panel.setVisible(false)
            drop_panel = nil
        end
        opt_windows = {}
    end

    -- Build (or rebuild) the dropdown panel window.
    -- The panel is a raw CC window (not a graphics element) positioned
    -- immediately below the button within the PARENT's window space.
    -- This keeps mouse handling simple — we check clicks manually.
    local function build_panel()
        destroy_panel()
        if #options == 0 then return end

        local h = drop_h()
        -- Create panel window as a child of the PARENT's window so it
        -- overlaps sibling elements (CC:T renders later windows on top).
        local parent_win = args.parent.window()
        local px = e.frame.x
        local py = e.frame.y + 1  -- directly below button

        drop_panel = window.create(parent_win, px, py, e.frame.w, h, false)
        drop_panel.setBackgroundColor(drop_fg_bg.bkg)
        drop_panel.setTextColor(drop_fg_bg.fgd)
        drop_panel.clear()

        -- Draw each option row
        for i = 1, math.min(#options, h) do
            local opt = options[i]
            local text = opt.text or ""
            -- Truncate to fit
            if string.len(text) > e.frame.w then
                text = string.sub(text, 1, e.frame.w - 1) .. "\x1a"
            end

            drop_panel.setCursorPos(1, i)
            -- Pad to full width for clickable area
            local padded = text .. string.rep(" ", e.frame.w - string.len(text))
            drop_panel.write(padded)
        end
    end

    -- ── Open / Close ────────────────────────────────────────────────────────

    local function open_dropdown()
        if is_open then return end
        is_open = true
        build_panel()
        if drop_panel then drop_panel.setVisible(true) end
        draw_button(true)
    end

    local function close_dropdown()
        if not is_open then return end
        is_open = false
        if drop_panel then drop_panel.setVisible(false) end
        draw_button(false)
    end

    local function toggle_dropdown()
        if is_open then close_dropdown() else open_dropdown() end
    end

    -- ── Option selection ────────────────────────────────────────────────────

    local function select_option(idx)
        if idx < 1 or idx > #options then return end
        local opt = options[idx]
        close_dropdown()

        -- Fire option-specific callback
        if type(opt.callback) == "function" then
            opt.callback()
        end
        -- Fire parent callback
        if type(args.callback) == "function" then
            args.callback(opt.text, idx)
        end
    end

    -- ── Highlight (hover feedback for dropdown rows) ────────────────────────

    local function highlight_row(row)
        if not drop_panel or not is_open then return end
        local h = drop_h()
        -- Redraw all rows, highlighting the selected one
        for i = 1, math.min(#options, h) do
            local opt = options[i]
            local text = opt.text or ""
            if string.len(text) > e.frame.w then
                text = string.sub(text, 1, e.frame.w - 1) .. "\x1a"
            end
            local padded = text .. string.rep(" ", e.frame.w - string.len(text))

            if i == row then
                drop_panel.setBackgroundColor(drop_fg_bg.fgd)
                drop_panel.setTextColor(drop_fg_bg.bkg)
            else
                drop_panel.setBackgroundColor(drop_fg_bg.bkg)
                drop_panel.setTextColor(drop_fg_bg.fgd)
            end
            drop_panel.setCursorPos(1, i)
            drop_panel.write(padded)
        end
    end

    -- ── Element callbacks ───────────────────────────────────────────────────

    function e.redraw()
        draw_button(is_open)
    end

    -- Mouse handling: check both the button area and the dropdown panel area.
    ---@param event mouse_interaction
    function e.handle_mouse(event)
        if not e.enabled then return end

        local x, y = event.current.x, event.current.y

        -- Check if click is on the button (row 1 of this element)
        if y == 1 and x >= 1 and x <= e.frame.w then
            if event.type == MOUSE_CLICK.TAP or event.type == MOUSE_CLICK.UP then
                toggle_dropdown()
                return
            end
        end

        -- Check if click is in the dropdown area
        if is_open and drop_panel then
            -- Dropdown is at y=2..2+drop_h()-1 relative to this element's parent position
            -- But mouse events are relative to this element's frame.
            -- The dropdown starts at y=2 in parent coords (button is y=1).
            -- Since element.lua transposes events relative to this element,
            -- the dropdown row = y - 1 (button occupies y=1).
            local drop_y = y - 1
            if drop_y >= 1 and drop_y <= drop_h() and x >= 1 and x <= e.frame.w then
                if event.type == MOUSE_CLICK.DOWN then
                    highlight_row(drop_y)
                    return
                elseif event.type == MOUSE_CLICK.TAP or event.type == MOUSE_CLICK.UP then
                    select_option(drop_y)
                    return
                end
            end
        end
    end

    -- Keyboard: space/enter toggle, escape closes.
    ---@param event key_interaction
    function e.handle_key(event)
        if event.type == core.events.KEY_CLICK.DOWN then
            if event.key == keys.space or event.key == keys.enter or event.key == keys.numPadEnter then
                toggle_dropdown()
            elseif event.key == keys.escape then
                close_dropdown()
            end
        end
    end

    -- Close dropdown on unfocus (click elsewhere).
    function e.on_unfocused()
        close_dropdown()
    end

    -- ── Public API ──────────────────────────────────────────────────────────

    ---@class DropBox:graphics_element
    local DropBox, id = e.complete(true)

    -- Replace all options.
    ---@param new_options dropbox_option[]
    function DropBox.set_options(new_options)
        options = new_options or {}
        if is_open then
            build_panel()
            if drop_panel then drop_panel.setVisible(true) end
        end
    end

    -- Append a single option.
    ---@param text string
    ---@param callback? function
    function DropBox.add_option(text, callback)
        table.insert(options, { text = text, callback = callback })
        if is_open then
            build_panel()
            if drop_panel then drop_panel.setVisible(true) end
        end
    end

    -- Remove all options.
    function DropBox.clear_options()
        options = {}
        close_dropdown()
        destroy_panel()
    end

    -- Programmatic open.
    function DropBox.open() open_dropdown() end

    -- Programmatic close.
    function DropBox.close() close_dropdown() end

    -- Query open state.
    ---@return boolean
    function DropBox.is_open() return is_open end

    return DropBox, id
end
