-- Dashboard: system health chips + live domain tile grid with the shared
-- §8 domain context menu per tile.
local ui = require("graphics.ui")
local widgets = require("thugnet.ui.widgets")
local kit = require("thugnet.ui.kit")
local menus = require("thugnet.ui.menus")

local TILE_W, TILE_H = 24, 4
local TILE_GAP = 1

return {
    id = "dashboard",
    name = "Home",
    category = "overview",
    min_w = 26,
    min_h = 10,
    build = function(content, ui_ctx)
        local theme = ui_ctx.theme
        local w, h = content.window().getSize()

        local y = widgets.section(content, 2, 1, w - 2, "SYSTEM", theme)
        local x = 2
        -- DNS + Server are live-heartbeat dots (pulse green up / solid red down),
        -- reading the ACTUAL service state, not static roles. Auto is a config
        -- authority flag, not a connection, so it stays a steady chip.
        local dns_dot = widgets.pulse_dot(content, x, y, "DNS", theme); x = x + dns_dot.width + 2
        local srv_dot = widgets.pulse_dot(content, x, y, "Server", theme); x = x + srv_dot.width + 2
        local auto_chip = widgets.chip(content, x, y, "Auto", theme)

        local roles = ui_ctx.config.roles or {}
        -- a DNS host reports its own service; anyone else reports the client's
        -- link. A node with neither shows the dot inert.
        local function dns_state()
            if ui_ctx.dns and roles.dns then
                return ui_ctx.dns.is_active() and "up" or "down"
            elseif ui_ctx.client then
                return ui_ctx.client.dns_ok() and "up" or "down"
            end
            return "off"
        end
        -- the server dot follows whether THIS node's server is actually running
        -- -- stopping it turns the dot red, which reading roles.server never did
        local function srv_state()
            if ui_ctx.server and roles.server then
                return ui_ctx.server.is_active() and "up" or "down"
            end
            return "off"
        end

        local phase = false
        local function refresh_chips()
            phase = not phase
            dns_dot.beat(dns_state(), phase)
            srv_dot.beat(srv_state(), phase)
            auto_chip.set(ui_ctx.config.automation and "ok" or "off")
        end
        refresh_chips()
        -- one shared 1s heartbeat drives the pulse AND polls up/down state
        -- (the front-panel pattern) so the dots can never sit stale-green
        ui_ctx.own(ui_ctx.kernel.every(1, refresh_chips))

        local dy = widgets.section(content, 2, y + 2, w - 2, "DOMAINS", theme)

        -- tiles live in their own container so the grid can refill in place
        -- when domains appear or disappear — no page switch, no app rebuild
        -- (the last content row is reserved for the send-status line)
        local grid = ui.Div{ parent = content, x = 1, y = dy + 1, width = w,
                             height = math.max(1, h - dy - 1),
                             fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
        local grid_h = math.max(1, h - dy - 1)

        -- immediate feedback for tile-menu sends: sending… / ok / error
        local status = ui.TextBox{ parent = content, x = 2, y = h, width = w - 2, height = 1,
                                   text = "", fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
        ui_ctx.notify_send = function(cmd, domain, ok, err)
            if ok == nil then
                status.set_value(("sending %s -> %s..."):format(cmd, domain))
            elseif ok then
                status.set_value(("%s -> %s: ok"):format(cmd, domain))
            else
                status.set_value(("%s -> %s: %s"):format(cmd, domain, tostring(err)))
            end
        end

        local tiles = {}   -- domain name -> tile

        local function layout_tiles()
            tiles = {}
            local names = ui_ctx.client and ui_ctx.client.get_domains() or {}
            if #names == 0 then
                kit.empty(grid, kit.icons.domain, "No domains on the network yet.", theme)
                return
            end
            local cols = math.max(1, math.floor((w - 2) / (TILE_W + TILE_GAP)))
            for i, name in ipairs(names) do
                local col = (i - 1) % cols
                local row = math.floor((i - 1) / cols)
                local ty = 1 + row * (TILE_H + TILE_GAP)
                if ty + TILE_H - 1 <= grid_h then
                    local info = ui_ctx.client.get(name)
                    local dom = name
                    tiles[name] = widgets.domain_tile(grid,
                        2 + col * (TILE_W + TILE_GAP), ty, TILE_W, TILE_H, ui_ctx, {
                            name = name, alive = info.alive,
                            commands = info.commands, sensors = info.sensors,
                            on_menu = function()
                                ui_ctx.menu(menus.domain_menu(ui_ctx, dom))
                            end,
                        })
                end
            end
        end

        local function refill()
            grid.remove_all()
            layout_tiles()
            grid.redraw()
        end

        layout_tiles()

        -- live updates: alive/state/commands changes update known tiles in
        -- place; anything structural (snapshot, removal, a domain the grid
        -- doesn't have a tile for — e.g. one that re-registered after being
        -- removed) refills the grid in place
        if ui_ctx.client then
            ui_ctx.own(ui_ctx.client.on_change(function(kind, domain)
                local in_place = kind == "up" or kind == "down"
                              or kind == "state" or kind == "commands"
                if in_place then
                    local tile = domain and tiles[domain]
                    local info = domain and ui_ctx.client.get(domain)
                    if tile and info then
                        tile.update({ name = domain, alive = info.alive,
                                      commands = info.commands, sensors = info.sensors })
                    else
                        refill()
                    end
                elseif kind == "snapshot" or kind == "removed" then
                    refill()
                end
            end))
        end
    end,
}
