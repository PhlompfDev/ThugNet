-- VStack Graphics Element
--
-- A vertical stack container.  Children are placed top-to-bottom in the
-- order they are created; no manual x/y coordinates needed.
--
-- Args:
--   parent   graphics_element  (required)
--   x, y     integer           position within parent (auto if omitted)
--   width    integer           defaults to parent width
--   height   integer           defaults to parent height
--   gap      integer           blank rows inserted between children (default 0)
--   padding  number|table      inset applied before stacking children
--                              formats: 1  |  {top,right,bottom,left}  |  {top=,right=,...}
--   fg_bg    cpair             colors (inherited if omitted)
--   hidden   boolean           start hidden
--
-- Example:
--   local col = VStack{ parent=page, x=2, y=3, width=20, gap=1, padding=1 }
--   PushButton{ parent=col, text="One" }
--   PushButton{ parent=col, text="Two" }   -- placed one row below "One" + gap

local element = require("graphics.element")

---@class vstack_args
---@field parent graphics_element
---@field id? string element id
---@field x? integer 1 if omitted
---@field y? integer auto incremented if omitted
---@field width? integer parent width if omitted
---@field height? integer parent height if omitted
---@field gframe? graphics_frame frame instead of x/y/width/height
---@field fg_bg? cpair foreground/background colors
---@field hidden? boolean true to hide on initial draw
---@field gap? integer blank rows between children (default 0)
---@field padding? number|table inset padding

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

-- Create a new VStack container element.
---@nodiscard
---@param args vstack_args
---@return graphics_element element, element_id id
return function(args)
    local e = element.new(args --[[@as graphics_args]])

    local pt, pr, pb, pl = parse_padding(args.padding)

    -- Create an inset content window so children auto-position within the
    -- padded area.  The content window also handles bottom/right padding by
    -- being sized to (w - pl - pr) x (h - pt - pb).
    if pt > 0 or pr > 0 or pb > 0 or pl > 0 then
        local cw = e.frame.w - pl - pr
        local ch = e.frame.h - pt - pb
        if cw >= 1 and ch >= 1 then
            e.content_window = window.create(e.window, pl + 1, pt + 1, cw, ch, true)
            e.mouse_window_shift = { x = pl, y = pt }
            -- Prime the content window with the element's background color so
            -- its initial visible render doesn't paint black over the outer window.
            e.content_window.setBackgroundColor(e.fg_bg.bkg)
            e.content_window.clear()
        end
    end

    ---@class VStack:graphics_element
    local VStack, id = e.complete()

    -- Insert gap blank lines after each child so subsequent children are
    -- pushed down by `gap` extra rows.
    local gap = args.gap or 0
    if gap > 0 then
        local orig_child_ready = VStack.__child_ready
        VStack.__child_ready = function(key, child)
            orig_child_ready(key, child)
            for _ = 1, gap do VStack.line_break() end
        end
    end

    return VStack, id
end
