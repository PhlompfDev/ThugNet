-- Graphical first-boot wizard, rebuilt on the UI kit (cc-mek-scada configurator
-- shape): a welcome screen, one concern per step with step dots and gated
-- navigation (Next is disabled until the pane validates), an in-flow theme
-- step, a Summary read-back before anything is written, and a Done screen.
--
-- Owns NO config rules -- Save builds an answers table and calls the shared
-- setup.commit core, so it cannot diverge from the plain-terminal wizard.
--
-- build() constructs the pane tree and returns a controller (the real nav
-- callbacks + element handles) so tests drive the actual validation/advance/
-- commit logic without pixel-hunting. run() is the thin blocking driver.
local ui      = require("graphics.ui")
local events  = require("graphics.events")
local theme   = require("thugnet.ui.theme")
local kit     = require("thugnet.ui.kit")
local config  = require("thugnet.config")
local setup   = require("thugnet.setup")
local version = require("thugnet.version")

local setup_ui = {}
setup_ui.MIN_W, setup_ui.MIN_H = 26, 12

-- pane indices (all panes exist in the tree; navigation skips domain when the
-- server role is off)
local P_WELCOME, P_LABEL, P_ROLES, P_DOMAIN, P_VISUAL, P_SUMMARY, P_DONE =
    1, 2, 3, 4, 5, 6, 7
local TITLES = {
    [P_WELCOME] = "Welcome", [P_LABEL] = "Label", [P_ROLES] = "Roles",
    [P_DOMAIN] = "Domain", [P_VISUAL] = "Look", [P_SUMMARY] = "Review",
    [P_DONE] = "Done",
}

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

    -- ── header: step title (left) + step dots (right) ─────────────────────
    ui.TextBox{ parent = display, x = 1, y = 1, width = w, height = 1, text = "",
                fg_bg = theme.fg_bg("text", "panel") }
    local title_tb = ui.TextBox{ parent = display, x = 2, y = 1, width = 12, height = 1,
        text = "", fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.panel) }
    local dots_tb = ui.TextBox{ parent = display, x = w - 12, y = 1, width = 12, height = 1,
        text = "", alignment = ui.ALIGN.RIGHT,
        fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.panel) }

    -- a single hint line under the header: names the missing requirement while
    -- a step is blocked, blank otherwise
    local hint_tb = ui.TextBox{ parent = display, x = 2, y = 2, width = w - 2, height = 1,
        text = "", fg_bg = theme.fg_bg("warn", "bg") }
    local function show_hint(msg) hint_tb.set_value(msg or "") end

    local body_h = h - 3                       -- rows 3 .. h-1 ; buttons on row h
    local body = ui.Div{ parent = display, x = 1, y = 3, width = w, height = body_h }

    -- overlapping panes; MultiPane shows exactly one
    local panes = {}
    for i = 1, 7 do
        panes[i] = ui.Div{ parent = body, x = 1, y = 1, width = w, height = body_h }
    end
    local pane = ui.MultiPane{ parent = body, x = 1, y = 1, width = w, height = body_h,
                              panes = panes }
    local p_welcome, p_label, p_roles, p_domain, p_visual, p_summary, p_done =
        panes[1], panes[2], panes[3], panes[4], panes[5], panes[6], panes[7]

    local field_fg = ui.cpair(theme.tokens.text, theme.tokens.raised)

    -- pane 1: welcome
    ui.TextBox{ parent = p_welcome, x = 2, y = 2, width = w - 4, height = 1,
        text = "Let's set up this computer.", alignment = ui.ALIGN.CENTER,
        fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
    ui.TextBox{ parent = p_welcome, x = 2, y = 4, width = w - 4, height = 2,
        text = "A few quick steps: name it, pick what it does, and choose a look.",
        alignment = ui.ALIGN.CENTER, fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }

    -- pane 2: label
    ui.TextBox{ parent = p_label, x = 2, y = 1, width = w - 2, height = 1, text = "Computer label:" }
    local f_label = ui.TextField{ parent = p_label, x = 2, y = 3, width = w - 4, height = 1,
        value = existing.label or ("node-" .. os.getComputerID()), max_len = 24, fg_bg = field_fg }

    -- pane 3: roles (each with a one-line explanation baked into the label)
    ui.TextBox{ parent = p_roles, x = 2, y = 1, width = w - 2, height = 1,
                text = "What should this computer do? (pick at least one)" }
    local box = theme.fg_bg("accent", "raised")
    local c_dns = ui.Checkbox{ parent = p_roles, x = 2, y = 3, label = "dns     name server for the network",
        default = ex_roles.dns == true, box_fg_bg = box }
    local c_srv = ui.Checkbox{ parent = p_roles, x = 2, y = 4, label = "server  hosts a domain & its mechanisms",
        default = ex_roles.server == true, box_fg_bg = box }
    local c_ui = ui.Checkbox{ parent = p_roles, x = 2, y = 5, label = "ui      touchscreen control panel",
        default = ex_roles.ui == true, box_fg_bg = box }

    -- pane 4: domain
    ui.TextBox{ parent = p_domain, x = 2, y = 1, width = w - 2, height = 1, text = "Domain name:" }
    local live_domain = require("thugnet.core.store").load("server_config2.json", {}).domain
    local f_domain = ui.TextField{ parent = p_domain, x = 2, y = 3, width = w - 4, height = 1,
        value = existing.server_domain or live_domain or "", max_len = 24, fg_bg = field_fg }

    -- pane 5: look (theme)
    ui.TextBox{ parent = p_visual, x = 2, y = 1, width = w - 2, height = 2,
        text = "Choose a theme (change it later in Settings > Visual)." }
    local theme_sel = ui.RadioButton{ parent = p_visual, x = 2, y = 4,
        options = { "Dark", "Light" },
        radio_colors = ui.cpair(theme.tokens.dim, theme.tokens.raised),
        select_color = theme.tokens.accent,
        default = (existing.theme == "light") and 2 or 1,
        -- preview live: re-tint the palette so the whole wizard recolors the
        -- instant a theme is picked, instead of only after the wizard exits
        callback = function(i)
            theme.set(i == 2 and "light" or "dark")
            theme.repalette(display.window())
        end }
    ui.TextBox{ parent = p_visual, x = 12, y = 4, width = w - 13, height = 1,
        text = "industrial, low-light", fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
    ui.TextBox{ parent = p_visual, x = 12, y = 5, width = w - 13, height = 1,
        text = "bright, high-contrast", fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }

    -- pane 6: summary (read-back)
    ui.TextBox{ parent = p_summary, x = 2, y = 1, width = w - 2, height = 1, text = "Review:" }
    local sum = ui.TextBox{ parent = p_summary, x = 2, y = 3, width = w - 2, height = 4, text = "" }
    ui.TextBox{ parent = p_summary, x = 2, y = body_h - 1, width = w - 2, height = 1,
        text = "Nothing is saved until you confirm.",
        fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }

    -- pane 7: done
    local done_tb = ui.TextBox{ parent = p_done, x = 2, y = 2, width = w - 4, height = 4,
        text = "", alignment = ui.ALIGN.CENTER,
        fg_bg = ui.cpair(theme.tokens.ok_bright, theme.tokens.bg) }

    -- ── logic ─────────────────────────────────────────────────────────────
    local function server_on() return c_srv.get_value() == true end
    local function roles_tbl()
        local r = {}
        if c_dns.get_value() then r.dns = true end
        if server_on() then r.server = true end
        if c_ui.get_value() then r.ui = true end
        return r
    end
    local function chosen_theme() return theme_sel.get_value() == 2 and "light" or "dark" end

    local function config_steps()
        if server_on() then return { P_LABEL, P_ROLES, P_DOMAIN, P_VISUAL } end
        return { P_LABEL, P_ROLES, P_VISUAL }
    end

    local idx = 1

    -- Next is gated on the current pane validating; welcome/visual/summary are
    -- always advanceable.
    local function can_advance()
        if idx == P_LABEL then return (f_label.get_value() or "") ~= ""
        elseif idx == P_ROLES then return next(roles_tbl()) ~= nil
        elseif idx == P_DOMAIN then return (f_domain.get_value() or "") ~= "" end
        return true
    end

    local function build_summary()
        local r = roles_tbl()
        local names = {}
        for k in pairs(r) do names[#names + 1] = k end
        table.sort(names)
        local lines = { "label   " .. f_label.get_value(),
                        "roles   " .. table.concat(names, ", ") }
        if server_on() then lines[#lines + 1] = "domain  " .. f_domain.get_value() end
        lines[#lines + 1] = "theme   " .. chosen_theme()
        sum.set_value(table.concat(lines, "\n"))
    end

    -- element visibility helper (hide with clear so it leaves the layout)
    local function vis(el, show) if show then el.show() else el.hide(true) end end

    -- buttons on the bottom row; only the relevant primary button is shown
    local brow = ui.Div{ parent = display, x = 1, y = h, width = w, height = 1 }
    local back_btn, next_btn, save_btn   -- forward refs for goto_pane
    local refresh_gate                    -- forward ref

    local function build_dots()
        if idx < P_LABEL or idx > P_VISUAL then return "" end
        local steps = config_steps()
        local pos = 0
        for i, p in ipairs(steps) do if p == idx then pos = i end end
        local s = ""
        for i = 1, #steps do s = s .. (i <= pos and "\x07" or "\x09") .. " " end
        return s
    end

    local function goto_pane(n)
        idx = n
        pane.set_value(n)
        title_tb.set_value(TITLES[n] or "")
        dots_tb.set_value(build_dots())
        show_hint("")
        vis(back_btn, n ~= P_WELCOME and n ~= P_DONE)
        vis(next_btn, n ~= P_SUMMARY and n ~= P_DONE)
        vis(save_btn, n == P_SUMMARY)
        refresh_gate()
    end

    -- enable/disable Next from can_advance; clear the hint when advanceable
    refresh_gate = function()
        if idx == P_SUMMARY or idx == P_DONE or idx == P_WELCOME then return end
        if can_advance() then next_btn.enable(); show_hint("")
        else next_btn.disable() end
    end

    local function next_action()
        if idx == P_WELCOME then goto_pane(P_LABEL)
        elseif idx == P_LABEL then
            if (f_label.get_value() or "") == "" then show_hint("Label can't be empty."); return end
            goto_pane(P_ROLES)
        elseif idx == P_ROLES then
            if next(roles_tbl()) == nil then show_hint("Pick at least one role."); return end
            goto_pane(server_on() and P_DOMAIN or P_VISUAL)
        elseif idx == P_DOMAIN then
            if (f_domain.get_value() or "") == "" then show_hint("Domain can't be empty."); return end
            goto_pane(P_VISUAL)
        elseif idx == P_VISUAL then
            build_summary(); goto_pane(P_SUMMARY)
        end
    end

    local function back_action()
        if idx == P_LABEL then goto_pane(P_WELCOME)
        elseif idx == P_ROLES then goto_pane(P_LABEL)
        elseif idx == P_DOMAIN then goto_pane(P_ROLES)
        elseif idx == P_VISUAL then goto_pane(server_on() and P_DOMAIN or P_ROLES)
        elseif idx == P_SUMMARY then goto_pane(P_VISUAL) end
    end

    local function save_action()
        if idx ~= P_SUMMARY then return end
        local answers = { label = f_label.get_value(), roles = roles_tbl(),
                          domain = server_on() and f_domain.get_value() or nil,
                          theme = chosen_theme() }
        local cfg = setup.commit(answers, ctx.existing)
        if config.validate(cfg) then
            done_tb.set_value("All set!\n\n" .. tostring(cfg.label)
                .. " is configured.\nStarting ThugNet...")
            goto_pane(P_DONE)
            on_done(cfg)
        end
    end

    -- (the roles gate refreshes from the run() loop after each event, which
    -- covers a checkbox toggle; no per-widget callback wiring needed)
    back_btn = ui.PushButton{ parent = brow, x = 2, y = 1, text = "\x11 Back",
        fg_bg = theme.fg_bg("dim", "panel"), active_fg_bg = theme.fg_bg("text", "raised"),
        callback = back_action }
    next_btn = ui.PushButton{ parent = brow, x = w - 9, y = 1, text = "Next \x10",
        fg_bg = theme.fg_bg("accent", "panel"), active_fg_bg = theme.fg_bg("text", "raised"),
        dis_fg_bg = theme.fg_bg("dim", "panel"), callback = next_action }
    save_btn = ui.PushButton{ parent = brow, x = w - 7, y = 1, text = "Save",
        fg_bg = theme.fg_bg("ok", "panel"), active_fg_bg = theme.fg_bg("text", "raised"),
        callback = save_action }

    goto_pane(P_WELCOME)

    return {
        -- test seams: the real nav callbacks + element handles
        next = next_action, back = back_action, save = save_action,
        pane_index = function() return idx end,
        can_advance = can_advance,
        refresh_gate = refresh_gate,
        fields = { label = f_label, domain = f_domain },
        roles  = { dns = c_dns, server = c_srv, ui = c_ui },
        theme_sel = theme_sel,
    }
end

-- Thin blocking driver (not unit-tested): build on the real terminal and pump
-- events until Save captures a cfg. Mirrors app.lua's translate-and-dispatch
-- shape, but pre-kernel (its own os.pullEventRaw loop -- no kernel yet). After
-- each event the Next gate is refreshed so it enables the instant a field
-- becomes valid (TextField has no per-keystroke callback of its own).
---@return table cfg
function setup_ui.run()
    local target = term.current()
    theme.apply(target)
    local display = ui.DisplayBox{ window = target, fg_bg = theme.fg_bg("text", "bg") }
    local existing = config.exists() and config.load() or nil
    local done
    local ctrl = setup_ui.build(display, { existing = existing }, function(cfg) done = cfg end)

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
        if ctrl.refresh_gate then pcall(ctrl.refresh_gate) end
    end

    -- let the Done screen linger a beat before boot continues
    pcall(function() if sleep then sleep(1.2) end end)
    display.delete()
    return done
end

return setup_ui
