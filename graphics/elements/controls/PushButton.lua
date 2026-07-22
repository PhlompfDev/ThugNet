-- Button Graphics Element

local tcd     = require("scada-common.tcd")
local util    = require("scada-common.util")

local core    = require("graphics.core")
local element = require("graphics.element")

local ALIGN = core.ALIGN

local MOUSE_CLICK = core.events.MOUSE_CLICK
local KEY_CLICK = core.events.KEY_CLICK

---@class push_button_args
---@field text string button text
---@field callback function function to call on touch
---@field min_width? integer text length if omitted
---@field alignment? ALIGN text align if min width > length
---@field active_fg_bg? cpair foreground/background colors when pressed (full flash)
---@field active_fg? color text-only color when pressed (bg unchanged; ignored when active_fg_bg is set)
---@field dis_fg_bg? cpair foreground/background colors when disabled
---@field parent graphics_element
---@field id? string element id
---@field x? integer 1 if omitted
---@field y? integer auto incremented if omitted
---@field fg_bg? cpair foreground/background colors
---@field hidden? boolean true to hide on initial draw

-->> Create a new push button control element.
---@param args push_button_args
---@return PushButton element, element_id id
return function (args)
    element.assert(type(args.text) == "string", "text is a required field")
    element.assert(type(args.callback) == "function", "callback is a required field")
    element.assert(type(args.min_width) == "nil" or (type(args.min_width) == "number" and args.min_width > 0), "min_width must be nil or a number > 0")

    local text_width = string.len(args.text)
    local alignment = args.alignment or ALIGN.CENTER

    args.can_focus = true
    args.min_width = args.min_width or 0
    if args.width == nil then
        args.width = math.max(text_width, args.min_width) + 2
    end

    -->> provide a constraint condition to element creation to prefer a single line button
    ---@param frame graphics_frame
    local function constrain(frame)
        -- frame.w can be <= 0 here if the button was placed past the parent's right edge;
        -- clamp so the element's own "frame width not >= 1" assert reports it instead of strwrap
        return frame.w, math.max(1, #util.strwrap(args.text, math.max(1, frame.w)))
    end

    -->> create new graphics element base object
    local e = element.new(args --[[@as graphics_args]], constrain)

    local text_lines = util.strwrap(args.text, e.frame.w)

    -- Resolved flash colors. active_fg_bg takes priority over active_fg.
    local flash_fgd = args.active_fg_bg and args.active_fg_bg.fgd or args.active_fg
    local flash_bkg = args.active_fg_bg and args.active_fg_bg.bkg or nil
    local has_flash = flash_fgd ~= nil

    -->> draw the button
    function e.redraw()
        e.window.clear()

        for i = 1, #text_lines do
            if i > e.frame.h then break end

            local len = string.len(text_lines[i])

            -->> use cursor position to align this line
            if alignment == ALIGN.CENTER then
                e.w_set_cur(math.floor((e.frame.w - len) / 2) + 1, i)
            elseif alignment == ALIGN.RIGHT then
                e.w_set_cur((e.frame.w - len) + 1, i)
            else
                e.w_set_cur(1, i)
            end

            e.w_write(text_lines[i])
        end
    end

    -->> draw the button as pressed
    local function show_pressed()
        if e.enabled and has_flash then
            e.value = true
            e.w_set_fgd(flash_fgd)
            if flash_bkg then e.w_set_bkg(flash_bkg) end
            e.redraw()
        end
    end

    -->> draw the button as unpressed
    local function show_unpressed()
        if e.enabled and has_flash then
            e.value = false
            e.w_set_fgd(e.fg_bg.fgd)
            if flash_bkg then e.w_set_bkg(e.fg_bg.bkg) end
            e.redraw()
        end
    end

    -->> handle mouse interaction
    ---@param event mouse_interaction mouse event
    function e.handle_mouse(event)
        if e.enabled then
            if event.type == MOUSE_CLICK.TAP then
                show_pressed()
                -- show as unpressed in 0.25 seconds
                if has_flash then tcd.dispatch(0.25, show_unpressed) end
                args.callback()
            elseif event.type == MOUSE_CLICK.DOWN then
                show_pressed()
            elseif event.type == MOUSE_CLICK.UP then
                show_unpressed()
                if e.in_frame_bounds(event.current.x, event.current.y) then
                    args.callback()
                end
            end
        end
    end

    -->> handle keyboard interaction
    ---@param event key_interaction key event
    function e.handle_key(event)
        if event.type == KEY_CLICK.DOWN then
            if event.key == keys.space or event.key == keys.enter or event.key == keys.numPadEnter then
                args.callback()
                -- visualize click without unfocusing
                show_unpressed()
                if has_flash then tcd.dispatch(0.25, show_pressed) end
            end
        end
    end

    -->> set the value (true simulates pressing the button)
    ---@param val boolean new value
    ---@param mirrored boolean|nil apply visual feedback without callbacks
    function e.set_value(val, mirrored)
        if val then
            if mirrored then
                show_pressed()
                if has_flash then tcd.dispatch(0.25, show_unpressed) end
            else
                e.handle_mouse(core.events.mouse_generic(core.events.MOUSE_CLICK.UP, 1, 1))
            end
        end
    end

    -->> show butten as enabled
    function e.on_enabled()
        if args.dis_fg_bg ~= nil then
            e.value = false
            e.w_set_fgd(e.fg_bg.fgd)
            e.w_set_bkg(e.fg_bg.bkg)
            e.redraw()
        end
    end

    -->> show button as disabled
    function e.on_disabled()
        if args.dis_fg_bg ~= nil then
            e.value = false
            e.w_set_fgd(args.dis_fg_bg.fgd)
            e.w_set_bkg(args.dis_fg_bg.bkg)
            e.redraw()
        end
    end

    -->> handle focus
    e.on_focused = show_pressed
    e.on_unfocused = show_unpressed

    -- Recolor the button's resting colors and repaint. TextBox has had this
    -- since the framework was vendored; PushButton did not, so callers hit
    -- element.lua's no-op protected.recolor and nothing happened. The Update
    -- button's pulse needs it.
    --
    -- Unlike TextBox.recolor (single color, foreground only), this takes a
    -- cpair and sets both foreground and background, since the pulse
    -- alternates the button's background. e.fg_bg (not args.fg_bg) is updated
    -- because that's the resting-color storage show_unpressed/on_enabled read
    -- from -- args.fg_bg is only consulted once, at construction.
    ---@param new_fg_bg cpair
    function e.recolor(new_fg_bg)
        e.fg_bg = new_fg_bg
        e.w_set_fgd(new_fg_bg.fgd)
        e.w_set_bkg(new_fg_bg.bkg)
        e.redraw()
    end

    ---@class PushButton:graphics_element
    local PushButton, id = e.complete(true)

    return PushButton, id
end
