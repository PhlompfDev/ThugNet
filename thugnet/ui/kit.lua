-- ThugNet UI kit v2 -- the design-system ATOMS.
--
-- Thin, themed wrappers over the vendored graphics/ elements so pages speak one
-- visual language (the cc-mek-scada industrial look) instead of hand-rolling
-- boxes and dots. No page or business logic lives here; every color comes from
-- theme tokens, never a raw CC number. widgets.lua composes these into the
-- page-level molecules (domain_tile, ...).
local ui = require("graphics.ui")

local kit = {}

-- ── icon vocabulary ───────────────────────────────────────────────────────
-- Named glyphs so a page writes kit.icons.sensor, never a raw \x07. Values are
-- CC control-picture characters chosen to render on the standard font; the
-- meaning is in the name, so a later font/glyph retune happens in one place.
kit.icons = {
    domain  = "\x07",   -- filled dot
    server  = "\x07",
    dns     = "\x07",
    sensor  = "\x9f",   -- signal-ish block
    scene   = "\x10",   -- play triangle
    rule    = "\x95",   -- tick / rule mark
    ok      = "\x07",
    warn    = "\x13",   -- caution
    alert   = "!",
}

-- ── card: filled panel primitive ──────────────────────────────────────────
-- The one card implementation (domain_tile builds on this). Returns the inner
-- content Div; children place inside it at 1,1 like any container.
---@param opts? table { bg = token (default "panel") }
---@return table content_div
function kit.card(parent, x, y, w, h, theme, opts)
    opts = opts or {}
    local bg = opts.bg or "panel"
    local card = ui.Div{ parent = parent, x = x, y = y, width = w, height = h,
                         fg_bg = ui.cpair(theme.tokens.text, theme.tokens[bg]) }
    ui.Tiling{ parent = card, x = 1, y = 1, width = w, height = h,
               fill_c = ui.cpair(theme.tokens[bg], theme.tokens[bg]) }
    return card
end

-- ── badge: colored text status tag ────────────────────────────────────────
-- states = { key = { color_token, text }, ... }; badge.set(key) switches the
-- shown state. Wraps StateIndicator (pads every state to a common width).
---@param opts? table { bg = token (default "raised") }
---@return table { set(key), width }
function kit.badge(parent, x, y, states, theme, opts)
    opts = opts or {}
    local bg = opts.bg or "raised"
    local sdef, idx, width = {}, {}, 1
    for key, def in pairs(states) do
        sdef[#sdef + 1] = { color = ui.cpair(theme.tokens[def[1]], theme.tokens[bg]), text = def[2] }
        idx[key] = #sdef
        if #def[2] > width then width = #def[2] end
    end
    local si = ui.StateIndicator{ parent = parent, x = x, y = y, states = sdef,
                                  min_width = width,
                                  fg_bg = ui.cpair(theme.tokens.text, theme.tokens[bg]) }
    return {
        width = width,
        set = function(key) if idx[key] then si.set_value(idx[key]) end end,
    }
end

-- ── readout: LABEL   value UNIT row ───────────────────────────────────────
-- Wraps DataIndicator. opts.format (default "%s"), opts.unit, opts.value.
---@param opts? table { format?, unit?, value? }
---@return table { set(v), recolor(token) }
function kit.readout(parent, x, y, w, label, theme, opts)
    opts = opts or {}
    local di = ui.DataIndicator{ parent = parent, x = x, y = y, width = w,
        label = label, format = opts.format or "%s", value = opts.value or "",
        unit = opts.unit,
        lu_colors = ui.cpair(theme.tokens.dim, theme.tokens.dim),
        fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
    return {
        set = function(v) di.set_value(v) end,
        recolor = function(tok) di.recolor(theme.tokens[tok]) end,
    }
end

-- ── led_row: labeled status dot ───────────────────────────────────────────
-- The panel.lua front-panel pattern as an atom. on-color defaults to ok_bright
-- over the bg (so the off half of a blink reads dark); recolor(token) swaps the
-- on color (e.g. to alert when a subject is down).
---@param opts? table { min_w?, on? token (default "ok_bright") }
---@return table { set(on), recolor(token) }
function kit.led_row(parent, x, y, label, theme, opts)
    opts = opts or {}
    local led = ui.LED{ parent = parent, x = x, y = y, label = label,
        min_label_width = opts.min_w,
        colors = ui.cpair(theme.tokens[opts.on or "ok_bright"], theme.tokens.bg) }
    return {
        set = function(on) led.set_value(on == true) end,
        recolor = function(tok) led.recolor(ui.cpair(theme.tokens[tok], theme.tokens.bg)) end,
    }
end

-- ── signal: link-quality bars ─────────────────────────────────────────────
-- level 0 = disconnected (x), 1..3 = low..high. High uses ok_bright, low/med
-- ramp alert->warn.
---@return table { set(level), width }
function kit.signal(parent, x, y, theme)
    local sb = ui.SignalBar{ parent = parent, x = x, y = y,
        fg_bg = ui.cpair(theme.tokens.ok_bright, theme.tokens.bg),
        colors_low_med = ui.cpair(theme.tokens.alert, theme.tokens.warn),
        disconnect_color = theme.tokens.alert }
    return { width = 2, set = function(level) sb.set_value(level or 0) end }
end

-- ── empty state: icon + centered message + optional action line ────────────
-- Replaces plain "nothing here" text. Centers on the parent's own size.
function kit.empty(parent, icon, msg, theme, action)
    local w, h = parent.window().getSize()
    local line = (icon and (icon .. "  ") or "") .. msg
    local cy = math.max(1, math.floor(h / 2))
    ui.TextBox{ parent = parent, x = 1, y = cy, width = w, height = 1,
                text = line, alignment = ui.ALIGN.CENTER,
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
    if action and h > cy then
        ui.TextBox{ parent = parent, x = 1, y = cy + 1, width = w, height = 1,
                    text = action, alignment = ui.ALIGN.CENTER,
                    fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg) }
    end
end

-- ── loading: spinner + label ──────────────────────────────────────────────
-- Waiting auto-animates via the tcd the app timer already pumps. done() stops
-- and hides it. Use in place of a bare "sending..." line on live pages.
---@return table { done() }
function kit.loading(parent, x, y, msg, theme)
    local wait = ui.Waiting{ parent = parent, x = x, y = y,
                             fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.bg) }
    local label = ui.TextBox{ parent = parent, x = x + 5, y = y + 1,
        width = math.max(1, #tostring(msg)), height = 1, text = tostring(msg),
        fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
    return { done = function()
        pcall(function() wait.stop_anim() end)
        pcall(function() wait.hide() end)
        pcall(function() label.hide() end)
    end }
end

-- ── link_corner: the live connectivity corner ────────────────────────────
-- DNS LED + Server LED + a signal bar, self-beating on a 1s kernel timer from
-- the live service handles (the panel.lua heartbeat pattern brought to the
-- touchscreen header). Reused at full size by the Status page. On a narrow
-- parent (< 30 cols, i.e. a pocket) it collapses to one combined dot.
--
--   ctx = { kernel, config, dns?, client?, server?, own? }
-- Returns { width, cancel }; the 1s timer is also registered via ctx.own when
-- present so a surface teardown cancels it.
kit.LINK_CORNER_W = 14   -- wide layout width (DNS + SRV + signal); app right-aligns on it

function kit.link_corner(parent, ctx, x, y, theme)
    local roles = (ctx.config and ctx.config.roles) or {}
    local pw = select(1, parent.window().getSize())
    local narrow = pw < 30

    local label_fg = ui.cpair(theme.tokens.dim, theme.tokens.panel)
    local GREEN_HI = ui.cpair(theme.tokens.ok_bright, theme.tokens.panel)  -- pulse on-half
    local RED      = ui.cpair(theme.tokens.alert, theme.tokens.panel)      -- solid down
    local GRAY     = ui.cpair(theme.tokens.raised, theme.tokens.panel)     -- inert / n-a

    -- live states (identical logic to the dashboard/header dots)
    local function dns_state()
        if ctx.dns and roles.dns then return ctx.dns.is_active() and "up" or "down"
        elseif ctx.client then return ctx.client.dns_ok() and "up" or "down" end
        return "off"
    end
    local function srv_state()
        if ctx.server and roles.server then return ctx.server.is_active() and "up" or "down" end
        return "off"
    end
    -- one dot for the narrow form: down if anything is down, up if anything up
    local function combined(a, b)
        if a == "down" or b == "down" then return "down" end
        if a == "up" or b == "up" then return "up" end
        return "off"
    end
    -- pulse a dot: green/dark while up, solid red while down, steady gray inert
    local function beat(led, state, phase)
        if state == "up" then led.recolor(GREEN_HI); led.set_value(phase)
        elseif state == "down" then led.recolor(RED); led.set_value(true)
        else led.recolor(GRAY); led.set_value(true) end
    end

    local phase, tick, width

    if narrow then
        local dot = ui.LED{ parent = parent, x = x, y = y, label = "",
                            colors = GREEN_HI, fg_bg = label_fg }
        width = 2
        phase = false
        tick = function()
            phase = not phase
            beat(dot, combined(dns_state(), srv_state()), phase)
        end
    else
        local dns_led = ui.LED{ parent = parent, x = x, y = y, label = "DNS",
                                colors = GREEN_HI, fg_bg = label_fg }
        local srv_led = ui.LED{ parent = parent, x = x + 6, y = y, label = "SRV",
                                colors = GREEN_HI, fg_bg = label_fg }
        local sig = ui.SignalBar{ parent = parent, x = x + 12, y = y,
            fg_bg = ui.cpair(theme.tokens.ok_bright, theme.tokens.panel),
            colors_low_med = ui.cpair(theme.tokens.alert, theme.tokens.warn),
            disconnect_color = theme.tokens.alert }
        width = kit.LINK_CORNER_W
        phase = false
        tick = function()
            phase = not phase
            local ds, ss = dns_state(), srv_state()
            beat(dns_led, ds, phase)
            beat(srv_led, ss, phase)
            sig.set_value(ds == "up" and 3 or (ds == "down" and 0 or 1))
        end
    end

    tick()   -- paint immediately, don't wait a second for the first beat
    local handle = ctx.kernel.every(1, tick)
    if ctx.own then ctx.own(handle) end
    return { width = width, cancel = function()
        if handle and handle.cancel then handle.cancel() end
    end }
end

return kit
