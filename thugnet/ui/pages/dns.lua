-- DNS page: service status, registered domains (shared §8 domain menu),
-- and network diagnostics — per-node last-seen age, message counters, and
-- on-demand ping RTT. A chunk-unloaded node is obvious at a glance.
local ui = require("graphics.ui")
local widgets = require("thugnet.ui.widgets")
local menus = require("thugnet.ui.menus")
local dns = require("thugnet.net.dns")
local protocol = require("thugnet.net.protocol")
local cmenu = require("graphics.context_menu")
local tprompt = require("graphics.text_prompt")

return {
    id = "dns",
    name = "DNS",
    category = "network",
    min_w = 26,
    min_h = 10,
    requires_role = "dns",
    build = function(content, ui_ctx)
        local theme = ui_ctx.theme
        local w, h = content.window().getSize()

        local svc = widgets.chip(content, 2, 1, "Service", theme)
        svc.set(dns.is_active() and "ok" or "off")

        local y = widgets.section(content, 2, 3, w - 2, "REGISTERED", theme)
        local reg_h = math.max(3, math.floor((h - 7) / 2))
        local reg = ui.ListBox{
            parent = content, x = 2, y = y, width = w - 2, height = reg_h,
            scroll_height = 100,
            fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg),
            nav_fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg),
            nav_active = ui.cpair(theme.tokens.accent, theme.tokens.bg),
        }

        local y2 = widgets.section(content, 2, y + reg_h + 1, w - 2, "DIAGNOSTICS", theme)
        local diag_list = ui.ListBox{
            parent = content, x = 2, y = y2, width = w - 2, height = h - y2,
            scroll_height = 100,
            fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg),
            nav_fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg),
            nav_active = ui.cpair(theme.tokens.accent, theme.tokens.bg),
        }

        local rtts = {}   -- src id -> ms (latest measured)

        local function refill_registered()
            reg.remove_all()
            local names = {}
            for name in pairs(dns.get_domains()) do table.insert(names, name) end
            table.sort(names)
            if #names == 0 then
                ui.TextBox{ parent = reg, height = 1, text = "(none registered)",
                            fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
            end
            for _, name in ipairs(names) do
                local rec = dns.get_domains()[name]
                local alive = dns.is_alive(name)
                local row = ui.Div{ parent = reg, height = 1,
                                    fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
                local rw = row.get_width()
                ui.TextBox{ parent = row, x = 1, y = 1, width = 1, height = 1, text = "\x07",
                            fg_bg = ui.cpair(alive and theme.tokens.ok_bright or theme.tokens.alert,
                                             theme.tokens.bg) }
                ui.TextBox{ parent = row, x = 3, y = 1, width = math.min(#name, rw - 9),
                            height = 1, text = name,
                            fg_bg = ui.cpair(alive and theme.tokens.text or theme.tokens.dim,
                                             theme.tokens.bg) }
                local tail = "#" .. tostring(rec.id)
                ui.TextBox{ parent = row, x = rw - #tail, y = 1, width = #tail, height = 1,
                            text = tail, fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
                if ui_ctx.client then
                    row.set_right_click_handler(function()
                        ui_ctx.menu(menus.domain_menu(ui_ctx, name))
                        return true
                    end)
                end
            end
            reg.redraw()
        end

        local function ping(id)
            if not ui_ctx.transport then return end
            local t0 = os.clock()
            ui_ctx.transport.request(id, protocol.new("ping", { t_sent = t0 }), 3,
                function(ok)
                    if ok then
                        rtts[id] = math.floor((os.clock() - t0) * 1000)
                    else
                        rtts[id] = -1   -- timed out
                    end
                end)
        end

        local function refill_diag()
            diag_list.remove_all()
            local ids = {}
            for id in pairs(dns.get_diag()) do table.insert(ids, id) end
            table.sort(ids)
            if #ids == 0 then
                ui.TextBox{ parent = diag_list, height = 1, text = "(no traffic yet)",
                            fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
            end
            local now = os.clock()
            for _, id in ipairs(ids) do
                local d = dns.get_diag()[id]
                local age = d.last_seen and math.max(0, math.floor(now - d.last_seen)) or 0
                local rtt = "-"
                if rtts[id] == -1 then rtt = "t/o"
                elseif rtts[id] then rtt = rtts[id] .. "ms" end
                local text = ("#%d  %ds ago  %d msgs  rtt %s"):format(id, age, d.msgs or 0, rtt)
                local row = ui.TextBox{ parent = diag_list, height = 1, text = text,
                                        fg_bg = ui.cpair(age > 5 and theme.tokens.warn
                                                         or theme.tokens.text, theme.tokens.bg) }
                local pid = id
                row.set_right_click_handler(function()
                    ui_ctx.menu({ { text = "Ping #" .. pid, callback = function() ping(pid) end } })
                    return true
                end)
            end
            diag_list.redraw()
        end

        refill_registered()
        refill_diag()

        -- ages/counters tick once a second; registry refresh piggybacks.
        -- Skipped while an overlay is open so the repaint can't paint under it.
        ui_ctx.own(ui_ctx.kernel.every(1, function()
            if cmenu.is_active() or tprompt.is_active() then return end
            svc.set(dns.is_active() and "ok" or "off")
            refill_registered()
            refill_diag()
        end))
    end,
}
