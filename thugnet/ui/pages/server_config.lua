-- Server Config page: commands (no 6-cap), sequences, and sensors, edited
-- on a working copy and pushed to the live server on Save. All §8 context
-- menus; the single shared FaceEditor for every redstone step.
--
-- Views inside one body Div (rebuilt per navigation, FaceEditor-style):
--   commands  - scrollable command list + add
--   editor    - one command: FaceEditor on its first redstone step
--   sequence  - the command's step list + FaceEditor on the selected step
--   sensors   - sensor list + add (chained prompts w/ peripheral autocomplete)
--   quick     - sensor quick setup: every reachable block (adjacent + wired
--               modem), click one like a face cell, applicable kinds accent
local ui = require("graphics.ui")
local widgets = require("thugnet.ui.widgets")
local menus = require("thugnet.ui.menus")
local face_editor = require("thugnet.ui.face_editor")
local server = require("thugnet.net.server")
local probe = require("thugnet.core.sensor_probe")

local KINDS = { "fluid", "energy", "item_count", "item_rate", "inventory", "method" }

local function deep_copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deep_copy(x) end
    return out
end

return {
    id = "server_config",
    name = "Config",
    min_w = 34,
    min_h = 16,
    requires_role = "server",
    hidden = true,
    build = function(content, ui_ctx)
        local theme = ui_ctx.theme
        local w, h = content.window().getSize()

        -- working copies; live config untouched until Save
        local cmds = deep_copy(server.get_commands())
        local sens = deep_copy(server.get_sensors())
        local dirty = false
        local view = "commands"     -- commands | editor | sequence | sensors | quick
        local sel = nil             -- selected command index
        local seq_sel = nil         -- selected step index (sequence view)
        local qs_sel = nil          -- selected peripheral name (quick view)

        widgets.section(content, 2, 1, w - 2, "SERVER CONFIG", theme)

        -- dirty marker overlays the tail of the header rule
        local dirty_tb = ui.TextBox{ parent = content, x = w - 10, y = 1, width = 10, height = 1,
                                     text = "", fg_bg = ui.cpair(theme.tokens.warn, theme.tokens.bg) }

        -- body sits one blank row below the tab strip so the header block
        -- (title / tabs / view) reads as three distinct bands
        local body = ui.Div{ parent = content, x = 2, y = 4, width = w - 2, height = h - 4,
                             fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
        local bw, bh = w - 2, h - 4

        local rebuild

        local function mutate(fn)
            fn()
            dirty = true
            dirty_tb.set_value("* unsaved")
            rebuild()
        end

        local function goto_view(v)
            view = v
            rebuild()
        end

        ui.PushButton{
            parent = content, x = w - 16, y = 2, width = 6, text = "Save",
            fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
            active_fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
            callback = function()
                server.set_commands(deep_copy(cmds))
                server.set_sensors(deep_copy(sens))
                dirty = false
                dirty_tb.set_value("")
                rebuild()
            end,
        }
        ui.PushButton{
            parent = content, x = w - 9, y = 2, width = 9, text = "Discard",
            fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
            active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.alert),
            callback = function()
                cmds = deep_copy(server.get_commands())
                sens = deep_copy(server.get_sensors())
                dirty = false
                dirty_tb.set_value("")
                view, sel, seq_sel = "commands", nil, nil
                rebuild()
            end,
        }

        -- ── shared bits ──────────────────────────────────────────────────
        local function back_button(parent, target)
            ui.PushButton{
                parent = parent, x = 1, y = 1, width = 8, text = "\x1b Back",
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.raised),
                active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                callback = function() seq_sel = nil; goto_view(target) end,
            }
        end

        local function sensor_names()
            local out = {}
            for _, s in ipairs(sens) do table.insert(out, s.name) end
            return out
        end

        -- first redstone step of a command, created on demand so the
        -- FaceEditor always has a faces table to edit (an empty redstone
        -- step is a runtime no-op, so this alone doesn't mark dirty)
        local function first_redstone_step(cmd)
            for _, st in ipairs(cmd.steps or {}) do
                if st.type == "redstone" then return st end
            end
            cmd.steps = cmd.steps or {}
            local st = { type = "redstone", faces = {} }
            table.insert(cmd.steps, st)
            return st
        end

        -- ── command menu actions ─────────────────────────────────────────
        local function command_actions(i)
            local cmd = cmds[i]
            return {
                rename = function()
                    ui_ctx.prompt("Rename command", cmd.name, function(v)
                        if v ~= "" then mutate(function() cmd.name = v end) end
                    end)
                end,
                delete = function() mutate(function() table.remove(cmds, i) end) end,
                sequence = function() sel = i; seq_sel = nil; goto_view("sequence") end,
                data_source = function()
                    ui_ctx.prompt("Data source (sensor)", cmd.sensor or "", function(v)
                        mutate(function() cmd.sensor = v ~= "" and v or nil end)
                    end, sensor_names)
                end,
                response_key = function()
                    ui_ctx.prompt("Response key", cmd.response_key or "", function(v)
                        mutate(function() cmd.response_key = v ~= "" and v or nil end)
                    end)
                end,
                duplicate = function()
                    mutate(function()
                        local copy = deep_copy(cmd)
                        copy.name = cmd.name .. " copy"
                        table.insert(cmds, i + 1, copy)
                    end)
                end,
            }
        end

        -- ── step menu actions ────────────────────────────────────────────
        local function step_actions(cmd, i)
            local st = cmd.steps[i]
            return {
                rename = function()
                    ui_ctx.prompt("Step name", st.name or "", function(v)
                        mutate(function() st.name = v ~= "" and v or nil end)
                    end)
                end,
                set_delay = function()
                    ui_ctx.prompt("Delay ticks (0 = none)", tostring(st.delay_ticks or 0), function(v)
                        local n = tonumber(v)
                        if n then
                            mutate(function()
                                st.delay_ticks = n > 0 and math.floor(n) or nil
                            end)
                        end
                    end)
                end,
                move_up = function()
                    if i > 1 then
                        mutate(function()
                            cmd.steps[i], cmd.steps[i - 1] = cmd.steps[i - 1], cmd.steps[i]
                        end)
                    end
                end,
                move_down = function()
                    if i < #cmd.steps then
                        mutate(function()
                            cmd.steps[i], cmd.steps[i + 1] = cmd.steps[i + 1], cmd.steps[i]
                        end)
                    end
                end,
                duplicate = function()
                    mutate(function() table.insert(cmd.steps, i + 1, deep_copy(st)) end)
                end,
                delete = function()
                    mutate(function() table.remove(cmd.steps, i) end)
                end,
            }
        end

        -- ── sensor menu actions ──────────────────────────────────────────
        local function sensor_actions(i)
            local s = sens[i]
            return {
                rename = function()
                    ui_ctx.prompt("Rename sensor", s.name, function(v)
                        if v ~= "" then mutate(function() s.name = v end) end
                    end)
                end,
                edit_peripheral = function()
                    ui_ctx.prompt("Peripheral", s.peripheral or "", function(v)
                        if v ~= "" then mutate(function() s.peripheral = v end) end
                    end, function() return peripheral.getNames() end)
                end,
                edit_kind = function()
                    local items = {}
                    for _, k in ipairs(KINDS) do
                        table.insert(items, { text = k, callback = function()
                            mutate(function() s.kind = k end)
                        end })
                    end
                    ui_ctx.menu(items)
                end,
                edit_poll = function()
                    ui_ctx.prompt("Poll seconds", tostring(s.poll_secs or 2), function(v)
                        local n = tonumber(v)
                        if n and n > 0 then mutate(function() s.poll_secs = n end) end
                    end)
                end,
                edit_unit = function()
                    ui_ctx.prompt("Unit", s.unit or "", function(v)
                        mutate(function() s.unit = v ~= "" and v or nil end)
                    end)
                end,
                delete = function() mutate(function() table.remove(sens, i) end) end,
            }
        end

        -- ── add-step wizard (sequence view) ──────────────────────────────
        local function parse_wait(v)
            if v == "" or v == "none" then return "none" end
            if v == "any" or v == "ok" then return v end
            local key, val = v:match("^([^=]+)=(.*)$")
            if not key then return "none" end
            local parsed
            if val == "true" then parsed = true
            elseif val == "false" then parsed = false
            else parsed = tonumber(val) or val end
            return { key = key, equals = parsed }
        end

        local function add_step_menu(cmd)
            ui_ctx.menu({
                { text = "Redstone", callback = function()
                    mutate(function()
                        cmd.steps = cmd.steps or {}
                        table.insert(cmd.steps, { type = "redstone", faces = {} })
                    end)
                end },
                { text = "Net...", callback = function()
                    ui_ctx.prompt("Target domain", "", function(domain)
                        if domain == "" then return end
                        ui_ctx.prompt("Command", "", function(cname)
                            if cname == "" then return end
                            ui_ctx.prompt("Wait (none/any/ok/key=value)", "ok", function(wv)
                                ui_ctx.prompt("Timeout secs", "10", function(tv)
                                    mutate(function()
                                        cmd.steps = cmd.steps or {}
                                        table.insert(cmd.steps, {
                                            type = "net", domain = domain, command = cname,
                                            wait = parse_wait(wv),
                                            timeout_secs = tonumber(tv) or 10,
                                        })
                                    end)
                                end)
                            end)
                        end, function()
                            local out = {}
                            if ui_ctx.client then
                                for _, c in ipairs(ui_ctx.client.get_commands(domain)) do
                                    table.insert(out, c.name)
                                end
                            end
                            return out
                        end)
                    end, function()
                        return ui_ctx.client and ui_ctx.client.get_domains() or {}
                    end)
                end },
                { text = "Wait...", callback = function()
                    ui_ctx.prompt("Wait ticks", "20", function(v)
                        local n = tonumber(v)
                        if n and n >= 1 then
                            mutate(function()
                                cmd.steps = cmd.steps or {}
                                table.insert(cmd.steps, { type = "wait", ticks = math.floor(n) })
                            end)
                        end
                    end)
                end },
            })
        end

        -- ── views ────────────────────────────────────────────────────────
        local function step_label(st, i)
            local base
            if st.type == "redstone" then
                local n = 0
                for _ in pairs(st.faces or {}) do n = n + 1 end
                base = ("redstone (%d face%s)"):format(n, n == 1 and "" or "s")
            elseif st.type == "net" then
                base = ("net %s->%s"):format(st.domain or "?", st.command or "?")
            else
                base = st.ticks and ("wait %dt"):format(st.ticks) or "wait (cond)"
            end
            local label = ("%d. %s"):format(i, st.name or base)
            if st.delay_ticks then label = label .. (" +%dt"):format(st.delay_ticks) end
            return label
        end

        local function build_commands()
            local list = ui.ListBox{
                parent = body, x = 1, y = 1, width = bw, height = bh - 2,
                scroll_height = 100,
                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg),
                nav_fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg),
                nav_active = ui.cpair(theme.tokens.accent, theme.tokens.bg),
            }
            if #cmds == 0 then
                ui.TextBox{ parent = list, height = 1, text = "(no commands yet)",
                            fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
            end
            for i, cmd in ipairs(cmds) do
                local n = #(cmd.steps or {})
                local marks = ("%d step%s"):format(n, n == 1 and "" or "s")
                if cmd.response_key then marks = marks .. " \x04" .. cmd.response_key end
                if cmd.sensor then marks = marks .. " \x7f" .. cmd.sensor end
                local text = cmd.name .. "  " .. marks
                local idx = i
                local row = ui.PushButton{
                    parent = list, width = bw - 1, text = text:sub(1, bw - 1),
                    alignment = ui.ALIGN.LEFT,
                    fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg),
                    active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                    callback = function() sel = idx; goto_view("editor") end,
                }
                row.set_right_click_handler(function()
                    ui_ctx.menu(menus.command_menu(command_actions(idx)))
                    return true
                end)
            end
            ui.PushButton{
                parent = body, x = 1, y = bh, width = 15, text = "+ Add Command",
                fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                active_fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                callback = function()
                    ui_ctx.prompt("New command name", "", function(v)
                        if v ~= "" then
                            mutate(function() table.insert(cmds, { name = v, steps = {} }) end)
                        end
                    end)
                end,
            }
        end

        local function build_editor()
            local cmd = cmds[sel]
            if not cmd then view = "commands" return build_commands() end
            back_button(body, "commands")
            ui.TextBox{ parent = body, x = 10, y = 1, width = bw - 10, height = 1,
                        text = cmd.name,
                        fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.bg) }
            local info = ("key: %s   sensor: %s"):format(
                cmd.response_key or "-", cmd.sensor or "-")
            ui.TextBox{ parent = body, x = 1, y = 2, width = bw, height = 1,
                        text = info:sub(1, bw),
                        fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
            face_editor.build(body, 1, 4, ui_ctx,
                function() return first_redstone_step(cmd).faces end,
                function()
                    dirty = true
                    dirty_tb.set_value("* unsaved")
                end)
            ui.PushButton{
                parent = body, x = 1, y = bh, width = 12, text = "Sequence \x1a",
                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                callback = function() seq_sel = nil; goto_view("sequence") end,
            }
        end

        local function build_sequence()
            local cmd = cmds[sel]
            if not cmd then view = "commands" return build_commands() end
            back_button(body, "editor")
            ui.TextBox{ parent = body, x = 10, y = 1, width = bw - 10, height = 1,
                        text = cmd.name .. " sequence",
                        fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.bg) }
            -- breathing rows above and below "+ Add Step" keep the step list,
            -- the button, and the face editor visually separate
            local list_h = math.max(2, bh - 10)
            local list = ui.ListBox{
                parent = body, x = 1, y = 2, width = bw, height = list_h,
                scroll_height = 60,
                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg),
                nav_fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg),
                nav_active = ui.cpair(theme.tokens.accent, theme.tokens.bg),
            }
            if #(cmd.steps or {}) == 0 then
                ui.TextBox{ parent = list, height = 1, text = "(no steps)",
                            fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
            end
            for i, st in ipairs(cmd.steps or {}) do
                local idx = i
                local is_sel = seq_sel == i
                local row = ui.PushButton{
                    parent = list, width = bw - 1,
                    text = ((is_sel and "\x10 " or "  ") .. step_label(st, i)):sub(1, bw - 1),
                    alignment = ui.ALIGN.LEFT,
                    fg_bg = ui.cpair(is_sel and theme.tokens.accent or theme.tokens.text,
                                     theme.tokens.bg),
                    active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                    callback = function()
                        if cmd.steps[idx].type == "redstone" then
                            seq_sel = idx
                            rebuild()
                        end
                    end,
                }
                row.set_right_click_handler(function()
                    ui_ctx.menu(menus.step_menu(step_actions(cmd, idx)))
                    return true
                end)
            end
            ui.PushButton{
                parent = body, x = 1, y = 3 + list_h, width = 12, text = "+ Add Step",
                fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                active_fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                callback = function() add_step_menu(cmd) end,
            }
            local st = seq_sel and cmd.steps[seq_sel]
            if st and st.type == "redstone" then
                face_editor.build(body, 1, 5 + list_h, ui_ctx,
                    function() return st.faces end,
                    function()
                        dirty = true
                        dirty_tb.set_value("* unsaved")
                    end)
            else
                ui.TextBox{ parent = body, x = 1, y = 5 + list_h, width = bw, height = 1,
                            text = "(select a redstone step to edit faces)",
                            fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
            end
        end

        local function build_sensors()
            local list = ui.ListBox{
                parent = body, x = 1, y = 1, width = bw, height = bh - 2,
                scroll_height = 100,
                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg),
                nav_fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg),
                nav_active = ui.cpair(theme.tokens.accent, theme.tokens.bg),
            }
            if #sens == 0 then
                ui.TextBox{ parent = list, height = 1, text = "(no sensors yet)",
                            fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
            end
            for i, s in ipairs(sens) do
                local idx = i
                local text = ("%s  %s  %s  %ss"):format(
                    s.name, s.kind or "?", s.peripheral or "?", tostring(s.poll_secs or 2))
                local row = ui.PushButton{
                    parent = list, width = bw - 1, text = text:sub(1, bw - 1),
                    alignment = ui.ALIGN.LEFT,
                    fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg),
                    active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                    callback = function()
                        ui_ctx.menu(menus.sensor_menu(sensor_actions(idx)))
                    end,
                }
                row.set_right_click_handler(function()
                    ui_ctx.menu(menus.sensor_menu(sensor_actions(idx)))
                    return true
                end)
            end
            ui.PushButton{
                parent = body, x = 17, y = bh, width = 15, text = "\x04 Quick Setup",
                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                callback = function() qs_sel = nil; goto_view("quick") end,
            }
            ui.PushButton{
                parent = body, x = 1, y = bh, width = 14, text = "+ Add Sensor",
                fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                active_fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                callback = function()
                    ui_ctx.prompt("Sensor name", "", function(name)
                        if name == "" then return end
                        ui_ctx.prompt("Peripheral", "", function(p)
                            if p == "" then return end
                            local items = {}
                            for _, k in ipairs(KINDS) do
                                table.insert(items, { text = k, callback = function()
                                    ui_ctx.prompt("Poll seconds", "2", function(ps)
                                        ui_ctx.prompt("Unit (optional)", "", function(u)
                                            mutate(function()
                                                table.insert(sens, {
                                                    name = name, peripheral = p, kind = k,
                                                    poll_secs = tonumber(ps) or 2,
                                                    unit = u ~= "" and u or nil,
                                                })
                                            end)
                                        end)
                                    end)
                                end })
                            end
                            ui_ctx.menu(items)
                        end, function() return peripheral.getNames() end)
                    end)
                end,
            }
        end

        -- ── quick setup: reachable blocks + applicable-kind picker ───────
        local function build_quick()
            back_button(body, "sensors")
            ui.TextBox{ parent = body, x = 10, y = 1, width = bw - 10, height = 1,
                        text = "quick sensor setup",
                        fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.bg) }

            local blocks = probe.scan()
            local sel_p = nil
            for _, p in ipairs(blocks) do
                if p.name == qs_sel then sel_p = p end
            end

            -- rows: block list; below it two flowed rows of kind buttons, a
            -- blank band on each side, hint line on the last row
            local list_h = math.max(2, bh - 7)
            local list = ui.ListBox{
                parent = body, x = 1, y = 3, width = bw, height = list_h,
                scroll_height = 60,
                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg),
                nav_fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg),
                nav_active = ui.cpair(theme.tokens.accent, theme.tokens.bg),
            }

            local hint = ui.TextBox{ parent = body, x = 1, y = bh, width = bw, height = 1,
                text = "", fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }

            if #blocks == 0 then
                ui.TextBox{ parent = list, height = 1,
                    text = "(no blocks detected)",
                    fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
                hint.set_value("attach a block or connect one via wired modem")
            else
                hint.set_value(sel_p and "pick a highlighted type for " .. probe.suggest_name(sel_p.name)
                                      or "click a block, then a highlighted type")
            end

            for _, p in ipairs(blocks) do
                local entry = p
                local is_sel = p.name == qs_sel
                local row = ui.Div{ parent = list, height = 1,
                                    fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
                local rw = row.get_width()
                local function select_block() qs_sel = entry.name; rebuild() end
                -- the block cell, face-editor style: a solid square, accent
                -- when selected
                local cell = is_sel and theme.tokens.accent or theme.tokens.raised
                ui.PushButton{ parent = row, x = 1, y = 1, width = 1, text = "\143",
                    fg_bg = ui.cpair(cell, cell), active_fg_bg = ui.cpair(cell, cell),
                    callback = select_block }
                local label = entry.name .. "  (" .. probe.suggest_name(entry.ptype) .. ")"
                ui.PushButton{ parent = row, x = 3, y = 1, width = math.max(1, rw - 3),
                    text = label:sub(1, math.max(1, rw - 3)), alignment = ui.ALIGN.LEFT,
                    fg_bg = ui.cpair(is_sel and theme.tokens.text or theme.tokens.dim,
                                     theme.tokens.bg),
                    active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                    callback = select_block }
            end

            -- create a sensor for the selected block: method kind asks which
            -- method first (autocompleting from the block's own methods), then
            -- name/poll/unit with sensible prefills; one mutate at the end
            local function quick_wizard(p, kind)
                local function ask_rest(method)
                    ui_ctx.prompt("Sensor name", probe.suggest_name(p.name), function(nm)
                        if nm == "" then return end
                        ui_ctx.prompt("Poll seconds", "2", function(ps)
                            ui_ctx.prompt("Unit (optional)", probe.default_unit(kind) or "", function(u)
                                view = "sensors"
                                mutate(function()
                                    table.insert(sens, {
                                        name = nm, peripheral = p.name, kind = kind,
                                        poll_secs = tonumber(ps) or 2,
                                        unit = u ~= "" and u or nil,
                                        method = method,
                                    })
                                end)
                            end)
                        end)
                    end)
                end
                if kind == "method" then
                    ui_ctx.prompt("Method (returns a number)", "", function(m)
                        if m == "" then return end
                        ask_rest(m)
                    end, function() return p.methods end)
                else
                    ask_rest(nil)
                end
            end

            -- kind strip: applicable kinds carry the accent and act; the rest
            -- are grayed out and only explain themselves
            local ky = list_h + 4
            local px, py = 1, 0
            for _, kind in ipairs(probe.KINDS) do
                local k = kind
                local kw = #kind + 2
                if px > 1 and (px + kw - 1) > bw then py = py + 1; px = 1 end
                local usable = sel_p ~= nil and sel_p.kinds[k] == true
                ui.PushButton{
                    parent = body, x = px, y = ky + py, width = kw, text = kind,
                    fg_bg = usable and ui.cpair(theme.tokens.accent, theme.tokens.raised)
                                    or ui.cpair(theme.tokens.dim, theme.tokens.panel),
                    active_fg_bg = usable and ui.cpair(theme.tokens.bg, theme.tokens.accent)
                                          or ui.cpair(theme.tokens.dim, theme.tokens.panel),
                    callback = function()
                        if usable then
                            quick_wizard(sel_p, k)
                        elseif sel_p then
                            hint.set_value(k .. ": not supported by this block")
                        else
                            hint.set_value("click a block first")
                        end
                    end,
                }
                px = px + kw + 1
            end
        end

        -- tabs
        ui.MultiButton{
            parent = content, x = 2, y = 2, default = 1,
            options = {
                { text = "Commands", fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.panel),
                  active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent) },
                { text = "Sensors", fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.panel),
                  active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent) },
            },
            callback = function(idx)
                sel, seq_sel = nil, nil
                goto_view(idx == 2 and "sensors" or "commands")
            end,
        }

        rebuild = function()
            body.remove_all()
            if view == "commands" then build_commands()
            elseif view == "editor" then build_editor()
            elseif view == "sequence" then build_sequence()
            elseif view == "quick" then build_quick()
            else build_sensors() end
            body.redraw()
        end

        rebuild()
    end,
}
