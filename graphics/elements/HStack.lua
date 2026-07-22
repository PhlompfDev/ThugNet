-- HStack Graphics Element
--
-- A horizontal stack container.  Children are placed left-to-right in the
-- order they are created; no manual x/y coordinates needed.
--
-- Args:
--   parent   graphics_element  (required)
--   x, y     integer           position within parent (auto if omitted)
--   width    integer           defaults to parent width
--   height   integer           height of the row (defaults to parent height)
--   gap      integer           blank columns inserted between children (default 0)
--   padding  number|table      inset applied before placing children
--                              formats: 1  |  {top,right,bottom,left}  |  {top=,right=,...}
--   fg_bg    cpair             colors (inherited if omitted)
--   hidden   boolean           start hidden
--
-- Example:
--   local row = HStack{ parent=page, x=1, y=4, height=1, gap=2 }
--   PushButton{ parent=row, text="OK",     width=8 }
--   PushButton{ parent=row, text="Cancel", width=8 }
--
-- Note: do not specify x or y on HStack children; HStack controls placement.

local element = require("graphics.element")

---@class hstack_args
---@field parent graphics_element
---@field id? string element id
---@field x? integer 1 if omitted
---@field y? integer auto incremented if omitted
---@field width? integer parent width if omitted
---@field height? integer defaults to parent height
---@field gframe? graphics_frame frame instead of x/y/width/height
---@field fg_bg? cpair foreground/background colors
---@field hidden? boolean true to hide on initial draw
---@field gap? integer blank columns between children (default 0)
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

-- Create a new HStack container element.
---@nodiscard
---@param args hstack_args
---@return graphics_element element, element_id id
return function(args)
    local e = element.new(args --[[@as graphics_args]])

    local pt, pr, pb, pl = parse_padding(args.padding)

    -- Create a content window for padding insets.
    -- We give the virtual content window a large height (1 000 rows) so that
    -- the auto-y counter used by the element system never exceeds the window
    -- height when multiple children are added in sequence.  The outer element
    -- clips everything beyond its own visible height so only real rows render.
    local cw = e.frame.w - pl - pr
    local ch = e.frame.h - pt - pb
    if cw >= 1 and ch >= 1 then
        e.content_window = window.create(e.window, pl + 1, pt + 1, cw, 1000, true)
        e.mouse_window_shift = { x = pl, y = pt }
        -- Prime the content window with the element's background color so
        -- its initial visible render doesn't paint black over the outer window.
        e.content_window.setBackgroundColor(e.fg_bg.bkg)
        e.content_window.clear()
    end

    ---@class HStack:graphics_element
    local HStack, id = e.complete()

    -- Track the x cursor (columns from the left edge of the content window).
    local cur_x = 1
    local gap   = args.gap or 0

    -- Override __add_child so that each child is placed at the current x cursor.
    --
    -- Strategy: wrap the child's prepare_template before __add_child calls it.
    -- prepare_template(offset_x, offset_y, next_y) uses offset_x and offset_y
    -- to adjust the position/bounds tracking after the CC:T window is created.
    -- By passing the right offsets we avoid any post-hoc repositioning call:
    --
    --   window created at (f.x, f.y)  (defaults: x=1, y=next_y)
    --   self.position.x = f.x + offset_x  → we want cur_x  → offset_x = cur_x - f.x
    --   self.position.y = f.y + offset_y  → we want 1      → offset_y = 1 - f.y
    --
    -- We also reposition the CC:T window object itself (child.window) so the
    -- actual drawn pixels appear at (cur_x, 1) within the content window.

    local orig_add = HStack.__add_child

    HStack.__add_child = function(key, child)
        -- Capture the current cursor value for this particular child.
        local slot_x = cur_x

        -- Wrap prepare_template before orig_add calls it.
        local orig_pt = child.prepare_template
        child.prepare_template = function(ox, oy, next_y)
            -- Compute where the element system would place this child.
            -- f.x defaults to 1 (args.x or 1 inside prepare_template).
            -- f.y defaults to next_y.
            local win_x = 1   -- assume no explicit args.x for HStack children
            local win_y = next_y

            -- Call original with adjusted offsets so bounds land at (slot_x, 1).
            orig_pt(slot_x - win_x, 1 - win_y, next_y)

            -- Reposition the CC:T window to the correct visual column/row.
            -- child.window is set by orig_pt (window.create inside prepare_template).
            if child.window then
                child.window.reposition(slot_x, 1)
            end
        end

        local elem_id = orig_add(key, child)

        -- Restore the original prepare_template.
        child.prepare_template = orig_pt

        -- Advance the horizontal cursor by this child's width plus any gap.
        cur_x = cur_x + child.frame.w + gap

        return elem_id
    end

    return HStack, id
end
