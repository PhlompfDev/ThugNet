-- Composite widgets shared by every page. All colors via theme tokens.
local ui = require("graphics.ui")
local flasher = require("graphics.flasher")

local widgets = {}

-- section header: accent tick + title + rule to the edge
-- returns next free y inside parent (header takes 1 row)
function widgets.section(parent, x, y, w, title, theme)
    ui.TextBox{ parent = parent, x = x, y = y, width = 1, height = 1, text = "\x95",
                fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.bg) }
    ui.TextBox{ parent = parent, x = x + 1, y = y, width = #title + 1, height = 1,
                text = " " .. title, fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
    local rule_x = x + #title + 3
    if rule_x <= x + w - 1 then
        ui.TextBox{ parent = parent, x = rule_x, y = y, width = (x + w) - rule_x, height = 1,
                    text = string.rep("\x8c", (x + w) - rule_x),
                    fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg) }
    end
    return y + 1
end

-- status chip: colored dot + label; chip.set(state) with "ok"|"warn"|"alert"|"off"
function widgets.chip(parent, x, y, label, theme)
    local STATE = { ok = theme.tokens.ok_bright, warn = theme.tokens.warn,
                    alert = theme.tokens.alert, off = theme.tokens.raised }
    local dot = ui.TextBox{ parent = parent, x = x, y = y, width = 1, height = 1, text = "\x07",
                            fg_bg = ui.cpair(STATE.off, theme.tokens.bg) }
    ui.TextBox{ parent = parent, x = x + 2, y = y, width = #label, height = 1, text = label,
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
    local chip = { width = #label + 3 }
    function chip.set(state) dot.recolor(STATE[state] or STATE.off) end
    return chip
end

-- key/value row; returns { set(value_text) }
function widgets.kv_row(parent, x, y, w, key, theme)
    local key_w = #key + 1
    ui.TextBox{ parent = parent, x = x, y = y, width = key_w, height = 1, text = key,
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
    local val = ui.TextBox{ parent = parent, x = x + key_w, y = y, width = w - key_w, height = 1,
                            text = "", fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
    return { set = function(text) val.set_value(tostring(text)) end }
end

-- domain tile: bordered card with name, liveness LED, optional primary
-- sensor bar. tile.update(info) / tile.update_sensor(reading)
-- info = { name, alive, commands, sensors, on_menu? }
-- on_menu: right-clicking anywhere on the card opens the page's menu (the
-- page owns menu content, per the §8 pattern)
---@param ui_ctx table { theme, own, telemetry_cache }
function widgets.domain_tile(parent, x, y, w, h, ui_ctx, info)
    local theme = ui_ctx.theme
    local card = ui.Div{ parent = parent, x = x, y = y, width = w, height = h,
                         fg_bg = ui.cpair(theme.tokens.text, theme.tokens.panel) }
    -- paint the card background
    ui.Tiling{ parent = card, x = 1, y = 1, width = w, height = h,
               fill_c = ui.cpair(theme.tokens.panel, theme.tokens.panel) }
    if info.on_menu then
        -- capture the callback NOW: tile.update() replaces `info` with a
        -- fresh table that carries no on_menu, so reading it through `info`
        -- at click time crashes after the first in-place update
        local on_menu = info.on_menu
        -- children have no right-click handlers of their own, so the click
        -- falls through to the card wherever it lands on the tile
        card.set_right_click_handler(function()
            on_menu()
            return true
        end)
    end

    -- heartbeat semantics (the front-panel pattern): a PULSING green LED
    -- proves the domain is alive right now, solid red proves it is down —
    -- pulsing / solid-red / frozen are three distinguishable states
    local led = ui.LED{ parent = card, x = 2, y = 2, label = "",
                        colors = ui.cpair(theme.tokens.ok_bright, theme.tokens.alert),
                        flash = true, period = flasher.PERIOD.BLINK_1000_MS,
                        fg_bg = ui.cpair(theme.tokens.text, theme.tokens.panel) }
    local name_tb = ui.TextBox{ parent = card, x = 4, y = 2, width = w - 4, height = 1,
                                text = info.name,
                                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.panel) }
    local sub_tb = ui.TextBox{ parent = card, x = 2, y = 3, width = w - 2, height = 1, text = "",
                               fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.panel) }

    local bar = nil
    local sensor_path = nil
    if h >= 4 and info.sensors and info.sensors[1] then
        sensor_path = info.name .. ":" .. info.sensors[1].name
        bar = ui.HorizontalBar{ parent = card, x = 2, y = h - 1, width = w - 2, height = 1,
                                bar_fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.raised) }
    end

    local tile = { path = sensor_path }

    function tile.update(new_info)
        info = new_info or info
        led.set_value(info.alive == true)
        local n = #(info.commands or {})
        sub_tb.set_value(info.alive and (n .. " cmd" .. (n == 1 and "" or "s")) or "offline")
        name_tb.recolor(info.alive and theme.tokens.text or theme.tokens.dim)
    end

    function tile.update_sensor(reading)
        if bar and reading and reading.fraction then
            bar.set_value(reading.fraction)
        end
    end

    tile.update(info)
    if sensor_path and ui_ctx.telemetry_cache then
        ui_ctx.own(ui_ctx.telemetry_cache.watch(sensor_path, function(reading)
            tile.update_sensor(reading)
        end))
    end

    return tile
end

-- page container: enforces min-size with an honest placeholder.
-- Returns the content Div (full parent size) or nil when too small.
function widgets.page_container(parent, ui_ctx, page_def)
    local w, h = parent.window().getSize()
    if w < (page_def.min_w or 1) or h < (page_def.min_h or 1) then
        -- the refusal must itself fit the screen it refuses: a clipped
        -- "Screen too s" reads like a render bug, not an explanation
        local msg = w >= 16 and "Screen too small" or "Too small"
        local msg2 = "(" .. page_def.name .. " needs " .. (page_def.min_w or 1)
            .. "x" .. (page_def.min_h or 1) .. ")"
        ui.TextBox{ parent = parent, x = 1, y = math.max(1, math.floor(h / 2)),
                    width = w, height = 1, text = msg, alignment = ui.ALIGN.CENTER,
                    fg_bg = ui.cpair(ui_ctx.theme.tokens.dim, ui_ctx.theme.tokens.bg) }
        if h >= 2 then
            ui.TextBox{ parent = parent, x = 1, y = math.max(1, math.floor(h / 2)) + 1,
                        width = w, height = 1, text = msg2, alignment = ui.ALIGN.CENTER,
                        fg_bg = ui.cpair(ui_ctx.theme.tokens.raised, ui_ctx.theme.tokens.bg) }
        end
        return nil
    end
    return ui.Div{ parent = parent, x = 1, y = 1, width = w, height = h,
                   fg_bg = ui.cpair(ui_ctx.theme.tokens.text, ui_ctx.theme.tokens.bg) }
end

return widgets
