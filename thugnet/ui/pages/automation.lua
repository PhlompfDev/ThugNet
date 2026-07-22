-- Automation page: list rules with enable toggle + summaries, add-rule wizard,
-- and per-row edit menus. Engine lives in core/automation (fires only on the
-- config.automation node). Spec §7 Automation.
local ui = require("graphics.ui")
local widgets = require("thugnet.ui.widgets")
local menus = require("thugnet.ui.menus")
local automation = require("thugnet.core.automation")

local function trigger_summary(t)
    if not t then return "(no trigger)" end
    if t.at then return "@" .. t.at end
    if t.sensor then
        local op = t.gte and (">=" .. t.gte) or t.lte and ("<=" .. t.lte)
            or t.equals ~= nil and ("==" .. tostring(t.equals)) or "?"
        return t.sensor .. op .. (t.sustained_secs and (" for " .. t.sustained_secs .. "s") or "")
    end
    return "(no trigger)"
end

local function action_summary(a)
    if not a then return "(no action)" end
    if a.scene then return "scene " .. a.scene end
    if a.domain and a.command then return a.domain .. ":" .. a.command end
    if a.alert then return "alert '" .. a.alert .. "'" end
    return "(no action)"
end

return {
    id = "automation",
    name = "Automation",
    category = "control",
    min_w = 30,
    min_h = 10,
    build = function(content, ui_ctx)
        local theme = ui_ctx.theme
        local w, h = content.window().getSize()
        local y = widgets.section(content, 2, 1, w - 2, "AUTOMATION", theme)

        ui.PushButton{
            parent = content, x = 2, y = y, width = 14, text = "+ New Rule",
            fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
            active_fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
            callback = function()
                ui_ctx.prompt("New rule name", "", function(name)
                    if name ~= "" then
                        automation.add(name)
                        if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
                    end
                end)
            end,
        }

        local list_y = y + 2
        local list = ui.ListBox{
            parent = content, x = 2, y = list_y, width = w - 2, height = h - list_y,
            scroll_height = 120,
            fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg),
            nav_fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg),
            nav_active = ui.cpair(theme.tokens.accent, theme.tokens.bg),
        }

        local function rebuild() if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end end

        for _, rule in ipairs(automation.list()) do
            local name = rule.name
            local row = ui.Div{ parent = list, height = 2,
                                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
            ui.TextBox{ parent = row, x = 1, y = 1, width = w - 3, height = 1,
                text = "\x07 " .. name .. (rule.enabled and "" or "  (off)"),
                fg_bg = ui.cpair(rule.enabled and theme.tokens.ok_bright or theme.tokens.dim,
                                 theme.tokens.bg) }
            ui.TextBox{ parent = row, x = 3, y = 2, width = w - 4, height = 1,
                text = trigger_summary(rule.trigger) .. " \x1a " .. action_summary(rule.action),
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }

            row.set_right_click_handler(function()
                ui_ctx.menu(menus.automation_rule_menu({
                    toggle = function()
                        automation.set_enabled(name, not rule.enabled); rebuild()
                    end,
                    edit_trigger = function()
                        ui_ctx.menu({
                            { text = "Time (at)", callback = function()
                                ui_ctx.prompt("Time (dawn/noon/dusk/midnight/HH:MM)", "dawn", function(at)
                                    if at ~= "" then automation.set_trigger(name, { at = at }); rebuild() end
                                end)
                            end },
                            { text = "Condition (sensor)", callback = function()
                                ui_ctx.prompt("Sensor path (domain:name)", "", function(path)
                                    if path == "" then return end
                                    ui_ctx.prompt("Fire when value >= (blank for <=)", "", function(gte)
                                        local t = { sensor = path }
                                        local n = tonumber(gte)
                                        if n then t.gte = n else
                                            ui_ctx.prompt("value <=", "", function(lte)
                                                local m = tonumber(lte); if m then t.lte = m end
                                                automation.set_trigger(name, t); rebuild()
                                            end)
                                            return
                                        end
                                        automation.set_trigger(name, t); rebuild()
                                    end)
                                end)
                            end },
                        })
                    end,
                    edit_action = function()
                        ui_ctx.menu({
                            { text = "Run scene", callback = function()
                                ui_ctx.prompt("Scene name", "", function(s)
                                    if s ~= "" then automation.set_action(name, { scene = s }); rebuild() end
                                end)
                            end },
                            { text = "Send command", callback = function()
                                ui_ctx.prompt("Domain", "", function(d)
                                    if d == "" then return end
                                    ui_ctx.prompt("Command", "", function(c)
                                        if c ~= "" then automation.set_action(name, { domain = d, command = c }); rebuild() end
                                    end)
                                end)
                            end },
                            { text = "Raise alert", callback = function()
                                ui_ctx.prompt("Alert text", "", function(t)
                                    if t ~= "" then automation.set_action(name, { alert = t }); rebuild() end
                                end)
                            end },
                        })
                    end,
                    rename = function()
                        ui_ctx.prompt("Rename " .. name, name, function(nn)
                            if nn ~= "" and automation.rename(name, nn) then rebuild() end
                        end)
                    end,
                    delete = function() automation.delete(name); rebuild() end,
                }, { enabled = rule.enabled }))
                return true
            end)
        end

        if #automation.list() == 0 then
            ui.TextBox{ parent = list, height = 1, text = "(no rules - + New Rule)",
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
        end
    end,
}
