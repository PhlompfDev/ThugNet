--
-- graphics/ui.lua  ─  Graphics Library Barrel Module
--
-- Single require that re-exports every element, container, and utility
-- from the graphics library. Import once per file instead of 10+ lines.
--
-- Usage (two patterns):
--
--   Pattern A — destructure what you need:
--     local ui = require("graphics.ui")
--     local Div, VStack, PushButton = ui.Div, ui.VStack, ui.PushButton
--     local cpair, ALIGN = ui.cpair, ui.ALIGN
--
--   Pattern B — access inline:
--     local ui = require("graphics.ui")
--     ui.PushButton{ parent=row, text="OK", callback=fn }
--

local ui = {}

-- ─── Core modules ─────────────────────────────────────────────────────────────
-- Full module references for advanced use
ui.core     = require("graphics.core")     -- cpair, ALIGN, gframe, border, pipe
ui.flasher  = require("graphics.flasher")  -- PERIOD constants, start/stop/run/clear
ui.events   = require("graphics.events")   -- CLICK_BUTTON, MOUSE_CLICK, KEY_CLICK enums

-- ─── Core shortcuts ───────────────────────────────────────────────────────────
-- Commonly used helpers hoisted to the top level for convenience.

-- ALIGN  →  { LEFT=1, CENTER=2, RIGHT=3 }
-- Usage:  alignment=ui.ALIGN.CENTER
ui.ALIGN = ui.core.ALIGN

-- cpair(fg_color, bg_color)  →  color pair table
-- Fields: color_a, color_b, blit_a, blit_b, fgd, bkg, blit_fgd, blit_bkg
-- Usage:  fg_bg=ui.cpair(colors.white, colors.black)
ui.cpair = ui.core.cpair

-- PERIOD  →  { BLINK_250_MS=1, BLINK_500_MS=2, BLINK_1000_MS=3 }
-- Usage:  period=ui.PERIOD.BLINK_500_MS  (with flash=true on LED/IndicatorLight/etc.)
ui.PERIOD = ui.flasher.PERIOD

-- gframe(x, y, w, h)  →  graphics frame table (alternative to x/y/width/height)
ui.gframe = ui.core.gframe

-- border(width, color, even?)  →  border definition for Rectangle element
-- even: if true, adjusts inner offset so border appears even on odd-size cells
ui.border = ui.core.border

-- ─── Container elements ───────────────────────────────────────────────────────

-- DisplayBox  →  root element; wraps a terminal or monitor window
-- Required:  window (term.current() or peripheral.wrap("monitor_N"))
-- All other elements must eventually be children of a DisplayBox.
ui.DisplayBox = require("graphics.elements.DisplayBox")

-- Div  →  basic rectangular container; no special layout logic
-- Optional: padding (number | {t,r,b,l} | {top=,right=,bottom=,left=})
-- Children use auto-y (stack below sibling) unless y is specified.
ui.Div = require("graphics.elements.Div")

-- VStack  →  vertical auto-stack container
-- Optional: gap (integer, columns of space between children), padding
-- Children omit y to auto-stack; omit width to inherit parent width.
ui.VStack = require("graphics.elements.VStack")

-- HStack  →  horizontal auto-stack container
-- Optional: gap (integer, columns between children), padding
-- Children must specify width; they auto-place left-to-right.
ui.HStack = require("graphics.elements.HStack")

-- MultiPane  →  shows exactly one pane at a time from a list
-- Required: panes (list of graphics_elements, all siblings of MultiPane)
-- set_value(idx) → show pane at 1-based index; all others hidden
ui.MultiPane = require("graphics.elements.MultiPane")

-- Box  →  titled bordered panel; children placed inside the padded content area
-- Required: title (string)
-- Optional: title_fg (color), border_color (color), padding, fg_bg
ui.Box = require("graphics.elements.Box")

-- Rectangle  →  bordered container without a title
-- Required: border (use ui.border(width, color))
-- Optional: thin (bool), even_inner (bool)
ui.Rectangle = require("graphics.elements.Rectangle")

-- ListBox  →  scrollable child container with an optional nav bar
-- Optional: scroll_height (int), item_pad (int), nav_fg_bg (cpair), nav_active (cpair)
ui.ListBox = require("graphics.elements.ListBox")

-- AppMultiPane  →  MultiPane variant with built-in navigation UI
ui.AppMultiPane = require("graphics.elements.AppMultiPane")

-- ─── Display elements ─────────────────────────────────────────────────────────

-- TextBox  →  read-only text display; auto-sizes to parent width if omitted
-- Required: text (string)
-- Optional: alignment (ALIGN.LEFT/CENTER/RIGHT), fg_bg, trim_whitespace (bool)
-- set_value(str)  →  update text content
-- recolor(color)  →  change text foreground color
ui.TextBox = require("graphics.elements.TextBox")

-- Tiling  →  repeating decorative tile pattern (fills its area with a character)
ui.Tiling = require("graphics.elements.Tiling")

-- ColorMap  →  display a grid of colors (for debugging palette assignments)
ui.ColorMap = require("graphics.elements.ColorMap")

-- PipeNetwork  →  visualize a pipe network using core.pipe() definitions
ui.PipeNetwork = require("graphics.elements.PipeNetwork")

-- ─── Control elements ─────────────────────────────────────────────────────────

-- PushButton  →  momentary button; fires callback on every click
-- Required: text, callback
-- Optional: min_width, alignment, fg_bg, active_fg_bg, dis_fg_bg
-- set_value(val, mirrored?) → simulates press if val is truthy
--   mirrored=true skips the callback (use for cross-display mirroring)
-- Focusable: yes (Enter/Space triggers)
ui.PushButton = require("graphics.elements.controls.PushButton")

-- Checkbox  →  boolean toggle rendered as a [ ]/[✓] box with a label
-- Required: label, box_fg_bg (cpair: box fg and bg colors)
-- Optional: disable_fg_bg, default (bool), callback
-- set_value(bool)   → set checked state (does NOT call callback)
-- get_value()       → current boolean
-- Focusable: yes (Space/Enter toggles)
-- Width: auto = 2 + len(label)
ui.Checkbox = require("graphics.elements.controls.Checkbox")

-- RadioButton  →  vertical exclusive-select group; value is a 1-based index
-- Required: options (list of strings), radio_colors (cpair), select_color (color)
-- Optional: default (index, default=1), min_width, callback, alignment
-- set_value(idx)  →  select option without firing callback
-- get_value()     →  current 1-based index
-- Height: = number of options (one row per option)
ui.RadioButton = require("graphics.elements.controls.RadioButton")

-- Radio2D  →  2-dimensional radio button grid
ui.Radio2D = require("graphics.elements.controls.Radio2D")

-- SwitchButton  →  latching toggle button (stays pressed/released)
-- Required: text, callback, active_fg_bg
-- Optional: default (bool, default=false), min_width, fg_bg
-- set_value(bool)  →  set state WITHOUT calling callback
-- get_value()      →  current boolean
-- Note: callback fires on user interaction only, not set_value()
ui.SwitchButton = require("graphics.elements.controls.SwitchButton")

-- HazardButton  →  3-row accent-bordered button for dangerous actions
-- Required: text, accent (color), callback
-- Optional: dis_colors (cpair), timeout (seconds, default 1.5)
-- HazardButton.on_response(success: bool)  →  shows success/failure blink animation
-- set_value(true)  →  simulates a button press
-- Height: always 3. Width: len(text) + 4.
ui.HazardButton = require("graphics.elements.controls.HazardButton")

-- MultiButton  →  horizontal exclusive-select strip; all options on one row
-- Required: options (list of {text, fg_bg, active_fg_bg}), callback
-- Optional: default (index, default=1), min_width
-- set_value(idx)  →  select option without firing callback
-- get_value()     →  current 1-based index
-- Width: computed from button widths + separators
ui.MultiButton = require("graphics.elements.controls.MultiButton")

-- TabBar  →  horizontal tab navigation strip
-- Required: tabs (list of {name, color}), callback (fn(idx))
-- Optional: min_width (minimum width per tab)
-- set_value(idx)  →  select tab without firing callback
-- Height: always 1
ui.TabBar = require("graphics.elements.controls.TabBar")

-- DropBox  →  clickable dropdown button that reveals a panel of selectable options
-- Required: text (string)
-- Optional: options (list of {text, callback?}), callback (fn(text, idx)),
--           min_width, alignment, active_fg_bg, drop_fg_bg, drop_height
-- set_options(opts)      →  replace all options
-- add_option(text, cb?)  →  append a single option
-- clear_options()        →  remove all options
-- open() / close()       →  programmatic dropdown control
-- is_open()              →  query dropdown state
-- Height: always 1 (dropdown overlays below)
ui.DropBox = require("graphics.elements.controls.DropBox")

-- NumericSpinbox  →  digit-by-digit numeric entry with ▲▼ arrow columns
-- Required: whole_num_precision (int), fractional_precision (int), arrow_fg_bg (cpair)
-- Optional: default (number), min, max, arrow_disable (color)
-- set_value(num)    →  set displayed value
-- set_min(n)        →  update minimum constraint
-- set_max(n)        →  update maximum constraint
-- get_value()       →  current number (via base element get_value())
-- Width:  whole_num_precision + fractional_precision + (1 if frac>0 else 0)
-- Height: always 3 (up-arrows row, value row, down-arrows row)
-- Note: no callback — read value on demand with get_value()
ui.NumericSpinbox = require("graphics.elements.controls.NumericSpinbox")

-- Sidebar  →  scrollable vertical icon-based navigation sidebar
ui.Sidebar = require("graphics.elements.controls.Sidebar")

-- App  →  application icon (for app launcher UIs)
ui.App = require("graphics.elements.controls.App")

-- ─── Form / input elements ────────────────────────────────────────────────────

-- TextField  →  focusable text entry field
-- Optional: value (initial string), max_len (int), censor (single char for masking),
--           dis_fg_bg (cpair when disabled)
-- set_value(str)    →  set text content
-- get_value()       →  current string
-- censor(char)      →  set/change masking character (e.g. "*" for passwords)
-- handle_paste(str) →  insert pasted text at cursor
-- Focusable: yes (click to focus, type to enter)
ui.TextField = require("graphics.elements.form.TextField")

-- NumberField  →  focusable numeric-only entry field
-- Optional: default, min, max, max_chars, max_int_digits, max_frac_digits,
--           allow_decimal (bool), allow_negative (bool), align_right (bool), dis_fg_bg
-- set_value(val)    →  set numeric value
-- get_value()       →  current string representation
-- get_numeric()     →  tonumber(value) or 0 if invalid
-- set_min(n)        →  update lower bound
-- set_max(n)        →  update upper bound
-- Focusable: yes
ui.NumberField = require("graphics.elements.form.NumberField")

-- ─── Indicator elements ───────────────────────────────────────────────────────

-- LED  →  square dot (\x8c) indicator; boolean on/off with optional flashing
-- Required: label (string, may be ""), colors (cpair: on_color / off_color)
-- Optional: min_label_width (int), flash (bool), period (PERIOD constant)
-- set_value(bool)  →  true starts flash (if flash=true) or lights up; false turns off
-- Width: max(min_label_width or 0, len(label)) + 2
-- Note: when flash=true, set_value(true) calls flasher.start(); set_value(false) calls flasher.stop()
ui.LED = require("graphics.elements.indicators.LED")

-- IndicatorLight  →  circle dot (\x95) indicator; boolean on/off with optional flashing
-- Required: label, colors (cpair: on/off)
-- Optional: min_label_width, flash (bool), period (PERIOD constant)
-- set_value(bool)  →  true enables (or starts flash); false disables
-- Width: max(min_label_width or 1, len(label)) + 2
ui.IndicatorLight = require("graphics.elements.indicators.IndicatorLight")

-- AlarmLight  →  tri-state indicator (off / alarm / ring-back) with optional flash
-- Required: label, c1 (off color), c2 (alarm color), c3 (ring-back color)
-- Optional: min_label_width, flash (bool, applies to alarm state), period
-- set_value(1|2|3)  →  1=off, 2=alarm (may flash), 3=ring-back
-- Width: max(min_label_width or 1, len(label)) + 2
ui.AlarmLight = require("graphics.elements.indicators.AlarmLight")

-- LEDPair  →  three-state LED dot (\x8c); values: 1=off, 2=c1, 3=c2
-- Required: label, off (color), c1 (color), c2 (color)
-- Optional: min_label_width, flash (bool), period
-- set_value(1|2|3)  →  set state
-- Width: max(min_label_width or 0, len(label)) + 2
ui.LEDPair = require("graphics.elements.indicators.LEDPair")

-- TriIndicatorLight  →  three-state circle dot indicator
ui.TriIndicatorLight = require("graphics.elements.indicators.TriIndicatorLight")

-- HorizontalBar  →  horizontal fill bar indicator; value is 0.0–1.0 fraction
-- Optional: show_percent (bool), bar_fg_bg (cpair override for bar fill color)
-- set_value(fraction)  →  0.0 = empty, 1.0 = full (clamped)
-- recolor(cpair)       →  change bar fill color at runtime
-- Height can be 1 or more rows; percent label appears at vertical center
ui.HorizontalBar = require("graphics.elements.indicators.HorizontalBar")

-- VerticalBar  →  vertical fill bar indicator; value is 0.0–1.0 fraction
-- set_value(fraction)  →  0.0 = empty, 1.0 = full (fills bottom-to-top)
-- recolor(cpair)       →  change bar color
-- Requires height > 1 to be meaningful
ui.VerticalBar = require("graphics.elements.indicators.VerticalBar")

-- DataIndicator  →  label + string.format value + optional unit, all on one row
-- Required: label (string), format (Lua format string), value (initial), width (total chars)
-- Optional: unit (string appended after value), commas (bool),
--           lu_colors (cpair: .color_a = label fg, .color_b = unit fg)
-- set_value(val)  →  update the displayed value through the format string
-- recolor(color)  →  change value text foreground color
-- Height: always 1
ui.DataIndicator = require("graphics.elements.indicators.DataIndicator")

-- IconIndicator  →  displays a colored icon symbol per state with a label
-- Required: label (string), states (list of {color=cpair, symbol=string})
-- Optional: value (initial index or bool; true→2, false→1), min_label_width
-- set_value(int|bool)  →  set current state (true→2, false→1)
-- Width: max(min_label_width or 1, len(label)) + 4 (3 chars for icon cell + 1 space)
-- Height: always 1; the icon occupies 3 chars (space + symbol + space)
ui.IconIndicator = require("graphics.elements.indicators.IconIndicator")

-- StateIndicator  →  displays a state name/color from a predefined list
ui.StateIndicator = require("graphics.elements.indicators.StateIndicator")

-- SignalBar  →  signal strength bar indicator (like Wi-Fi bars)
ui.SignalBar = require("graphics.elements.indicators.SignalBar")

-- PowerIndicator  →  power level display (specialized DataIndicator variant)
ui.PowerIndicator = require("graphics.elements.indicators.PowerIndicator")

-- RadIndicator  →  radiation level display (specialized DataIndicator variant)
ui.RadIndicator = require("graphics.elements.indicators.RadIndicator")

-- RGBLED  →  RGB LED indicator (color composed from RGB channels)
ui.RGBLED = require("graphics.elements.indicators.RGBLED")

-- CoreMap  →  visual representation of a reactor core cell map
ui.CoreMap = require("graphics.elements.indicators.CoreMap")

-- ─── Animation elements ───────────────────────────────────────────────────────

-- Waiting  →  animated "waiting/loading" spinner
ui.Waiting = require("graphics.elements.animations.Waiting")

return ui
