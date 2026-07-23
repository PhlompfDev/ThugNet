-- Settings page: updates, node identity, roles. Pure UI -- all update logic
-- lives in core/updater.lua and is reached through updater.status().
local ui = require("graphics.ui")
local widgets = require("thugnet.ui.widgets")
local flasher = require("graphics.flasher")
local updater = require("thugnet.core.updater")

local TABS = { "Updates", "Node", "Roles" }

return {
    id = "settings",
    name = "Settings",
    category = "system",
    min_w = 26,
    -- Updates tab bottoms out at row 15 plus the hint line (request 004's
    -- padding); anything shorter clips checkboxes instead of refusing
    min_h = 16,
    requires_role = "ui",
    build = function(content, ui_ctx)
        local theme = ui_ctx.theme
        local bus = ui_ctx.bus
        local w, h = content.window().getSize()
        local view = bus.get("settings_tab") or "Updates"

        local y = widgets.section(content, 2, 1, w - 2, "SETTINGS", theme)
        y = y + 1 -- blank row: the header's accent tick must not touch the
                  -- highlighted tab below it (request 004)

        -- tab strip
        local tx = 2
        for _, name in ipairs(TABS) do
            local active = (name == view)
            ui.PushButton{
                parent = content, x = tx, y = y, width = #name + 2, text = name,
                fg_bg = active and ui.cpair(theme.tokens.bg, theme.tokens.accent)
                               or ui.cpair(theme.tokens.dim, theme.tokens.raised),
                active_fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                callback = function()
                    bus.set("settings_tab", name)
                    if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
                end,
            }
            tx = tx + #name + 3
        end
        y = y + 2

        -- shared one-line status/hint row at the bottom of the content area
        local hint = ui.TextBox{
            parent = content, x = 2, y = h, width = w - 3, height = 1, text = "",
            fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
        local function say(msg) hint.set_value(msg) end

        if view == "Updates" then
            local st = updater.status()

            widgets.kv_row(content, 2, y, w - 3, "Installed", theme)
                .set("v" .. tostring(st.installed or "?"))
            local latest_row = widgets.kv_row(content, 2, y + 1, w - 3, "Latest", theme)
            latest_row.set(st.latest and ("v" .. st.latest) or "(not checked)")

            -- The button lives in its own Div so a status change can rebuild
            -- just the button, in place, without tearing down the tab.
            local slot = ui.Div{ parent = content, x = 2, y = y + 3,
                                 width = w - 3, height = 1 }

            local pulse_fn = nil
            local function stop_pulse()
                if pulse_fn then flasher.stop(pulse_fn); pulse_fn = nil end
            end

            local render_button
            render_button = function()
                stop_pulse()
                slot.remove_all()
                local s = updater.status()

                -- Every updater state gets its own explicit branch -- no
                -- default initialiser masquerading as a real state. A fresh
                -- node that has never run a check is "idle", NOT "up_to_date":
                -- confusing the two once told a never-checked node it was
                -- current, which is actively misinformative (the first
                -- scheduled check doesn't run until 30s after boot, and a
                -- node with HTTP disabled or no network can sit in idle
                -- forever). If a future state string shows up here that isn't
                -- one of these, the else branch renders it as visibly unknown
                -- rather than silently defaulting to a confident claim.
                local label, enabled, pulsing
                if s.state == "idle" then
                    label, enabled, pulsing = "Not checked yet", false, false
                elseif s.state == "checking" then
                    label, enabled, pulsing = "Checking...", false, false
                elseif s.state == "up_to_date" then
                    label, enabled, pulsing = "Up to date", false, false
                elseif s.state == "available" then
                    label, enabled, pulsing = "\x1e Update to v" .. tostring(s.latest), true, true
                elseif s.state == "downloading" then
                    label, enabled, pulsing =
                        ("Downloading %d/%d"):format(s.done or 0, s.total or 0), false, false
                elseif s.state == "staged" then
                    label, enabled, pulsing = "Install & Reboot", true, true
                elseif s.state == "error" then
                    label, enabled, pulsing = "Retry -- " .. tostring(s.reason or "failed"), true, false
                else
                    label, enabled, pulsing = "Unknown state: " .. tostring(s.state), false, false
                end

                local rest = pulsing and ui.cpair(theme.tokens.text, theme.tokens.alert)
                    or (s.state == "error" and ui.cpair(theme.tokens.text, theme.tokens.alert)
                                            or ui.cpair(theme.tokens.dim, theme.tokens.raised))

                local btn = ui.PushButton{
                    parent = slot, x = 1, y = 1, width = w - 5,
                    text = label:sub(1, w - 7),
                    fg_bg = rest,
                    active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                    -- dim, not raised: raised-on-panel is dark-on-dark and the
                    -- disabled label ("Not checked yet", "Up to date", ...)
                    -- was unreadable on a monitor (request 003)
                    dis_fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.panel),
                    callback = function()
                        local cur = updater.status().state
                        if cur == "available" then
                            updater.download(function() render_button() end)
                            render_button()
                        elseif cur == "staged" then
                            say("installing -- the node will reboot")
                            updater.apply()
                        elseif cur == "error" then
                            updater.check(function() render_button() end)
                            render_button()
                        end
                    end,
                }
                if not enabled then btn.disable() end

                if pulsing then
                    -- element.delete() never calls flasher.stop, so this
                    -- callback is released explicitly in the own() teardown
                    -- below -- otherwise it keeps firing at a dead element.
                    local on = true
                    pulse_fn = function()
                        on = not on
                        btn.recolor(on and ui.cpair(theme.tokens.text, theme.tokens.alert)
                                        or ui.cpair(theme.tokens.text, theme.tokens.raised))
                    end
                    flasher.start(pulse_fn, flasher.PERIOD.BLINK_500_MS)
                end
                slot.redraw()
            end

            render_button()

            -- The button must repaint from state changes it did NOT itself
            -- cause -- e.g. the scheduled 30-second/30-minute poll finding
            -- an update while this page is already open, or a download's
            -- progress advancing in the background. render_button() was
            -- previously only ever re-invoked from this page's own button
            -- callbacks, so a state change from anywhere else (the poll)
            -- left the button showing "Not checked yet" and disabled --
            -- the owner had no way to click the very button the feature
            -- exists for. The updater already mirrors every state change
            -- onto the "update_state" bus key (see set_state() in
            -- updater.lua); bus.watch is the natural way to ride along.
            local update_watch = bus.watch("update_state", function() render_button() end)
            ui_ctx.own({ cancel = function()
                stop_pulse()
                if update_watch then update_watch.cancel() end
            end })

            ui.PushButton{
                parent = content, x = 2, y = y + 5, width = 13, text = "Check Now",
                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                callback = function()
                    say("checking github...")
                    updater.check(function(state)
                        latest_row.set(updater.status().latest
                            and ("v" .. updater.status().latest) or "(none)")
                        say(state == "up_to_date" and "you are on the latest version"
                            or state == "error" and ("check failed: " .. tostring(updater.status().reason))
                            or "")
                        render_button()
                    end)
                    render_button()
                end,
            }

            ui.PushButton{
                parent = content, x = 17, y = y + 5, width = 14, text = "What's New",
                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                callback = function()
                    say("fetching changelog...")
                    updater.fetch(updater.BASE .. "CHANGELOG.md", function(body, err)
                        if err or not body then return say("changelog unavailable: "
                            .. tostring(err or "empty")) end
                        bus.set("settings_changelog", body)
                        bus.set("settings_tab", "Changelog")
                        if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
                    end)
                end,
            }

            -- Live since Phase 12: opens the request composer, which files a
            -- `## Title` block into the public ThugNet-Requests inbox that
            -- the agent loop watches -- and this updater carries the result
            -- back to every node once the owner merges and publishes.
            ui.PushButton{
                parent = content, x = 2, y = y + 7, width = 17,
                text = "Feature Request",
                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                callback = function() ui_ctx.nav_to("feature_request") end,
            }

            ui.Checkbox{
                parent = content, x = 2, y = y + 9, label = "Notify me about updates",
                box_fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.raised),
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg),
                default = bus.get("update_notify") ~= false,
                callback = function(v) bus.set("update_notify", v, { persist = true }) end,
            }
            ui.Checkbox{
                parent = content, x = 2, y = y + 10,
                label = "Auto-install and reboot when idle",
                box_fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.raised),
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg),
                default = bus.get("update_auto") == true,
                callback = function(v)
                    bus.set("update_auto", v, { persist = true })
                    say(v and "will install automatically once idle"
                          or "updates will wait for you")
                end,
            }

        elseif view == "Changelog" then
            -- an empty (or whitespace-only) string is truthy in Lua, so a
            -- fetch that returns "" must be treated the same as a missing
            -- body -- otherwise the user sees a silently blank panel.
            local raw_body = bus.get("settings_changelog")
            local is_blank = raw_body == nil or tostring(raw_body):match("%S") == nil
            local body = is_blank and "(no changelog loaded)" or raw_body
            local list = ui.ListBox{ parent = content, x = 2, y = y,
                width = w - 3, height = h - y - 1, scroll_height = 200,
                fg_bg = theme.fg_bg("text", "bg"),
                nav_fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg),
                nav_active = ui.cpair(theme.tokens.accent, theme.tokens.bg) }
            local row = 1
            for line in tostring(body):gmatch("([^\n]*)\n?") do
                if row > 200 then break end
                local is_head = line:match("^##%s") ~= nil
                if line ~= "" then
                    ui.TextBox{ parent = list, x = 1, y = row, width = w - 5, height = 1,
                        text = (line:gsub("^#+%s*", "")),
                        fg_bg = is_head and ui.cpair(theme.tokens.accent, theme.tokens.bg)
                                        or ui.cpair(theme.tokens.text, theme.tokens.bg) }
                end
                row = row + 1
            end
            ui.PushButton{
                parent = content, x = 2, y = h - 1, width = 8, text = "Back",
                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                callback = function()
                    bus.set("settings_tab", "Updates")
                    if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
                end,
            }

        elseif view == "Node" then
            local cfg = ui_ctx.config
            local config_mod = require("thugnet.config")

            local label_row = widgets.kv_row(content, 2, y, w - 3, "Label", theme)
            label_row.set(tostring(cfg.label or "?"))
            widgets.kv_row(content, 2, y + 1, w - 3, "Computer", theme)
                .set(tostring(os.getComputerID()))
            widgets.kv_row(content, 2, y + 2, w - 3, "Version", theme)
                .set("v" .. require("thugnet.version"))

            local up_row = widgets.kv_row(content, 2, y + 3, w - 3, "Uptime", theme)
            local function fmt_uptime()
                local s = math.floor(os.clock())
                return ("%dh %02dm"):format(math.floor(s / 3600), math.floor((s % 3600) / 60))
            end
            up_row.set(fmt_uptime())

            local disk_row = widgets.kv_row(content, 2, y + 4, w - 3, "Free disk", theme)
            local free = (fs.getFreeSpace and select(1, pcall(fs.getFreeSpace, "/"))) and
                         fs.getFreeSpace("/") or nil
            disk_row.set(free and (math.floor(free / 1024) .. " KB") or "n/a")

            ui.PushButton{
                parent = content, x = 2, y = y + 6, width = 10, text = "Rename",
                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                callback = function()
                    ui_ctx.prompt("Node label", tostring(cfg.label or ""), function(v)
                        if v == nil or v == "" then return end
                        cfg.label = v
                        config_mod.save(cfg)
                        pcall(os.setComputerLabel, v)
                        label_row.set(v)
                        say("renamed to " .. v)
                    end)
                end,
            }

            -- config.automation decides which SINGLE node fires automation
            -- rules. It had no interface anywhere before this -- only the
            -- first-boot wizard set it, so the Automation page would list
            -- rules on a node that would never run them.
            ui.Checkbox{
                parent = content, x = 2, y = y + 8,
                label = "This node runs automation rules",
                box_fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.raised),
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg),
                default = cfg.automation == true,
                callback = function(v)
                    cfg.automation = v
                    config_mod.save(cfg)
                    say(v and "this node is the automation authority"
                          or "automation rules will not fire here")
                end,
            }

            ui.PushButton{
                parent = content, x = 2, y = y + 10, width = 10, text = "Reboot",
                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.alert),
                callback = function()
                    ui_ctx.prompt("Type 'yes' to reboot this node", "", function(v)
                        if tostring(v):lower() ~= "yes" then
                            return say("reboot cancelled")
                        end
                        -- flush first: the bus debounces its writes, so a
                        -- reboot without this loses up to half a second of
                        -- state changes
                        if bus.flush then pcall(bus.flush) end
                        os.reboot()
                    end)
                end,
            }

        elseif view == "Roles" then
            local cfg = ui_ctx.config
            local config_mod = require("thugnet.config")
            local ROLES = {
                { key = "dns",    label = "DNS  -- hosts the name registry" },
                { key = "server", label = "Server -- hosts a domain" },
                { key = "client", label = "Client -- follows the network" },
                { key = "ui",     label = "Panel  -- draws the interface" },
            }
            cfg.roles = cfg.roles or {}

            -- config.validate() rejects a config with zero roles enabled --
            -- that sends the node into the (plain-terminal) setup wizard on
            -- its next boot instead of booting normally. Ticking/unticking
            -- any role but the last is fine (that's the whole point of this
            -- tab), but letting someone untick the very last one here would
            -- silently strand them in the wizard next reboot with no warning
            -- at the point of the mistake. So: refuse the toggle instead,
            -- revert the box, and say why.
            local function other_enabled(skip_key)
                for _, r in ipairs(ROLES) do
                    if r.key ~= skip_key and cfg.roles[r.key] == true then
                        return true
                    end
                end
                return false
            end

            for i, r in ipairs(ROLES) do
                local box
                box = ui.Checkbox{
                    -- one blank row between each role box (request 004)
                    parent = content, x = 2, y = y + (i - 1) * 2, label = r.label,
                    box_fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.raised),
                    fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg),
                    default = cfg.roles[r.key] == true,
                    callback = function(v)
                        if not v and not other_enabled(r.key) then
                            box.set_value(true)
                            say("at least one role must stay enabled")
                            return
                        end
                        cfg.roles[r.key] = v or nil
                        config_mod.save(cfg)
                        say("saved -- reboot to apply role changes")
                    end,
                }
            end
            ui.TextBox{ parent = content, x = 2, y = y + #ROLES * 2, width = w - 3,
                height = 2, text = "Role changes take effect after a reboot "
                    .. "(Node tab).",
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
        end
    end,
}
