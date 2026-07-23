-- Scenes page: list of scenes with per-row Run/Abort + live progress, and a
-- step editor for the selected scene. Spec §7 Scenes.
-- (PushButton has no label setter and its set_value simulates a press, so the
--  per-row button keeps a static label and toggles run/abort by live state.)
local ui = require("graphics.ui")
local widgets = require("thugnet.ui.widgets")
local menus = require("thugnet.ui.menus")
local scenes = require("thugnet.core.scenes")

return {
    id = "scenes",
    name = "Scenes",
    category = "control",
    min_w = 30,
    min_h = 10,
    build = function(content, ui_ctx)
        local theme = ui_ctx.theme
        local w, h = content.window().getSize()

        local y = widgets.section(content, 2, 1, w - 2, "SCENES", theme)
        y = y + 1 -- blank row so + New Scene doesn't touch the accent bar above

        ui.PushButton{
            parent = content, x = 2, y = y, width = 14, text = "+ New Scene",
            fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
            active_fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
            callback = function()
                ui_ctx.prompt("New scene name", "", function(name)
                    if name ~= "" then
                        scenes.add(name)
                        if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
                    end
                end)
            end,
        }

        local sel = ui_ctx.selected_scene and scenes.get(ui_ctx.selected_scene)

        local list_y = y + 2
        local list_h = sel and math.max(3, math.floor((h - list_y) / 2)) or (h - list_y)
        local listbox = ui.ListBox{
            parent = content, x = 2, y = list_y, width = w - 2, height = list_h,
            scroll_height = 60,
            fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg),
            nav_fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg),
            nav_active = ui.cpair(theme.tokens.accent, theme.tokens.bg),
        }

        local prog_tb = {}   -- name -> progress TextBox

        local function running_id(name)
            for _, r in ipairs(scenes.running()) do
                if r.scene == name then return r.run_id end
            end
        end

        local function build_row(scene)
            local name = scene.name
            local row = ui.Div{ parent = listbox, height = 2,
                                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
            ui.TextBox{ parent = row, x = 1, y = 1, width = w - 12, height = 1, text = name,
                        fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }

            ui.PushButton{
                parent = row, x = w - 9, y = 1, width = 8, text = "Run",
                fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.ok),
                active_fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                callback = function()
                    local rid = running_id(name)
                    if rid then scenes.abort(rid) else scenes.run(name) end
                end,
            }
            prog_tb[name] = ui.TextBox{ parent = row, x = 1, y = 2, width = w - 3, height = 1,
                text = "", fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }

            row.set_right_click_handler(function()
                ui_ctx.menu(menus.scene_menu{
                    run = function() scenes.run(name) end,
                    rename = function()
                        ui_ctx.prompt("Rename " .. name, name, function(nn)
                            if nn ~= "" and scenes.rename(name, nn) and ui_ctx.request_rebuild then
                                ui_ctx.request_rebuild()
                            end
                        end)
                    end,
                    edit_steps = function()
                        if ui_ctx.bus then ui_ctx.bus.set("scenes_selected", name, { persist = false }) end
                        ui_ctx.selected_scene = name
                        if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
                    end,
                    duplicate = function()
                        scenes.duplicate(name)
                        if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
                    end,
                    delete = function()
                        scenes.delete(name)
                        if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
                    end,
                })
                return true
            end)
            return row
        end

        for _, scene in ipairs(scenes.list()) do build_row(scene) end

        -- seed progress lines for any already-running scene (survives rebuilds)
        for _, r in ipairs(scenes.running()) do
            local tb = prog_tb[r.scene]
            if tb then
                tb.set_value(("step %d/%d %s (Run = abort)"):format(
                    r.step or 0, r.total or 0, r.status or "running"))
                tb.recolor(theme.tokens.text)
            end
        end

        -- live progress: update the matching scene's line
        ui_ctx.own(scenes.on_progress(function(p)
            local tb = prog_tb[p.scene]
            if not tb then return end
            if p.status == "done" or p.status == "aborted" or p.status == "failed" then
                tb.set_value("last run: " .. p.status)
                tb.recolor(p.status == "done" and theme.tokens.ok_bright or theme.tokens.alert)
            else
                tb.set_value(("step %d/%d %s %s (Run = abort)"):format(
                    p.step or 0, p.total or 0, p.step_name or "", p.status or ""))
                tb.recolor(theme.tokens.text)
            end
        end))

        -- ── step editor for the selected scene ───────────────────────────
        if sel then
            local ey = list_y + list_h
            widgets.section(content, 2, ey, w - 2, "EDIT: " .. sel.name, theme)

            ui.PushButton{
                parent = content, x = 2, y = ey + 1, width = 12, text = "+ Add Step",
                fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                active_fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                callback = function()
                    ui_ctx.menu({
                        { text = "Wait (ticks)", callback = function()
                            ui_ctx.prompt("Wait ticks", "20", function(v)
                                local ticks = tonumber(v)
                                if ticks then
                                    local st = sel.steps
                                    st[#st + 1] = { type = "wait", ticks = ticks }
                                    scenes.set_steps(sel.name, st)
                                    if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
                                end
                            end)
                        end },
                        { text = "Net command", callback = function()
                            ui_ctx.prompt("Domain", "", function(domain)
                                if domain == "" then return end
                                ui_ctx.prompt("Command", "", function(cmd)
                                    if cmd == "" then return end
                                    local st = sel.steps
                                    st[#st + 1] = { type = "net", domain = domain,
                                                    command = cmd, wait = "ok" }
                                    scenes.set_steps(sel.name, st)
                                    if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
                                end)
                            end)
                        end },
                    })
                end,
            }

            local step_list = ui.ListBox{
                parent = content, x = 2, y = ey + 3, width = w - 2,
                height = math.max(1, h - (ey + 3)), scroll_height = 60,
                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg),
                nav_fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg),
                nav_active = ui.cpair(theme.tokens.accent, theme.tokens.bg),
            }
            for i, step in ipairs(sel.steps) do
                local label = ("%d. %s"):format(i, step.type == "net"
                    and (step.domain .. ":" .. (step.command or ""))
                    or ("wait " .. (step.ticks or "?")))
                local srow = ui.TextBox{ parent = step_list, height = 1, text = label,
                    fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
                local idx = i
                srow.set_right_click_handler(function()
                    local function reorder(delta)
                        local st = sel.steps
                        local j = idx + delta
                        if j >= 1 and j <= #st then
                            st[idx], st[j] = st[j], st[idx]
                            scenes.set_steps(sel.name, st)
                            if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
                        end
                    end
                    ui_ctx.menu(menus.scene_step_menu({
                        edit = function() end,
                        move_up = function() reorder(-1) end,
                        move_down = function() reorder(1) end,
                        duplicate = function()
                            local st = sel.steps
                            table.insert(st, idx + 1, st[idx])
                            scenes.set_steps(sel.name, st)
                            if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
                        end,
                        delete = function()
                            local st = sel.steps
                            table.remove(st, idx)
                            scenes.set_steps(sel.name, st)
                            if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
                        end,
                        edit_wait = function() end,
                        edit_timeout = function() end,
                    }, { is_net = step.type == "net" }))
                    return true
                end)
            end
        end
    end,
}
