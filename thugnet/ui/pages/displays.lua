-- Displays page: per-monitor zone layout + page assignment. Persists to
-- displays.json (read by app.lua's build_monitor_surface). Spec §7 Displays.
local ui = require("graphics.ui")
local widgets = require("thugnet.ui.widgets")
local menus = require("thugnet.ui.menus")
local nav = require("thugnet.ui.nav")

local DISPLAYS_PATH = "displays.json"
local PRESETS = {
    { text = "Full",    rows = 1, cols = 1 },
    { text = "Split-H", rows = 2, cols = 1 },
    { text = "Split-V", rows = 1, cols = 2 },
    { text = "Quad",    rows = 2, cols = 2 },
}

local function monitor_list()
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            local w, h = peripheral.wrap(name).getSize()
            out[#out + 1] = { name = name, w = w, h = h }
        end
    end
    return out
end

return {
    id = "displays",
    name = "Displays",
    category = "telemetry",
    min_w = 26,
    min_h = 8,
    requires_monitor = true,
    build = function(content, ui_ctx)
        local theme = ui_ctx.theme
        local store = ui_ctx.store
        local w, h = content.window().getSize()

        local function load_all() return store.load(DISPLAYS_PATH, {}) end
        local function cfg_for(name)
            local all = load_all()
            return all[name] or { text_scale = 1.0, zones = { rows = 1, cols = 1 }, pages = { "follow" } }
        end
        local function save_for(name, cfg)
            local all = load_all()
            all[name] = cfg
            store.save(DISPLAYS_PATH, all)
            if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
        end
        local function set_zones(name, rows, cols)
            local cfg = cfg_for(name)
            cfg.zones = { rows = rows, cols = cols }
            local n = rows * cols
            cfg.pages = cfg.pages or {}
            for i = 1, n do cfg.pages[i] = cfg.pages[i] or "follow" end
            while #cfg.pages > n do table.remove(cfg.pages) end
            save_for(name, cfg)
        end

        local list = ui.ListBox{
            parent = content, x = 2, y = 1, width = w - 2, height = h,
            scroll_height = 120,
            fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg),
            nav_fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg),
            nav_active = ui.cpair(theme.tokens.accent, theme.tokens.bg),
        }

        local mons = monitor_list()
        if #mons == 0 then
            ui.TextBox{ parent = list, height = 1, text = "(no monitors attached)",
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
            return
        end

        for _, mon in ipairs(mons) do
            local name = mon.name
            local cfg = cfg_for(name)
            widgets.section(list, 1, 1, w - 3, name .. "  " .. mon.w .. "x" .. mon.h, theme)

            -- preset buttons, flowed onto as many rows as the zone width needs. A narrow
            -- zone (e.g. Quad on a 71x33 monitor) can't fit all five on one line, and a
            -- button placed past the parent's right edge gets a frame width <= 0.
            local buttons = {}
            for _, p in ipairs(PRESETS) do
                buttons[#buttons + 1] = { text = p.text,
                    callback = function() set_zones(name, p.rows, p.cols) end }
            end
            buttons[#buttons + 1] = { text = "Custom", callback = function()
                ui_ctx.prompt("Rows", tostring(cfg.zones.rows), function(rs)
                    local r = tonumber(rs); if not r or r < 1 then return end
                    ui_ctx.prompt("Cols", tostring(cfg.zones.cols), function(cs)
                        local c = tonumber(cs); if not c or c < 1 then return end
                        set_zones(name, math.floor(r), math.floor(c))
                    end)
                end)
            end }

            -- list reserves its rightmost column for the scroll bar
            local avail = math.max(1, w - 3)
            local bi = 1
            while bi <= #buttons do
                local prow = ui.Div{ parent = list, height = 1,
                                     fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
                local px = 1
                repeat
                    local b = buttons[bi]
                    local bw = #b.text + 2
                    -- wrap to the next row once this button would overflow, but always
                    -- place at least one button per row so the loop can't stall
                    if px > 1 and (px + bw - 1) > avail then break end
                    ui.PushButton{ parent = prow, x = px, y = 1,
                        width = math.max(1, math.min(bw, avail - px + 1)), text = b.text,
                        fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.raised),
                        active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                        callback = b.callback }
                    px = px + bw + 1
                    bi = bi + 1
                until bi > #buttons
            end

            -- Zones default to "follow", so an untouched monitor just mirrors the
            -- terminal and looks like the preset did nothing. Nothing else on screen
            -- says the rows are right-clickable, so say it.
            local hint = "  right-click a zone to assign"
            ui.TextBox{ parent = list, height = 1,
                text = #hint <= (w - 3) and hint or "  right-click a zone",
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }

            -- zone rows
            local assignable = nav.pages({ config = ui_ctx.config, has_monitor = true })
            local zi = 0
            for r = 1, cfg.zones.rows do
                for c = 1, cfg.zones.cols do
                    zi = zi + 1
                    local idx = zi
                    local pageid = (cfg.pages or {})[idx] or "follow"
                    local zrow = ui.TextBox{ parent = list, height = 1,
                        text = ("  Z%d r%dc%d: %s"):format(idx, r, c, pageid),
                        fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
                    zrow.set_right_click_handler(function()
                        ui_ctx.menu(menus.zone_menu{
                            assign_page = function()
                                local sub = {}
                                for _, def in ipairs(assignable) do
                                    local id = def.id
                                    sub[#sub + 1] = { text = def.name, callback = function()
                                        local cur = cfg_for(name)
                                        cur.pages[idx] = id; save_for(name, cur)
                                    end }
                                end
                                if #sub == 0 then
                                    sub[1] = { text = "(no pages)", callback = function() end }
                                end
                                ui_ctx.menu(sub)
                            end,
                            follow = function()
                                local cur = cfg_for(name); cur.pages[idx] = "follow"; save_for(name, cur)
                            end,
                            clear = function()
                                local cur = cfg_for(name); cur.pages[idx] = "none"; save_for(name, cur)
                            end,
                        })
                        return true
                    end)
                end
            end
        end
    end,
}
