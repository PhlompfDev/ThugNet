-- Server page: local service status and control — domain, DNS link, counts,
-- stop/start, and the door into the config editor. Whether this node IS a
-- server at all (config.roles.server) is set on Settings > Roles.
local ui = require("graphics.ui")
local widgets = require("thugnet.ui.widgets")
local server = require("thugnet.net.server")
local cmenu = require("graphics.context_menu")
local tprompt = require("graphics.text_prompt")

return {
    id = "server",
    name = "Server",
    category = "network",
    min_w = 34,
    min_h = 12,
    requires_role = "server",
    build = function(content, ui_ctx)
        local theme = ui_ctx.theme
        local w, h = content.window().getSize()

        local y = widgets.section(content, 2, 1, w - 2, "LOCAL SERVER", theme)

        local link = widgets.chip(content, 2, y, "DNS link", theme)
        local run_chip = widgets.chip(content, 2 + link.width + 2, y, "Running", theme)

        -- right-click layer for the domain row -> Rename…  (created *before*
        -- the kv_row so its background paint sits underneath the text)
        local rn = ui.Div{ parent = content, x = 2, y = y + 2, width = w - 3, height = 1 }

        local domain_row = widgets.kv_row(content, 2, y + 2, w - 3, "Domain", theme)
        local cmds_row = widgets.kv_row(content, 2, y + 3, w - 3, "Commands", theme)
        local sens_row = widgets.kv_row(content, 2, y + 4, w - 3, "Sensors", theme)
        local runs_row = widgets.kv_row(content, 2, y + 5, w - 3, "Active runs", theme)
        rn.set_right_click_handler(function()
            ui_ctx.menu({ { text = "Rename...", callback = function()
                ui_ctx.prompt("Rename domain", server.get_domain() or "", function(v)
                    if v ~= "" then server.rename(v) end
                end)
            end } })
            return true
        end)

        local function refresh()
            local act = server.is_active()
            link.set(act and (server.dns_ok() and "ok" or "alert") or "off")
            run_chip.set(act and "ok" or "off")
            domain_row.set(server.get_domain() or "?")
            cmds_row.set(#server.get_commands())
            sens_row.set(#server.get_sensors())
            local n = 0
            for _ in pairs(server.get_runs()) do n = n + 1 end
            runs_row.set(n)
        end

        ui.PushButton{
            parent = content, x = 2, y = y + 7, width = 7, text = "Start",
            fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
            active_fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
            callback = function() server.start(); refresh() end,
        }
        ui.PushButton{
            parent = content, x = 10, y = y + 7, width = 6, text = "Stop",
            fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
            active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.alert),
            callback = function() server.stop(); refresh() end,
        }

        ui.PushButton{
            parent = content, x = 18, y = y + 7, width = 16, text = "Edit Commands \x1a",
            fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
            active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
            callback = function() ui_ctx.nav_to("server_config") end,
        }

        refresh()
        ui_ctx.own(ui_ctx.kernel.every(2, function()
            if cmenu.is_active() or tprompt.is_active() then return end
            refresh()
        end))
    end,
}
