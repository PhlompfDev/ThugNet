-- Domains page: every domain on the network in one scrollable list (no v1
-- 6-slot cap), the full §8 context menu per row, and a keyboard-friendly
-- quick-send flow (domain -> command, both autocompleted).
local ui = require("graphics.ui")
local widgets = require("thugnet.ui.widgets")
local menus = require("thugnet.ui.menus")

return {
    id = "domains",
    name = "Domains",
    category = "control",
    min_w = 26,
    min_h = 8,
    build = function(content, ui_ctx)
        local theme = ui_ctx.theme
        local client = ui_ctx.client
        local w, h = content.window().getSize()

        local y = widgets.section(content, 2, 1, w - 2, "DOMAINS", theme)

        local list = ui.ListBox{
            parent = content, x = 2, y = y, width = w - 2, height = h - y - 2,
            scroll_height = 100,
            fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg),
            nav_fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg),
            nav_active = ui.cpair(theme.tokens.accent, theme.tokens.bg),
        }

        local status = ui.TextBox{
            parent = content, x = 2, y = h, width = w - 16, height = 1, text = "",
            fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg),
        }

        -- context-menu sends report here too, same as quick-send
        ui_ctx.notify_send = function(cmd, domain, ok, err)
            if ok == nil then
                status.set_value(("sending %s -> %s..."):format(cmd, domain))
            elseif ok then
                status.set_value(("%s -> %s: ok"):format(cmd, domain))
            else
                status.set_value(("%s -> %s: %s"):format(cmd, domain, tostring(err)))
            end
        end

        local function add_row(name)
            local info = client.get(name) or {}
            local alive = info.alive == true
            local row = ui.Div{ parent = list, height = 1,
                                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
            local rw = row.get_width()
            ui.TextBox{ parent = row, x = 1, y = 1, width = 1, height = 1, text = "\x07",
                        fg_bg = ui.cpair(alive and theme.tokens.ok_bright or theme.tokens.alert,
                                         theme.tokens.bg) }
            ui.TextBox{ parent = row, x = 3, y = 1, width = math.min(#name, rw - 14), height = 1,
                        text = name,
                        fg_bg = ui.cpair(alive and theme.tokens.text or theme.tokens.dim,
                                         theme.tokens.bg) }
            local n = #(info.commands or {})
            local tail = ("#%s %d cmd%s"):format(tostring(info.id or "?"), n, n == 1 and "" or "s")
            ui.TextBox{ parent = row, x = rw - #tail, y = 1, width = #tail, height = 1,
                        text = tail, fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
            row.set_right_click_handler(function()
                ui_ctx.menu(menus.domain_menu(ui_ctx, name))
                return true
            end)
        end

        local function refill()
            list.remove_all()
            local names = client.get_domains()
            if #names == 0 then
                ui.TextBox{ parent = list, height = 1, text = "(no domains registered)",
                            fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
            end
            for _, name in ipairs(names) do add_row(name) end
            list.redraw()
        end

        -- quick send: Domain prompt -> Command prompt -> send, result on the
        -- status line and in the event feed
        local function quick_send()
            ui_ctx.prompt("Domain", "", function(domain)
                if domain == "" then return end
                ui_ctx.prompt("Command for " .. domain, "", function(cmd)
                    if cmd == "" then return end
                    status.set_value("sending " .. cmd .. " -> " .. domain .. "...")
                    client.send(domain, cmd, nil, function(ok, _, err)
                        status.set_value(ok and (cmd .. " -> " .. domain .. ": ok")
                                            or (cmd .. " -> " .. domain .. ": " .. tostring(err)))
                        ui_ctx.events.log(ok and "info" or "warn", "ui",
                            ("%s -> %s: %s"):format(cmd, domain, ok and "ok" or tostring(err)))
                    end)
                end, function()
                    local out = {}
                    for _, c in ipairs(client.get_commands(domain)) do table.insert(out, c.name) end
                    return out
                end)
            end, function() return client.get_domains() end)
        end

        ui.PushButton{
            parent = content, x = w - 13, y = h, width = 12, text = "\x1a Quick send",
            fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
            active_fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
            callback = quick_send,
        }

        refill()

        ui_ctx.own(client.on_change(function(kind)
            if kind == "snapshot" or kind == "up" or kind == "down"
               or kind == "removed" or kind == "commands" then
                refill()
            end
        end))
    end,
}
