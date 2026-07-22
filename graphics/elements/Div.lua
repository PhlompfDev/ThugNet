-- Div (Division, like in HTML) Graphics Element
--
-- Optional `padding` arg creates an inset content area so children
-- auto-position inside the padded bounds without manual x/y offsets.
--
-- padding formats (CSS order):
--   padding = 1                       -- all four sides equal
--   padding = {2, 1, 2, 1}            -- {top, right, bottom, left}
--   padding = {top=1, right=2, bottom=1, left=2}

local element = require("graphics.element")

---@class div_args
---@field parent graphics_element
---@field id? string element id
---@field x? integer 1 if omitted
---@field y? integer auto incremented if omitted
---@field width? integer parent width if omitted
---@field height? integer parent height if omitted
---@field gframe? graphics_frame frame instead of x/y/width/height
---@field fg_bg? cpair foreground/background colors
---@field hidden? boolean true to hide on initial draw
---@field padding? number|table optional inset: number, {t,r,b,l}, or {top,right,bottom,left}

-- Parse a padding value into (top, right, bottom, left) integers.
---@param p number|table|nil
---@return integer top, integer right, integer bottom, integer left
local function parse_padding(p)
    if not p then return 0, 0, 0, 0 end
    if type(p) == "number" then return p, p, p, p end
    if type(p) == "table" then
        if p.top ~= nil or p.right ~= nil or p.bottom ~= nil or p.left ~= nil then
            return p.top or 0, p.right or 0, p.bottom or 0, p.left or 0
        else
            return p[1] or 0, p[2] or 0, p[3] or 0, p[4] or 0
        end
    end
    return 0, 0, 0, 0
end

-- Create a new div container element.
---@nodiscard
---@param args div_args
---@return Div element, element_id id
return function (args)
    -- create new graphics element base object
    local e = element.new(args --[[@as graphics_args]])

    -- Apply padding by replacing the parent window with a smaller content window.
    -- Children use public.window() which returns content_window when set.
    local pt, pr, pb, pl = parse_padding(args.padding)
    if pt > 0 or pr > 0 or pb > 0 or pl > 0 then
        local cw = e.frame.w - pl - pr
        local ch = e.frame.h - pt - pb
        if cw >= 1 and ch >= 1 then
            e.content_window = window.create(e.window, pl + 1, pt + 1, cw, ch, true)
            -- Shift mouse event coordinates so children receive events relative
            -- to the content window origin rather than the outer window origin.
            e.mouse_window_shift = { x = pl, y = pt }
            -- Prime the content window with the element's background color so
            -- its initial visible render doesn't paint black over the outer window.
            if args.fg_bg then
                e.content_window.setBackgroundColor(args.fg_bg.bkg)
                e.content_window.clear()
            end
        end
    end

    ---@class Div:graphics_element
    local Div, id = e.complete()

    return Div, id
end
