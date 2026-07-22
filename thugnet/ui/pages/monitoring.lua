-- Monitoring page: zero-config auto-grid of every sensor on the network.
-- Rows come from the union of the panel-side telemetry cache and the sensor
-- rosters the servers declared at registration, so a sensor that cannot be
-- read is shown as ERR / no data instead of silently missing. Spec §7.
local ui = require("graphics.ui")
local widgets = require("thugnet.ui.widgets")
local menus = require("thugnet.ui.menus")

local function split_path(path)
    local d, s = path:match("^([^:]+):(.+)$")
    return d or path, s or path
end

return {
    id = "monitoring",
    name = "Monitoring",
    category = "telemetry",
    min_w = 26,
    min_h = 8,
    build = function(content, ui_ctx)
        local theme = ui_ctx.theme
        local cache = ui_ctx.telemetry_cache
        local w, h = content.window().getSize()
        local filter = ui_ctx.bus and ui_ctx.bus.get("mon_filter") or nil

        local y = widgets.section(content, 2, 1, w - 2, "MONITORING", theme)

        -- Every sensor the network has DECLARED, not merely those that have
        -- published a reading. A sensor whose peripheral is missing or whose
        -- kind doesn't match publishes an error (and, before that reached the
        -- wire, nothing at all) -- listing only published paths made a broken
        -- sensor vanish from the panel with one warn event as its only trace.
        -- The declared roster comes from the server's own `register`, so this
        -- can't reintroduce the typo'd-widget-path problem cache.paths()
        -- deliberately filters out (watch() creates entries lazily).
        local function sensor_paths()
            local seen, out = {}, {}
            local function add(p)
                if type(p) == "string" and not seen[p] then
                    seen[p] = true; out[#out + 1] = p
                end
            end
            for _, p in ipairs(cache and cache.paths() or {}) do add(p) end
            if ui_ctx.client then
                for _, d in ipairs(ui_ctx.client.get_domains()) do
                    local info = ui_ctx.client.get(d) or {}
                    for _, s in ipairs(info.sensors or {}) do
                        if type(s) == "table" and type(s.name) == "string" then
                            add(d .. ":" .. s.name)
                        end
                    end
                end
            end
            table.sort(out)
            return out
        end

        local all_paths = sensor_paths()

        -- domains present (for the filter strip)
        local domains, seen = {}, {}
        for _, p in ipairs(all_paths) do
            local d = split_path(p)
            if not seen[d] then seen[d] = true; table.insert(domains, d) end
        end
        table.sort(domains)

        local opts = { { text = "all", fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.panel),
                         active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent) } }
        local filter_default = 1
        for i, d in ipairs(domains) do
            table.insert(opts, { text = d, fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.panel),
                                 active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent) })
            if d == filter then filter_default = i + 1 end
        end
        ui.MultiButton{
            parent = content, x = 2, y = y, options = opts, default = filter_default,
            callback = function(idx)
                local sel = idx > 1 and domains[idx - 1] or nil
                if ui_ctx.bus then ui_ctx.bus.set("mon_filter", sel, { persist = false }) end
                if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
            end,
        }

        local list = ui.ListBox{
            parent = content, x = 2, y = y + 1, width = w - 2, height = h - y - 2,
            scroll_height = 200,
            fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg),
            nav_fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg),
            nav_active = ui.cpair(theme.tokens.accent, theme.tokens.bg),
        }

        local n_shown = 0
        for _, path in ipairs(all_paths) do
            local domain, sensor = split_path(path)
            if filter == nil or domain == filter then
                n_shown = n_shown + 1
                local r = cache.reading(path)
                local row = ui.Div{ parent = list, height = (r and r.fraction ~= nil) and 2 or 1,
                                    fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
                -- fixed right-aligned columns: the value/unit/rate block keeps a
                -- constant width, so changing digits never make the row jitter.
                -- Total function -- readings arrive raw off the wire, and a
                -- declared sensor may have no reading at all yet.
                local function line(reading)
                    local rw = w - 3
                    local val, unit, rate
                    if type(reading) ~= "table" then
                        val, unit, rate = "no data", "", ""
                    elseif reading.error then
                        val, unit, rate = "ERR", tostring(reading.unit or ""), ""
                    else
                        val = tostring(reading.value == nil and "?" or reading.value)
                        unit = tostring(reading.unit or "")
                        rate = tonumber(reading.rate) and (("%.0f/m"):format(reading.rate)) or ""
                    end
                    local block = ("%9s %-4s %8s"):format(val:sub(1, 9), unit:sub(1, 4), rate:sub(1, 8))
                    local left = path
                    if #left + #block + 1 > rw then
                        left = left:sub(1, math.max(1, rw - #block - 1))
                    end
                    return left .. string.rep(" ", math.max(1, rw - #left - #block)) .. block
                end
                -- a silent or failing sensor is stated, never omitted
                local function row_color(reading)
                    if type(reading) ~= "table" then return theme.tokens.dim end
                    if reading.error then return theme.tokens.alert end
                    return theme.tokens.text
                end
                local tb = ui.TextBox{ parent = row, x = 1, y = 1, width = w - 3, height = 1,
                    text = line(r), fg_bg = ui.cpair(row_color(r), theme.tokens.bg) }
                local bar = nil
                if r and r.fraction ~= nil then
                    bar = ui.HorizontalBar{ parent = row, x = 1, y = 2, width = w - 3, height = 1,
                        bar_fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.raised) }
                    bar.set_value(r.fraction)
                end
                -- inventory breakdown
                for _, item in ipairs((r and r.detail) or {}) do
                    local nm = tostring(item.name or "?"):match("[^:]+$") or tostring(item.name)
                    ui.TextBox{ parent = list, height = 1,
                        text = "   \x07 " .. nm .. " x" .. tostring(item.count),
                        fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
                end
                -- live update in place. A row built before its first reading
                -- (declared but silent) still updates the moment one arrives.
                ui_ctx.own(cache.watch(path, function(reading)
                    tb.set_value(line(reading))
                    tb.recolor(row_color(reading))
                    if bar and type(reading) == "table" and tonumber(reading.fraction) then
                        bar.set_value(reading.fraction)
                    end
                end))
                -- context menu
                row.set_right_click_handler(function()
                    ui_ctx.menu(menus.sensor_tile_menu{
                        details = function()
                            local cur = cache.reading(path) or {}
                            ui_ctx.menu({
                                { text = "value: " .. tostring(cur.value), callback = function() end },
                                { text = "rate: " .. tostring(cur.rate or "-"), callback = function() end },
                                { text = "unit: " .. tostring(cur.unit or "-"), callback = function() end },
                            })
                        end,
                        add_rule = function()
                            -- Phase 5c wires this to the Automation page (pre-filled
                            -- condition trigger for `path`). Until then, surface intent.
                            ui_ctx.events.log("info", "ui",
                                "Add Rule for " .. path .. " (automation page pending)")
                        end,
                        filter_domain = function()
                            if ui_ctx.bus then ui_ctx.bus.set("mon_filter", domain, { persist = false }) end
                            if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
                        end,
                    })
                    return true
                end)
            end
        end

        if n_shown == 0 then
            -- distinguish "nothing on the network declares a sensor" from
            -- "the current domain filter hides them all"
            local msg = (#all_paths > 0) and "(no sensors for this filter)"
                or "(no sensors declared -- add them in Server > Edit Commands > Sensors)"
            ui.TextBox{ parent = list, height = 1, text = msg:sub(1, w - 3),
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
        end

        -- new sensors appear with zero config: rebuild when the roster changes.
        -- Counts the DECLARED set, so a sensor added on a server shows up here
        -- as soon as it registers, without waiting for a first reading.
        local known = #all_paths
        ui_ctx.own(ui_ctx.kernel.every(2, function()
            local n = #sensor_paths()
            if n ~= known then
                known = n
                if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
            end
        end))
    end,
}
