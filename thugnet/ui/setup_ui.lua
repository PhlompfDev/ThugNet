-- Graphical first-boot wizard, mirroring cc-mek-scada's configurator frame: a
-- titled header over a MultiPane of steps (label -> roles -> domain -> summary,
-- domain skipped when the server role is off). Owns NO config rules -- Save
-- builds an answers table and calls the shared setup.commit core, so it cannot
-- diverge from the plain-terminal wizard.
--
-- build() constructs the pane tree and returns a controller (the real nav
-- callbacks + element handles) so tests drive the actual validation/advance/
-- commit logic without pixel-hunting. run() is the thin blocking driver.
local ui      = require("graphics.ui")
local events  = require("graphics.events")
local theme   = require("thugnet.ui.theme")
local config  = require("thugnet.config")
local setup   = require("thugnet.setup")
local version = require("thugnet.version")

local setup_ui = {}
setup_ui.MIN_W, setup_ui.MIN_H = 26, 12

-- Build the wizard into `display`. ctx = { existing = cfg|nil }; on_done(cfg)
-- fires when Save commits a valid configuration.
---@param display table a DisplayBox
---@param ctx table { existing = table|nil }
---@param on_done fun(cfg:table)
---@return table controller
function setup_ui.build(display, ctx, on_done)
    local existing = ctx.existing or {}
    local ex_roles = existing.roles or {}
    local w, h = display.window().getSize()

    ui.TextBox{ parent = display, x = 1, y = 1, width = w, height = 1,
                text = " THUGNET v" .. version .. " setup",
                fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.panel) }

    local body_h = h - 3                      -- rows 3 .. h-1 ; nav sits on row h
    local body = ui.Div{ parent = display, x = 1, y = 3, width = w, height = body_h }

    -- panes overlap (all at 1,1); MultiPane shows exactly one at a time
    local p_label   = ui.Div{ parent = body, x = 1, y = 1, width = w, height = body_h }
    local p_roles   = ui.Div{ parent = body, x = 1, y = 1, width = w, height = body_h }
    local p_domain  = ui.Div{ parent = body, x = 1, y = 1, width = w, height = body_h }
    local p_summary = ui.Div{ parent = body, x = 1, y = 1, width = w, height = body_h }
    local pane = ui.MultiPane{ parent = body, x = 1, y = 1, width = w, height = body_h,
                              panes = { p_label, p_roles, p_domain, p_summary } }

    local field_fg = ui.cpair(theme.tokens.text, theme.tokens.raised)
    local err_fg   = theme.fg_bg("alert", "bg")

    -- pane 1: label
    ui.TextBox{ parent = p_label, x = 2, y = 1, width = w - 2, height = 1, text = "Computer label:" }
    local f_label = ui.TextField{ parent = p_label, x = 2, y = 3, width = w - 4, height = 1,
        value = existing.label or ("node-" .. os.getComputerID()), max_len = 24, fg_bg = field_fg }
    local e_label = ui.TextBox{ parent = p_label, x = 2, y = 5, width = w - 2, height = 1,
        text = "", fg_bg = err_fg, hidden = true }

    -- pane 2: roles
    ui.TextBox{ parent = p_roles, x = 2, y = 1, width = w - 2, height = 1,
                text = "Roles (pick at least one):" }
    local box = theme.fg_bg("accent", "raised")
    local c_dns = ui.Checkbox{ parent = p_roles, x = 2, y = 3, label = "dns - name server",
        default = ex_roles.dns == true, box_fg_bg = box }
    local c_srv = ui.Checkbox{ parent = p_roles, x = 2, y = 4, label = "server - host a domain",
        default = ex_roles.server == true, box_fg_bg = box }
    local c_ui = ui.Checkbox{ parent = p_roles, x = 2, y = 5, label = "ui - control panel",
        default = ex_roles.ui == true, box_fg_bg = box }
    local e_roles = ui.TextBox{ parent = p_roles, x = 2, y = 7, width = w - 2, height = 1,
        text = "", fg_bg = err_fg, hidden = true }

    -- pane 3: domain (a live server_config2.json owns the real name -> prefill)
    ui.TextBox{ parent = p_domain, x = 2, y = 1, width = w - 2, height = 1, text = "Domain name:" }
    local live_domain = require("thugnet.core.store").load("server_config2.json", {}).domain
    local f_domain = ui.TextField{ parent = p_domain, x = 2, y = 3, width = w - 4, height = 1,
        value = existing.server_domain or live_domain or "", max_len = 24, fg_bg = field_fg }
    local e_domain = ui.TextBox{ parent = p_domain, x = 2, y = 5, width = w - 2, height = 1,
        text = "", fg_bg = err_fg, hidden = true }

    -- pane 4: summary
    ui.TextBox{ parent = p_summary, x = 2, y = 1, width = w - 2, height = 1, text = "Review:" }
    local sum = ui.TextBox{ parent = p_summary, x = 2, y = 3, width = w - 2, height = 4, text = "" }

    local function server_on() return c_srv.get_value() == true end
    local function roles_tbl()
        local r = {}
        if c_dns.get_value() then r.dns = true end
        if server_on() then r.server = true end
        if c_ui.get_value() then r.ui = true end
        return r
    end
    local function build_summary()
        local r = roles_tbl()
        local names = {}
        for k in pairs(r) do names[#names + 1] = k end
        table.sort(names)
        sum.set_value(("label:  %s\nroles:  %s%s"):format(
            f_label.get_value(), table.concat(names, ", "),
            server_on() and ("\ndomain: " .. f_domain.get_value()) or ""))
    end

    local idx = 1
    local function goto_pane(n) idx = n; pane.set_value(n) end

    -- advance with per-pane validation; domain pane is skipped when server is off
    local function next_action()
        if idx == 1 then
            if (f_label.get_value() or "") == "" then
                e_label.set_value("Label cannot be empty."); e_label.show(); return
            end
            e_label.hide(); goto_pane(2)
        elseif idx == 2 then
            if next(roles_tbl()) == nil then
                e_roles.set_value("Pick at least one role."); e_roles.show(); return
            end
            e_roles.hide()
            if server_on() then goto_pane(3) else goto_pane(4); build_summary() end
        elseif idx == 3 then
            if (f_domain.get_value() or "") == "" then
                e_domain.set_value("Domain cannot be empty."); e_domain.show(); return
            end
            e_domain.hide(); goto_pane(4); build_summary()
        end
    end
    local function back_action()
        if idx == 2 then goto_pane(1)
        elseif idx == 3 then goto_pane(2)
        elseif idx == 4 then goto_pane(server_on() and 3 or 2) end
    end
    local function save_action()
        if idx ~= 4 then return end
        local answers = { label = f_label.get_value(), roles = roles_tbl(),
                          domain = server_on() and f_domain.get_value() or nil }
        local cfg = setup.commit(answers, ctx.existing)
        if config.validate(cfg) then on_done(cfg) end
    end

    local brow = ui.Div{ parent = display, x = 1, y = h, width = w, height = 1 }
    ui.PushButton{ parent = brow, x = 2, y = 1, text = "< Back",
        fg_bg = theme.fg_bg("dim", "panel"), active_fg_bg = theme.fg_bg("text", "raised"),
        callback = back_action }
    ui.PushButton{ parent = brow, x = w - 13, y = 1, text = "Next >",
        fg_bg = theme.fg_bg("accent", "panel"), active_fg_bg = theme.fg_bg("text", "raised"),
        callback = next_action }
    ui.PushButton{ parent = brow, x = w - 5, y = 1, text = "Save",
        fg_bg = theme.fg_bg("ok", "panel"), active_fg_bg = theme.fg_bg("text", "raised"),
        callback = save_action }

    goto_pane(1)

    return {
        -- test seams: the real nav callbacks + element handles, so a test drives
        -- the same validation/advance/commit path the buttons do
        next = next_action, back = back_action, save = save_action,
        pane_index = function() return idx end,
        fields = { label = f_label, domain = f_domain },
        roles  = { dns = c_dns, server = c_srv, ui = c_ui },
    }
end

-- Thin blocking driver (not unit-tested): build on the real terminal and pump
-- events until Save captures a cfg. Mirrors app.lua's translate-and-dispatch
-- shape, but pre-kernel (its own os.pullEventRaw loop -- no kernel yet).
---@return table cfg
function setup_ui.run()
    local target = term.current()
    theme.apply(target)
    local display = ui.DisplayBox{ window = target, fg_bg = theme.fg_bg("text", "bg") }
    local existing = config.exists() and config.load() or nil
    local done
    setup_ui.build(display, { existing = existing }, function(cfg) done = cfg end)

    while done == nil do
        local e = { os.pullEventRaw() }
        local name = e[1]
        if name == "mouse_click" or name == "mouse_up" or name == "mouse_drag"
            or name == "mouse_scroll" then
            local mev = events.new_mouse_event(name, e[2], e[3], e[4])
            if mev then display.handle_mouse(mev) end
        elseif name == "key" or name == "key_up" or name == "char" then
            local kev = events.new_key_event(name, e[2], e[3])
            if kev then display.handle_key(kev) end
        elseif name == "paste" then
            display.handle_paste(e[2])
        elseif name == "terminate" then
            error("Terminated", 0)
        end
    end

    display.delete()
    return done
end

return setup_ui
