-- The context-menu map (spec §8, normative). All menu *content* lives here
-- so pages showing the same entity always offer the same options; pages own
-- the mutations and pass action callbacks in. ui_ctx.menu appends Cancel.
local menus = {}

local SEP = string.rep("\x8c", 10)

-- a visual separator row (selecting it just closes the menu)
function menus.sep()
    return { text = SEP, callback = function() end }
end

-- ── Domain row (Domains page + DNS page, one shared builder) ─────────────
-- Send Command…, View Sensors ▸, All Commands ▸, ──, Rename…, Stop Server,
-- Remove Domain
---@param ui_ctx table page context (client, events, menu, prompt, telemetry_cache)
---@param domain string domain name
function menus.domain_menu(ui_ctx, domain)
    local client = ui_ctx.client

    local function command_names()
        local out = {}
        for _, c in ipairs(client.get_commands(domain)) do table.insert(out, c.name) end
        return out
    end

    -- pages that show a status line set ui_ctx.notify_send(cmd, domain, ok, err)
    -- to get immediate "sending… / ok / failed" feedback where the user acted
    -- (ok == nil means "in flight"); the event feed always gets the result
    local function send(name)
        if ui_ctx.notify_send then ui_ctx.notify_send(name, domain, nil) end
        client.send(domain, name, nil, function(ok, _, err)
            ui_ctx.events.log(ok and "info" or "warn", "ui",
                ("%s -> %s: %s"):format(name, domain, ok and "ok" or tostring(err)))
            if ui_ctx.notify_send then ui_ctx.notify_send(name, domain, ok, err) end
        end)
    end

    return {
        { text = "Send Command...", callback = function()
            ui_ctx.prompt("Send to " .. domain, "", function(name)
                if name ~= "" then send(name) end
            end, command_names)
        end },
        { text = "View Sensors \x10", callback = function()
            local info = client.get(domain) or {}
            local items = {}
            for _, s in ipairs(info.sensors or {}) do
                local label = s.name
                local r = ui_ctx.telemetry_cache
                    and ui_ctx.telemetry_cache.reading(domain .. ":" .. s.name)
                if r and r.value ~= nil then
                    label = label .. " = " .. tostring(r.value) .. (r.unit and (" " .. r.unit) or "")
                end
                table.insert(items, { text = label, callback = function() end })
            end
            if #items == 0 then
                table.insert(items, { text = "(no sensors)", callback = function() end })
            end
            ui_ctx.menu(items)
        end },
        { text = "All Commands \x10", callback = function()
            local items = {}
            for _, name in ipairs(command_names()) do
                table.insert(items, { text = name, callback = function() send(name) end })
            end
            if #items == 0 then
                table.insert(items, { text = "(no commands)", callback = function() end })
            end
            ui_ctx.menu(items)
        end },
        menus.sep(),
        { text = "Rename...", callback = function()
            ui_ctx.prompt("Rename " .. domain, domain, function(new_name)
                if new_name ~= "" and new_name ~= domain then
                    client.admin(domain, "rename", { name = new_name })
                end
            end)
        end },
        { text = "Stop Server", callback = function() client.admin(domain, "stop") end },
        { text = "Remove Domain", callback = function() client.admin(domain, "remove") end },
    }
end

-- ── Command row (Server Config) ──────────────────────────────────────────
-- Rename…, Delete, Sequence…, Data Source…, Response Key…, Duplicate
---@param a table action callbacks { rename, delete, sequence, data_source, response_key, duplicate }
function menus.command_menu(a)
    return {
        { text = "Rename...", callback = a.rename },
        { text = "Delete", callback = a.delete },
        { text = "Sequence...", callback = a.sequence },
        { text = "Data Source...", callback = a.data_source },
        { text = "Response Key...", callback = a.response_key },
        { text = "Duplicate", callback = a.duplicate },
    }
end

-- ── Sequence step row (Server Config) ────────────────────────────────────
-- Rename…, Set Delay…, Move Up, Move Down, Duplicate, Delete
---@param a table action callbacks { rename, set_delay, move_up, move_down, duplicate, delete }
function menus.step_menu(a)
    return {
        { text = "Rename...", callback = a.rename },
        { text = "Set Delay...", callback = a.set_delay },
        { text = "Move Up", callback = a.move_up },
        { text = "Move Down", callback = a.move_down },
        { text = "Duplicate", callback = a.duplicate },
        { text = "Delete", callback = a.delete },
    }
end

-- ── Sensor row (Server Config) ───────────────────────────────────────────
-- Rename…, Edit Peripheral…, Edit Kind ▸, Edit Poll…, Edit Unit…, Delete
---@param a table action callbacks { rename, edit_peripheral, edit_kind, edit_poll, edit_unit, delete }
function menus.sensor_menu(a)
    return {
        { text = "Rename...", callback = a.rename },
        { text = "Edit Peripheral...", callback = a.edit_peripheral },
        { text = "Edit Kind \x10", callback = a.edit_kind },
        { text = "Edit Poll...", callback = a.edit_poll },
        { text = "Edit Unit...", callback = a.edit_unit },
        { text = "Delete", callback = a.delete },
    }
end

-- ── Scene row (Scenes page + dashboard scene strip) ──────────────────────
-- Run, Rename…, Edit Steps…, Duplicate, Delete
---@param a table callbacks { run, rename, edit_steps, duplicate, delete }
function menus.scene_menu(a)
    return {
        { text = "Run", callback = a.run },
        { text = "Rename...", callback = a.rename },
        { text = "Edit Steps...", callback = a.edit_steps },
        { text = "Duplicate", callback = a.duplicate },
        { text = "Delete", callback = a.delete },
    }
end

-- ── Scene/sequence step row (Scenes editor) ──────────────────────────────
-- Edit…, Move Up, Move Down, Duplicate, (net: Edit Wait…, Edit Timeout…), Delete
---@param a table callbacks { edit, move_up, move_down, duplicate, delete, edit_wait, edit_timeout }
---@param opts table { is_net }
function menus.scene_step_menu(a, opts)
    local m = {
        { text = "Edit...", callback = a.edit },
        { text = "Move Up", callback = a.move_up },
        { text = "Move Down", callback = a.move_down },
        { text = "Duplicate", callback = a.duplicate },
    }
    if opts and opts.is_net then
        table.insert(m, { text = "Edit Wait...", callback = a.edit_wait })
        table.insert(m, { text = "Edit Timeout...", callback = a.edit_timeout })
    end
    table.insert(m, { text = "Delete", callback = a.delete })
    return m
end

-- ── Monitor zone (Displays page) ─────────────────────────────────────────
-- Assign Page ▸, Follow Terminal, Clear Zone
---@param a table { assign_page, follow, clear }
function menus.zone_menu(a)
    return {
        { text = "Assign Page \x10", callback = a.assign_page },
        { text = "Follow Terminal", callback = a.follow },
        { text = "Clear Zone", callback = a.clear },
    }
end

-- ── Automation rule row (Automation page) ────────────────────────────────
-- Enable/Disable, Edit Trigger…, Edit Action…, Rename…, Delete
---@param a table { toggle, edit_trigger, edit_action, rename, delete }
---@param opts table { enabled }
function menus.automation_rule_menu(a, opts)
    return {
        { text = (opts and opts.enabled) and "Disable" or "Enable", callback = a.toggle },
        { text = "Edit Trigger...", callback = a.edit_trigger },
        { text = "Edit Action...", callback = a.edit_action },
        { text = "Rename...", callback = a.rename },
        { text = "Delete", callback = a.delete },
    }
end

-- ── Sensor tile (Monitoring page) ────────────────────────────────────────
-- Details, Add Rule…, Filter this domain, ──, Forget sensor
-- "Forget" locally dismisses a sensor that is gone/removed but still lingering
-- (down sensors are shown, not hidden, so a manual escape hatch is needed).
---@param a table callbacks { details, add_rule, filter_domain, forget }
function menus.sensor_tile_menu(a)
    return {
        { text = "Details", callback = a.details },
        { text = "Add Rule...", callback = a.add_rule },
        { text = "Filter this domain", callback = a.filter_domain },
        menus.sep(),
        { text = "Forget sensor", callback = a.forget },
    }
end

-- ── Sidebar empty space / built-in page button (Phase 6a) ────────────────
-- New Page…
---@param a table { new_page = fun(name:string) }
function menus.sidebar_menu(a)
    return { { text = "New Page...", callback = a.new_page } }
end

-- ── Custom page sidebar button (Phase 6a) ────────────────────────────────
-- Rename…, ──, Delete
---@param a table { rename = fun(), delete = fun() }
function menus.custom_page_menu(a)
    return {
        { text = "Rename...", callback = a.rename },
        menus.sep(),
        { text = "Delete",    callback = a.delete },
    }
end

-- ── Editor canvas + element type picker (Phase 6b) ───────────────────────
-- Right-clicking empty space on a custom page. Elements have their own menu
-- (element_menu), reached because right-click dispatch is depth-first.
---@param a table { add = fun() }
function menus.canvas_menu(a)
    return { { text = "Add Element \x10", callback = a.add } }
end

-- One row per widget type, Interactive above Display.
---@param a table { pick = fun(type_name:string) }
---@param types string[] factory.TYPES
function menus.element_type_menu(a, types)
    local out = {}
    for i, t in ipairs(types) do
        if i == 5 then table.insert(out, menus.sep()) end   -- Interactive | Display
        table.insert(out, { text = t, callback = function() a.pick(t) end })
    end
    return out
end

-- ── Placed editor element (Phase 6b) ────────────────────────────────────
-- A placed element's own menu. Entries are type-dependent: asking a TextLabel
-- for its flash period is nonsense, so those rows simply do not appear.
---@param a table action callbacks, see the fields consumed below
---@param opts table { type = string, flash = boolean }
function menus.element_menu(a, opts)
    local t, out = opts.type, {}
    local function add(text, cb) table.insert(out, { text = text, callback = cb }) end

    if t == "TextLabel" then
        add("Edit Text...", a.edit_label)
    elseif t == "RadioButton" then
        add("Edit Options...", a.edit_options)
    elseif t ~= "HorizontalBar" and t ~= "SensorBar" and t ~= "StorageBreakdown" then
        add("Edit Label...", a.edit_label)
    end

    if t == "SensorBar" or t == "SensorReadout" or t == "StorageBreakdown" then
        add("Edit Sensor...", a.edit_sensor)
    end

    add("Edit Colors \x10", a.edit_colors)

    -- "Active" is framework jargon: for a PushButton it is the pressed flash,
    -- for a SwitchButton it is the ON state. Say which.
    if t == "PushButton" then
        add("Edit Pressed Colors \x10", a.edit_active)
    elseif t == "SwitchButton" then
        add("Edit On Colors \x10", a.edit_active)
    end

    if t == "PushButton" then
        add("Edit Route \x10", a.edit_route)
    end

    if t == "LED" or t == "IndicatorLight" then
        add("Edit Scheme \x10", a.edit_scheme)
        add(opts.flash and "Blinking: on" or "Blinking: off", a.toggle_flash)
        if opts.flash then add("Edit Period \x10", a.edit_period) end
    end

    if t == "HorizontalBar" or t == "SensorBar" then
        add("Edit Width...", a.edit_width)
        add("Edit Bar Colors \x10", a.edit_bar_colors)
        add("Show %", a.toggle_percent)
    end

    if t == "StorageBreakdown" then
        add("Edit Top N...", a.edit_top_n)
    end

    table.insert(out, menus.sep())
    add("Move", a.move)
    add("Delete", a.delete)
    return out
end

return menus
