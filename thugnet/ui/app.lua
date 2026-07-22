-- Display manager: owns every surface (terminal + monitors + zones),
-- builds/tears down page instances with full watcher lifecycle, routes
-- input events, shows alert toasts. The v1 rebuild leaks die here.
local ui      = require("graphics.ui")
local gevents = require("graphics.events")
local flasher = require("graphics.flasher")
local cmenu   = require("graphics.context_menu")
local tprompt = require("graphics.text_prompt")
local tcd     = require("scada-common.tcd")
local theme   = require("thugnet.ui.theme")
local nav     = require("thugnet.ui.nav")
local widgets = require("thugnet.ui.widgets")
local menus   = require("thugnet.ui.menus")

local app = {}

local NAV_W = 12
local SIDEBAR_MIN_W = 30
local TOAST_SECS = 5
local DISPLAYS_PATH = "displays.json"

local C                  -- ctx = { kernel, bus, events, config, client, telemetry_cache, store, updater? }
local started = false
local building = false
local surfaces = {}      -- { target, display, root_win?, page_id, owned = {handles}, kind, rect?, monitor? }
local app_handles = {}   -- live for the whole app (event routing etc.)
local rebuild_pending = nil
local toasts = {}        -- per root target: { win, timer }
local last_rc = { x = 2, y = 2 }  -- absolute terminal coords of last right-click
                                  -- (anchor for ui_ctx.menu / ui_ctx.prompt)

-- ── zone math (pure) ─────────────────────────────────────────────────────

---@return table[] row-major { x, y, w, h }; last row/col absorb remainders
function app.zone_rects(w, h, rows, cols)
    rows = math.max(rows or 1, 1)
    cols = math.max(cols or 1, 1)
    local base_w = math.floor(w / cols)
    local base_h = math.floor(h / rows)
    local rects = {}
    for r = 1, rows do
        for c = 1, cols do
            local x = (c - 1) * base_w + 1
            local y = (r - 1) * base_h + 1
            local zw = (c == cols) and (w - x + 1) or base_w
            local zh = (r == rows) and (h - y + 1) or base_h
            table.insert(rects, { x = x, y = y, w = zw, h = zh })
        end
    end
    return rects
end

-- ── helpers ──────────────────────────────────────────────────────────────

local function monitors()
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            out[name] = peripheral.wrap(name)
        end
    end
    return out
end

local function has_monitor()
    for _ in pairs(monitors()) do return true end
    return false
end

local function display_cfg(name)
    local all = C.store.load(DISPLAYS_PATH, {})
    return all[name] or { text_scale = 1.0, zones = { rows = 1, cols = 1 }, pages = { "follow" } }
end

function app.set_display_cfg(name, cfg)
    local all = C.store.load(DISPLAYS_PATH, {})
    all[name] = cfg
    C.store.save(DISPLAYS_PATH, all)
    app.request_rebuild()
end

local function visible_pages()
    return nav.pages({ config = C.config, has_monitor = has_monitor() })
end

local function terminal_surface()
    for _, s in ipairs(surfaces) do
        if s.kind == "terminal" then return s end
    end
end

local function active_page_id()
    local id = C.bus.get("active_page")
    if id and nav.get(id) then return id end
    local pages = visible_pages()
    return pages[1] and pages[1].id
end

-- ── surface construction ─────────────────────────────────────────────────

local function make_ui_ctx(surface)
    local ctx = {
        theme = theme,
        kernel = C.kernel,
        bus = C.bus,
        events = C.events,
        client = C.client,
        telemetry_cache = C.telemetry_cache,
        config = C.config,
        transport = C.transport,
        store = C.store,
        -- "terminal" or "zone". Editing is terminal-only: route_touch delivers a
        -- monitor touch as a left-click TAP and there is no monitor right-click, so
        -- any click-to-commit gesture on a zone would be uncancellable.
        surface_kind = surface and surface.kind or "terminal",
        nav_to = function(id) C.bus.set("active_page", id, { persist = true }) end,
        -- pages trigger a full teardown+rebuild after structural mutations
        request_rebuild = function() app.request_rebuild() end,
        -- Scenes page: which scene the editor targets (survives rebuilds via bus)
        selected_scene = C.bus.get("scenes_selected"),
    }
    function ctx.own(h)
        table.insert(surface.owned, h)
        return h
    end
    -- context menu anchored at the last right-click; Cancel is always appended
    function ctx.menu(items)
        local s = terminal_surface()
        if not s then return end
        local full = {}
        for _, it in ipairs(items or {}) do table.insert(full, it) end
        table.insert(full, { text = "Cancel", callback = function() end })
        cmenu.open(s.target, last_rc.x, last_rc.y, full)
    end
    -- text prompt near the same anchor
    function ctx.prompt(label, initial, on_confirm, suggestions_fn)
        local s = terminal_surface()
        if not s then return end
        tprompt.open(s.target, last_rc.x, last_rc.y, label, initial, on_confirm, suggestions_fn)
    end
    return ctx
end

-- A zone keeps the page id it was assigned even after that page is deleted, and
-- nothing rewrites displays.json on delete. Without this the zone just stays a
-- black rectangle forever with no way to tell it apart from a hardware fault.
local function build_missing_page(parent)
    local w, h = parent.window().getSize()
    local msg = "(page removed)"
    -- an element placed past its parent's right edge gets frame width <= 0,
    -- which crashes inside util.strwrap(); clamp both axes into the frame
    ui.TextBox{ parent = parent,
        x = math.max(1, math.floor((w - #msg) / 2) + 1),
        y = math.max(1, math.floor(h / 2)),
        width = math.max(1, math.min(#msg, w)), height = 1, text = msg,
        fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
end

local function build_page_into(parent, page_id, surface)
    local def = nav.get(page_id)
    if not def then
        -- "none" is a deliberate choice to leave the zone empty; any other
        -- unresolvable id is a dangling reference and should say so
        if page_id ~= "none" then build_missing_page(parent) end
        return
    end
    local ui_ctx = make_ui_ctx(surface)
    local content = widgets.page_container(parent, ui_ctx, def)
    if content then def.build(content, ui_ctx) end
end

-- sidebar right-click on empty space, or on a built-in page's button: offers
-- only "New Page…" — mutations route through the C.on_sidebar_menu hook so
-- app.lua never imports custom_pages directly.
local function open_sidebar_menu()
    local ctx = make_ui_ctx(terminal_surface())
    ctx.menu(menus.sidebar_menu{
        new_page = function()
            ctx.prompt("Page Name", "", function(name)
                if name and name ~= "" then
                    C.on_sidebar_menu.new_page(name)
                    app.request_rebuild()
                end
            end)
        end })
end

-- sidebar right-click on a custom page's button: Rename…/Delete
---@param def page_def the custom page's descriptor
local function open_custom_page_menu(def)
    local ctx = make_ui_ctx(terminal_surface())
    ctx.menu(menus.custom_page_menu{
        rename = function()
            ctx.prompt("Page Name", def.name, function(name)
                if name and name ~= "" then
                    C.on_sidebar_menu.rename(def.id, name)
                    app.request_rebuild()
                end
            end)
        end,
        delete = function()
            C.on_sidebar_menu.delete(def.id)
            app.request_rebuild()
        end })
end

-- Fixed sidebar category order; a page with no category falls into a trailing
-- "misc" bucket (defensive -- every built-in sets one).
local CATEGORY_ORDER = { "overview", "control", "telemetry", "network", "custom", "system", "misc" }

-- Reorder the visible pages into category buckets, inserting a { spacer = true }
-- marker between non-empty buckets. DISPLAY ONLY -- nav.pages order is untouched
-- (default-page logic and every other consumer are unaffected); registration
-- order is preserved within a bucket.
local function bucketed(pages)
    local buckets = {}
    for _, def in ipairs(pages) do
        local c = def.category or "misc"
        buckets[c] = buckets[c] or {}
        table.insert(buckets[c], def)
    end
    local out = {}
    for _, c in ipairs(CATEGORY_ORDER) do
        local b = buckets[c]
        if b then
            if #out > 0 then table.insert(out, { spacer = true }) end
            for _, def in ipairs(b) do table.insert(out, def) end
        end
    end
    return out
end

-- The page list, as a scrollable ListBox rather than fixed rows.
--
-- Custom pages are the first page source with unbounded cardinality, so the
-- list can outgrow its own height: a button laid out past the sidebar either
-- renders nowhere (window.create past the parent is legal in CC) or trips the
-- frame assert. Both leave the page unreachable — and since Delete is only
-- offered by right-clicking a page's own button, an unreachable custom page
-- could not be removed in-game at all. A ListBox keeps every registered page
-- one scroll away, so reachability and deletability hold for any page count.
---@param narrow boolean drawer mode (no sidebar column): picking closes it
local function build_sidebar(display, pages, active, x, y, width, height, narrow)
    local sidebar = ui.Div{ parent = display, x = x, y = y, width = width, height = height,
                            fg_bg = theme.fg_bg("dim", "panel") }
    ui.Tiling{ parent = sidebar, x = 1, y = 1, width = width, height = height,
               fill_c = ui.cpair(theme.tokens.panel, theme.tokens.panel) }

    local rows = bucketed(pages)
    local list = ui.ListBox{
        parent = sidebar, x = 1, y = 1, width = width, height = height,
        scroll_height = math.max(#rows + 1, height),   -- spacer rows count toward scroll
        fg_bg = theme.fg_bg("dim", "panel"),
        nav_fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.panel),
        nav_active = ui.cpair(theme.tokens.accent, theme.tokens.panel) }

    -- the ListBox reserves its rightmost column for the scroll bar, so rows
    -- inherit width - 1; truncate labels to that, not to the sidebar width
    local label_w = width - 1

    for _, def in ipairs(rows) do
        if def.spacer then
            -- a non-interactive blank row separating two category buckets
            ui.TextBox{ parent = list, x = 1, y = 1, width = label_w, height = 1,
                        text = "", fg_bg = theme.fg_bg("panel", "panel") }
        else
            local is_active = def.id == active
            local label = (is_active and "\x95" or " ") .. def.name
            if #label > label_w then label = label:sub(1, label_w) end
            local pid = def.id
            local btn = ui.PushButton{
                -- explicit width: PushButton otherwise sizes to its text, and a
                -- short page name leaves a dead zone on the right of the row
                -- (left-click did nothing; right-click fell through to the
                -- list's generic menu instead of the row's own)
                parent = list, x = 1, height = 1, width = label_w,
                text = label, alignment = ui.ALIGN.LEFT,
                fg_bg = is_active and ui.cpair(theme.tokens.accent, theme.tokens.raised)
                                   or ui.cpair(theme.tokens.dim, theme.tokens.panel),
                active_fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                callback = function()
                    if narrow then C.bus.set("nav_open", false) end
                    C.bus.set("active_page", pid, { persist = true })
                end,
            }

            if C.on_sidebar_menu then
                local d = def
                btn.set_right_click_handler(function()
                    if d.is_custom then
                        open_custom_page_menu(d)
                    else
                        open_sidebar_menu()
                    end
                    return true
                end)
            end
        end
    end

    if C.on_sidebar_menu then
        -- empty space below the last row belongs to the ListBox, not the Div
        list.set_right_click_handler(function() open_sidebar_menu(); return true end)
        sidebar.set_right_click_handler(function() open_sidebar_menu(); return true end)
    end

    return list
end

local function build_terminal_surface(target)
    local w, h = target.getSize()
    theme.apply(target)
    local display = ui.DisplayBox{ window = target, fg_bg = theme.fg_bg("text", "bg") }
    -- Overlays (context menu / text prompt) save+restore the pixels they cover
    -- via getLine, which exists on `window` objects but NOT on a raw terminal
    -- redirect (term.current()). Target the DisplayBox's window so overlays have
    -- getLine in real CC — matches v1 (shared._display_win = display.window()).
    local surface = { kind = "terminal", target = display.window(), display = display, owned = {} }
    table.insert(surfaces, surface)

    local pages = visible_pages()
    local active = active_page_id()
    local narrow = w < SIDEBAR_MIN_W
    -- wide terminals can collapse the sidebar for a full-width content area;
    -- persisted, it's a preference. Pockets instead get the transient drawer.
    local collapsed = C.bus.get("nav_collapsed") == true
    local show_sidebar = (not narrow) and (not collapsed)
    -- pocket computers have no room for a sidebar column, so the page list
    -- opens over the content as a drawer. Without it custom pages could not be
    -- created, renamed or deleted on a pocket at all. Transient: not persisted.
    local nav_open = narrow and C.bus.get("nav_open") == true

    -- header
    ui.TextBox{ parent = display, x = 1, y = 1, width = w, height = 1,
                text = "", fg_bg = theme.fg_bg("text", "panel") }
    local title_x
    if narrow then
        ui.PushButton{ parent = display, x = 1, y = 1, width = 3, height = 1,
            text = nav_open and " \x11" or " \x10",
            fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.panel),
            active_fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
            callback = function() C.bus.set("nav_open", not nav_open) end }
        title_x = 5
    else
        ui.PushButton{ parent = display, x = 1, y = 1, width = 3, height = 1,
            text = show_sidebar and " \x11" or " \x10",
            fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.panel),
            active_fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
            callback = function()
                C.bus.set("nav_collapsed", not collapsed, { persist = true })
            end }
        ui.TextBox{ parent = display, x = 5, y = 1, width = 10, height = 1,
                    text = "\x07 ThugNet", fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.panel) }
        title_x = 16
    end
    ui.TextBox{ parent = display, x = title_x, y = 1,
                width = math.max(1, math.min(#C.config.label, w - title_x - 6)),
                height = 1, text = C.config.label,
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.panel) }
    local dns_dot = ui.TextBox{ parent = display, x = w - 4, y = 1, width = 3, height = 1,
                                text = "\x07 ", fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.panel) }
    if C.client then
        local function set_dot(ok)
            dns_dot.recolor(ok and theme.tokens.ok_bright or theme.tokens.alert)
        end
        set_dot(C.client.dns_ok())
        surface.owned[#surface.owned + 1] = C.client.on_dns(set_dot)
    end

    if nav_open then
        -- the drawer owns the whole body; no content is built behind it
        build_sidebar(display, pages, active, 1, 2, w, h - 1, true)
        return
    end

    local content_x = show_sidebar and (NAV_W + 1) or 1
    local content = ui.Div{ parent = display, x = content_x, y = 2,
                            width = w - (show_sidebar and NAV_W or 0), height = h - 1,
                            fg_bg = theme.fg_bg("text", "bg") }

    if show_sidebar then
        build_sidebar(display, pages, active, 1, 2, NAV_W, h - 1, false)
    end

    if active then build_page_into(content, active, surface) end
end

local function build_monitor_surface(name, mon)
    local cfg = display_cfg(name)
    if mon.setTextScale then mon.setTextScale(cfg.text_scale or 1.0) end
    theme.apply(mon)
    local mw, mh = mon.getSize()
    local rects = app.zone_rects(mw, mh, cfg.zones.rows, cfg.zones.cols)
    for i, rect in ipairs(rects) do
        local zone_win = window.create(mon, rect.x, rect.y, rect.w, rect.h, true)
        local display = ui.DisplayBox{ window = zone_win, fg_bg = theme.fg_bg("text", "bg") }
        local page_id = (cfg.pages or {})[i] or "follow"
        local resolved = page_id == "follow" and active_page_id() or page_id
        local surface = { kind = "zone", target = mon, root_win = zone_win, display = display,
                          owned = {}, rect = rect, monitor = name, page_id = resolved }
        table.insert(surfaces, surface)
        if resolved then build_page_into(display, resolved, surface) end
    end
end

-- ── lifecycle ────────────────────────────────────────────────────────────

local function teardown()
    cmenu.close()
    tprompt.close()
    for _, surface in ipairs(surfaces) do
        for _, h in ipairs(surface.owned) do
            if h and h.cancel then h.cancel() end
        end
    end
    surfaces = {}
    flasher.clear()
    for _, t in pairs(toasts) do
        if t.timer then t.timer.cancel() end
    end
    toasts = {}
end

local function build()
    building = true
    -- The flag must unwind even when a page builder throws: it gates the
    -- active_page watcher's rebuilds, so leaving it stuck true after a mid-build
    -- error would permanently kill sidebar page switching. kernel.step's pcall
    -- contains the error either way; this makes the NEXT rebuild possible.
    local ok, err = pcall(function()
        teardown()
        build_terminal_surface(term.current())
        for name, mon in pairs(monitors()) do
            build_monitor_surface(name, mon)
        end
    end)
    building = false
    if not ok then error(err, 0) end
end

function app.request_rebuild()
    if rebuild_pending then return end
    rebuild_pending = C.kernel.after(0.1, function()
        rebuild_pending = nil
        build()
    end)
end

function app.rebuild() build() end

-- ── toasts ───────────────────────────────────────────────────────────────

local function show_toast(entry)
    -- alerts stay red; "ok" toasts (e.g. a domain coming back) show green
    local is_ok = entry.severity == "ok"
    for _, surface in ipairs(surfaces) do
        if surface.kind == "terminal" or surface.kind == "zone" then
            local root = surface.kind == "terminal" and surface.target or surface.root_win
            local w = root.getSize()
            local key = tostring(root)
            local old = toasts[key]
            if old and old.timer then old.timer.cancel() end
            local win = (old and old.win) or window.create(root, 1, 1, w, 1, false)
            win.setBackgroundColor(is_ok and theme.tokens.ok or theme.tokens.alert)
            win.setTextColor(theme.tokens.bg)
            win.setVisible(true)
            win.clear()
            win.setCursorPos(2, 1)
            win.write(("%s %s: %s"):format(is_ok and "\x07" or "!",
                entry.source, entry.text):sub(1, w - 2))
            local display = surface.display
            toasts[key] = { win = win, timer = C.kernel.after(TOAST_SECS, function()
                win.setVisible(false)
                display.redraw()
                toasts[key] = nil
            end) }
        end
    end
end

-- ── input routing ────────────────────────────────────────────────────────

-- overlay-aware terminal mouse routing (v1 ui_demo loop, minus the editor):
-- prompt eats everything (outside click closes, inside clicks interact),
-- then open menu, then right-click dispatch, then normal element handling.
local function route_mouse(ev_name, p1, p2, p3)
    local ev = gevents.new_mouse_event(ev_name, p1, p2, p3)
    if not ev then return end
    if tprompt.is_active() then
        tprompt.handle_mouse(ev)
        return
    end
    if cmenu.is_active() then
        cmenu.handle_mouse(ev)
        return
    end
    local s = terminal_surface()
    if not s then return end
    if ev.button == gevents.CLICK_BUTTON.RIGHT_BUTTON
       and ev.type == gevents.MOUSE_CLICK.DOWN then
        last_rc.x, last_rc.y = p2, p3
        s.display.handle_right_click(ev)
    else
        s.display.handle_mouse(ev)
    end
end

local function route_touch(side, x, y)
    for _, s in ipairs(surfaces) do
        if s.kind == "zone" and s.monitor == side then
            local r = s.rect
            if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
                local ev = gevents.new_mouse_event("monitor_touch", side, x - r.x + 1, y - r.y + 1)
                if ev then s.display.handle_mouse(ev) end
                return
            end
        end
    end
end

-- ── public lifecycle ─────────────────────────────────────────────────────

---@param ctx table { kernel, bus, events, config, client, telemetry_cache, store, updater? }
function app.start(ctx)
    if started then return end
    C = ctx
    started = true

    -- framework timers (LED blink + delayed flashes); overlays repaint on
    -- top afterwards so animated elements never overwrite them
    table.insert(app_handles, C.kernel.on_event("timer", function(id)
        flasher.step(id)
        tcd.handle(id)
        cmenu.redraw()
        tprompt.redraw()
    end))

    -- input
    for _, ev in ipairs({ "mouse_click", "mouse_up", "mouse_drag", "mouse_scroll" }) do
        local name = ev
        table.insert(app_handles, C.kernel.on_event(name, function(p1, p2, p3)
            route_mouse(name, p1, p2, p3)
        end))
    end
    table.insert(app_handles, C.kernel.on_event("monitor_touch", route_touch))
    for _, ev in ipairs({ "key", "key_up", "char" }) do
        local name = ev
        table.insert(app_handles, C.kernel.on_event(name, function(p1, p2)
            local kev = gevents.new_key_event(name, p1, p2)
            if tprompt.is_active() then
                tprompt.handle_key(kev)
                return
            end
            local s = terminal_surface()
            if not s then return end
            if kev then s.display.handle_key(kev) end
        end))
    end
    table.insert(app_handles, C.kernel.on_event("paste", function(text)
        if tprompt.is_active() then tprompt.handle_paste(text) end
    end))

    -- structural changes -> rebuild
    for _, ev in ipairs({ "term_resize", "monitor_resize", "peripheral", "peripheral_detach" }) do
        table.insert(app_handles, C.kernel.on_event(ev, function() app.request_rebuild() end))
    end

    -- page switch / nav drawer or collapse toggle -> rebuild (deferred so it
    -- never happens mid-build)
    for _, key in ipairs({ "active_page", "nav_open", "nav_collapsed" }) do
        table.insert(app_handles, C.bus.watch(key, function()
            if not building then app.request_rebuild() end
        end))
    end

    -- alert toasts
    table.insert(app_handles, C.events.on_alert(show_toast))

    -- domain up/down transitions are impossible to miss: red toast on loss,
    -- green on return (the tile/LED state changes too, but a toast reaches
    -- whichever page is open)
    if C.client then
        table.insert(app_handles, C.client.on_change(function(kind, domain)
            if kind == "down" then
                show_toast({ source = "net", severity = "alert",
                             text = "domain down: " .. tostring(domain) })
            elseif kind == "up" then
                show_toast({ source = "net", severity = "ok",
                             text = "domain up: " .. tostring(domain) })
            end
        end))
    end

    -- Updater toasts: on_notify/on_countdown keep updater.lua free of any UI
    -- import (a stated architecture rule) -- it only ever hands app.lua a
    -- version/duration, never a toast shape. A new version is good news
    -- (green); the auto-install countdown is urgent (red) since a reboot is
    -- about to happen and a keypress is the only way to stop it. Both fire
    -- only here, in the UI path, so a headless node (no app.start call) never
    -- shows one -- it still gets the Events-page log entry either way.
    if C.updater then
        table.insert(app_handles, C.updater.on_notify(function(version)
            show_toast({ source = "update", severity = "ok",
                         text = "v" .. tostring(version) .. " available" })
        end))
        table.insert(app_handles, C.updater.on_countdown(function(version, secs)
            show_toast({ source = "update", severity = "alert",
                         text = "installing v" .. tostring(version) .. " in "
                                .. tostring(secs) .. "s -- press any key to cancel" })
        end))
    end

    build()
end

function app.stop()
    if not started then return end
    started = false
    teardown()
    for _, h in ipairs(app_handles) do h.cancel() end
    app_handles = {}
end

-- test support
function app.surface_count() return #surfaces end

-- test accessor: the terminal surface's DisplayBox (for handle_right_click/mouse)
function app.terminal_display()
    for _, s in ipairs(surfaces) do
        if s.kind == "terminal" then return s.display end
    end
end

return app
