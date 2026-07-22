-- Indicator "LED" Graphics Element

local core = require("graphics.core")
local util    = require("scada-common.util")

local element = require("graphics.element")
local flasher = require("graphics.flasher")

---@class indicator_led_args
---@field label string indicator label
---@field colors cpair on/off colors (a/b respectively)
---@field min_label_width? integer label length if omitted
---@field flash? boolean whether to flash on true rather than stay on
---@field period? PERIOD flash period
---@field parent graphics_element
---@field id? string element id
---@field x? integer 1 if omitted
---@field y? integer auto incremented if omitted
---@field fg_bg? cpair foreground/background colors
---@field hidden? boolean true to hide on initial draw

-- Create a new indicator LED element.
---@nodiscard
---@param args indicator_led_args
---@return LED element, element_id id
return function (args)
    element.assert(type(args.label) == "string", "label is a required field")
    element.assert(type(args.colors) == "table", "colors is a required field")

    if args.flash then
        element.assert(util.is_int(args.period), "period is a required field if flash is enabled")
    end

    args.height = 1
    args.width = math.max(args.min_label_width or 0, string.len(args.label)) + 2

    local flash_on = true

    -- create new graphics element base object
    local e = element.new(args --[[@as graphics_args]])

    e.value = false

    local on_pair    = args.colors          -- green/red
    local flash_pair = core.cpair(colors.green, args.colors.color_b)  -- gray/red

    local function flash_callback()
        e.w_set_cur(1, 1)

        local fg = flash_on and flash_pair.blit_a or on_pair.blit_a
        e.w_blit("\x8c", fg, e.fg_bg.blit_bkg)

        flash_on = not flash_on
    end

    -- enable light or start flashing
    local function enable()
        if args.flash then
            flash_on = true
            flasher.stop(flash_callback)   -- remove any existing copy before re-registering
            flasher.start(flash_callback, args.period)
        else
            e.w_set_cur(1, 1)
            e.w_blit("\x8c", args.colors.blit_a, e.fg_bg.blit_bkg)
        end
    end

    -- disable light or stop flashing
    local function disable()
        if args.flash then
            flash_on = false
            flasher.stop(flash_callback)
        end

        e.w_set_cur(1, 1)
        -- solid red (off color)
        e.w_blit("\x8c", args.colors.blit_b, e.fg_bg.blit_bkg)
    end


    -- on state change
    ---@param new_state boolean indicator state
    function e.on_update(new_state)
        e.value = new_state
        if new_state then enable() else disable() end
    end

    -- set indicator state
    ---@param val boolean indicator state
    function e.set_value(val) e.on_update(val) end

    -- change the on/off colors after construction and repaint at the current
    -- value. Backport of the toolkit's protected.recolor pattern (DataIndicator,
    -- HorizontalBar, VerticalBar) so the front panel can flip a heartbeat LED
    -- between a green/dark pulse and solid red without rebuilding it. enable()/
    -- disable() dereference args.colors.blit_a/blit_b each call, so reassign
    -- that table; on_pair/flash_pair back the flash path.
    ---@param new_colors cpair new on/off colors
    function e.recolor(new_colors)
        args.colors = new_colors
        on_pair     = new_colors
        flash_pair  = core.cpair(colors.green, new_colors.color_b)
        e.on_update(e.value)
    end

    -- draw label and indicator light
    function e.redraw()
        e.on_update(e.value)
        if string.len(args.label) > 0 then
            e.w_set_cur(3, 1)
            e.w_write(args.label)
        end
    end

    ---@class LED:graphics_element
    local LED, id = e.complete(true)

    return LED, id
end
