-- Status / Diagnostics page: the cc-mek-scada front-panel language (heartbeat
-- LEDs, roster, FW/NET/SN asset tag) brought to the touchscreen, built entirely
-- from the kit atoms. Reads live service accessors only -- no protocol/bus
-- changes. The 1s beat is the panel.lua pattern: pulsing green = up, solid red
-- = down, and a frozen node visibly stops pulsing.
local ui = require("graphics.ui")
local widgets = require("thugnet.ui.widgets")
local kit = require("thugnet.ui.kit")
local version = require("thugnet.version")

local function fmt_uptime()
    local s = math.floor(os.clock())
    return ("%dh %02dm"):format(math.floor(s / 3600), math.floor((s % 3600) / 60))
end

return {
    id = "status",
    name = "Status",
    category = "overview",
    min_w = 26,
    -- SYSTEM header + 5 rows, blank, NETWORK header + blank + LEDs, blank,
    -- DOMAINS header + >=1 roster row, and the asset line on the last row:
    -- bottoms out around row 13, so refuse below 15 (leaves a roster row)
    min_h = 15,
    requires_role = "ui",
    build = function(content, ui_ctx)
        local theme = ui_ctx.theme
        local w, h = content.window().getSize()
        local roles = ui_ctx.config.roles or {}

        -- ── SYSTEM ────────────────────────────────────────────────────────
        local y = widgets.section(content, 2, 1, w - 2, "SYSTEM", theme)
        kit.readout(content, 2, y, w - 3, "Label", theme).set(ui_ctx.config.label or "?")
        kit.readout(content, 2, y + 1, w - 3, "Computer", theme).set(os.getComputerID())
        kit.readout(content, 2, y + 2, w - 3, "Version", theme).set("v" .. version)
        local up_ro = kit.readout(content, 2, y + 3, w - 3, "Uptime", theme)
        local role_names = {}
        for k, on in pairs(roles) do if on then role_names[#role_names + 1] = k end end
        table.sort(role_names)
        kit.readout(content, 2, y + 4, w - 3, "Roles", theme)
            .set(#role_names > 0 and table.concat(role_names, ", ") or "none")

        -- ── NETWORK (heartbeats) ──────────────────────────────────────────
        -- one blank row below the readouts, then the header, then the LEDs one
        -- row under it -- so the DNS/Server dots aren't sandwiched against the
        -- section rules above and below (no signal bar here: the LEDs already
        -- carry link state, and the bar read as messy "stairs" on a page)
        local ny = widgets.section(content, 2, y + 6, w - 2, "NETWORK", theme)
        local dns_led = kit.led_row(content, 2, ny + 1, "DNS", theme)
        local srv_led = kit.led_row(content, 14, ny + 1, "Server", theme)

        local function dns_state()
            if ui_ctx.dns and roles.dns then return ui_ctx.dns.is_active() and "up" or "down"
            elseif ui_ctx.client then return ui_ctx.client.dns_ok() and "up" or "down" end
            return "off"
        end
        local function srv_state()
            if ui_ctx.server and roles.server then return ui_ctx.server.is_active() and "up" or "down" end
            return "off"
        end
        -- pulse a kit.led_row: green/dark while up, solid red down, steady gray inert
        local function beat_led(led, state, phase)
            if state == "up" then led.recolor("ok_bright"); led.set(phase)
            elseif state == "down" then led.recolor("alert"); led.set(true)
            else led.recolor("raised"); led.set(true) end
        end

        -- ── DOMAINS (roster) ──────────────────────────────────────────────
        -- a blank row below the NETWORK LEDs, then the header
        local dy = widgets.section(content, 2, ny + 3, w - 2, "DOMAINS", theme)
        local roster = {}
        local function alive(d)
            if ui_ctx.dns and roles.dns then return ui_ctx.dns.is_alive(d) == true
            elseif ui_ctx.client then return ui_ctx.client.is_alive(d) == true end
            return false
        end
        if ui_ctx.dns and roles.dns then
            for d in pairs(ui_ctx.dns.get_domains() or {}) do roster[#roster + 1] = d end
        elseif ui_ctx.client then
            for _, d in ipairs(ui_ctx.client.get_domains() or {}) do roster[#roster + 1] = d end
        end
        table.sort(roster)

        local roster_leds = {}
        local first = dy + 1
        local last = h - 2            -- leave the asset line on the last row
        local room = math.max(0, last - first + 1)
        if #roster == 0 then
            ui.TextBox{ parent = content, x = 2, y = first, width = w - 3, height = 1,
                text = "No domains on the network yet.",
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
        else
            local shown, overflow
            if #roster <= room then shown, overflow = #roster, false
            else shown, overflow = math.max(0, room - 1), true end
            for i = 1, shown do
                roster_leds[roster[i]] = kit.led_row(content, 2, first + i - 1, roster[i], theme)
            end
            if overflow then
                ui.TextBox{ parent = content, x = 2, y = first + shown, width = w - 3, height = 1,
                    text = ("...+%d more"):format(#roster - shown),
                    fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
            end
        end

        -- ── asset tag ─────────────────────────────────────────────────────
        ui.TextBox{ parent = content, x = 2, y = h, width = w - 2, height = 1,
            text = ("FW v%s  NET thugnet2  SN %04d"):format(version, os.getComputerID()),
            fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }

        -- ── live beat ─────────────────────────────────────────────────────
        local phase = false
        local function beat()
            phase = not phase
            beat_led(dns_led, dns_state(), phase)
            beat_led(srv_led, srv_state(), phase)
            up_ro.set(fmt_uptime())
            for d, led in pairs(roster_leds) do
                beat_led(led, alive(d) and "up" or "down", phase)
            end
        end
        beat()
        ui_ctx.own(ui_ctx.kernel.every(1, beat))

        -- structural roster changes -> rebuild so new/removed domains appear
        if ui_ctx.client then
            ui_ctx.own(ui_ctx.client.on_change(function(kind, domain)
                if kind == "snapshot" or kind == "removed" then
                    ui_ctx.request_rebuild()
                elseif (kind == "up" or kind == "down") and domain and not roster_leds[domain] then
                    ui_ctx.request_rebuild()
                end
            end))
        end
    end,
}
