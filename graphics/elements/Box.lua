-- Box Graphics Element
--
-- A bordered rectangular container with an optional title in the header row.
-- The interior acts like a Div: children are auto-stacked inside the border,
-- with optional extra padding.
--
-- Visual layout (width=22, height=6, title="Lighting"):
--   [      Lighting      ]  <- row 1: solid thick bar (border_color bg, title_fg text, centered)
--   |                   |   <- rows 2..h-1: thin V sides on content bg
--   |   [content here]  |
--   |                   |
--   |                   |
--   +-------------------+   <- row h: thin BL + H*(w-2) + BR
--
-- All border characters use the CC:T 2x3 block encoding (char = 128 + bitmask).
-- For even-inner thin borders the lit pixels are always drawn as FG=border_color
-- on BG=content_bg so the border line sits in the middle row of the cell.
--
-- Args:
--   parent        graphics_element  (required)
--   x, y          integer           position within parent (auto if omitted)
--   width         integer           defaults to parent width
--   height        integer           defaults to parent height (minimum 3)
--   title         string            optional label centered in the top bar
--   title_fg      color             title text color (defaults to colors.white)
--   border_color  color             header bar + border line color (defaults to colors.yellow)
--   fg_bg         cpair             content background and foreground (inherited if omitted)
--   padding       number|table      extra inset inside the border
--                                   formats: 1  |  {top,right,bottom,left}  |  {top=,right=,...}
--   hidden        boolean           start hidden
--
-- Border characters (CC:T non-even-inner thin set, same as Rectangle.lua thin+not-even_inner):
--   Used with FG=content_bg, BG=border_color so the bar appears at the BOTTOM of the cell.
--   BL = \x8a  bits p1,p3     → top-right + mid-right lit; unlit left col + bot row = BG = border_color
--   BR = \x85  bits p0,p2     → top-left + mid-left lit;  unlit right col + bot row = BG = border_color
--   H  = \x8f  bits p0,p1,p2,p3 → top+mid rows lit; unlit bot row = BG = border_color (bar at bottom)
--   V  = \x95  bits p0,p2,p4  → full left column only (left half-block, used with inverted colors)
local BL, BR = "\x8a", "\x85"
local H,  V  = "\x8f", "\x95"


local element = require("graphics.element")

---@class box_args
---@field parent graphics_element
---@field id? string element id
---@field x? integer 1 if omitted
---@field y? integer auto incremented if omitted
---@field width? integer parent width if omitted
---@field height? integer parent height if omitted
---@field gframe? graphics_frame frame instead of x/y/width/height
---@field fg_bg? cpair border and background colors
---@field hidden? boolean true to hide on initial draw
---@field title? string optional text in the top bar
---@field title_fg? color title text color (defaults to colors.white)
---@field border_color? color color used for border lines (defaults to colors.yellow)
---@field padding? number|table extra inset inside the border

-- Parse padding into (top, right, bottom, left).
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

-- Create a new Box container element.
---@nodiscard
---@param args box_args
---@return graphics_element element, element_id id
return function(args)
    local e = element.new(args --[[@as graphics_args]])

    local w     = e.frame.w
    local h     = e.frame.h
    local title = args.title or ""
    local pt, pr, pb, pl = parse_padding(args.padding)

    -- Resolved colors.  e.fg_bg is set by element.new (inherited when not given).
    local border_color = args.border_color or colors.yellow
    local title_fg     = args.title_fg     or colors.white
    local content_bg   = e.fg_bg.bkg

    -- ── Pre-computed blit strings ─────────────────────────────────────────────
    -- CC:T blit: e.w_blit(text, fg_blit, bg_blit)
    -- Lit pixels (■) appear as FG color; unlit pixels (□) appear as BG color.
    local border_blit = colors.toBlit(border_color)
    local bg_blit     = colors.toBlit(content_bg)
    local title_blit  = colors.toBlit(title_fg)
    local inner_w     = w - 2

    -- Side rows (rows 2..h-1):
    --   Left  col: V with FG=border_color, BG=content_bg → left half = border_color (thin line at left edge)
    --   Inner    : spaces with FG=bg, BG=bg              → solid content_bg fill
    --   Right col: V with FG=content_bg, BG=border_color → right half = border_color (fills right edge, no spill)
    local p_s       = V .. string.rep(" ", inner_w) .. V
    local blit_fg_s = border_blit .. string.rep(bg_blit, inner_w) .. bg_blit
    local blit_bg_s = bg_blit     .. string.rep(bg_blit, inner_w) .. border_blit

    -- Bottom border (row h):
    --   All cells: FG=content_bg, BG=border_color  (inverted from sides)
    --   BL \x8a: lit=p1,p3 (top-right + mid-right) → FG=dark; unlit left col + bot row = BG=yellow ✓
    --   H  \x8f: lit=p0..p3 (top+mid rows)         → FG=dark; unlit bot row = BG=yellow (bar at bottom) ✓
    --   BR \x85: lit=p0,p2 (top-left + mid-left)   → FG=dark; unlit right col + bot row = BG=yellow ✓
    local p_bot       = BL .. string.rep(H, inner_w) .. BR
    local blit_fg_bot = string.rep(bg_blit,     w)
    local blit_bg_bot = string.rep(border_blit, w)

    -- Draw the border.  Called by complete(true) at init and by public.redraw().
    function e.redraw()
        -- Row 1: solid header bar — spaces on border_color bg, title in title_fg
        -- Clamp title to box width so all three blit strings stay the same length
        -- (prevents crashes when the box is constrained narrower than the title).
        local safe_title = title:sub(1, w)
        local pad_l = math.floor((w - #safe_title) / 2)
        local pad_r = w - #safe_title - pad_l
        e.w_set_cur(1, 1)
        e.w_blit(string.rep(" ", pad_l) .. safe_title .. string.rep(" ", pad_r),
                 string.rep(title_blit,  w),
                 string.rep(border_blit, w))

        -- Rows 2..h-1: side bars (full-width blit covers left V, interior spaces, right V)
        for row = 2, h - 1 do
            e.w_set_cur(1, row)
            e.w_blit(p_s, blit_fg_s, blit_bg_s)
        end

        -- Row h: bottom border
        e.w_set_cur(1, h)
        e.w_blit(p_bot, blit_fg_bot, blit_bg_bot)
    end

    -- ── Content window ────────────────────────────────────────────────────────
    -- Interior: cols 2…w-1, rows 2…h-1, further inset by padding.
    local cwin_x = 2 + pl
    local cwin_y = 2 + pt
    local cwin_w = w - 2 - pl - pr
    local cwin_h = h - 2 - pt - pb

    if cwin_w >= 1 and cwin_h >= 1 then
        e.content_window = window.create(e.window, cwin_x, cwin_y, cwin_w, cwin_h, true)
        -- element.lua applies (mouse_window_shift + 1) as the child event shift,
        -- so store (cwin_x - 1, cwin_y - 1) so the effective shift equals cwin_x/cwin_y.
        e.mouse_window_shift = { x = cwin_x - 1, y = cwin_y - 1 }
        e.content_window.setBackgroundColor(e.fg_bg.bkg)
        e.content_window.clear()
    end

    ---@class Box:graphics_element
    -- complete(true) calls e.redraw() immediately to paint the border.
    local Box, id = e.complete(true)

    return Box, id
end
