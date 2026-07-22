-- Headless front panel. Nodes without the ui role used to print one line and go
-- silent -- indistinguishable from a hang. This paints a live status surface:
-- one heartbeat LED per connection that BLINKS while its subject is alive and
-- goes SOLID RED when it is down, so three states read at a glance --
--   pulsing   = alive (and the panel's own redraw loop is proven alive)
--   solid red = the subject is down
--   frozen    = the panel itself has hung
-- plus a live status line derived from the current accessors (never the event
-- log -- Phase 8 fixed a stale "DNS link lost" that never cleared) and a
-- hardware box (FW / NET / SN).
--
-- Values refresh by recolor+set_value on a 1s kernel timer -- the tree is built
-- once and never rebuilt (the v1 leak lesson). Blinking is the tick parity, not
-- the flasher, so a frozen node visibly stops pulsing.
local ui      = require("graphics.ui")
local theme   = require("thugnet.ui.theme")
local version = require("thugnet.version")

local panel = {}

---@param ctx table { kernel, config, dns?, server?, client? }
---@return table handle { destroy }
function panel.start(ctx)
    local target = term.current()
    local w, h = target.getSize()
    theme.apply(target)

    local roles = ctx.config.roles or {}
    -- a dns host shows its own heartbeat + a roster of registered domains; a
    -- server/client shows a DNS-link heartbeat; a server also shows a heartbeat
    -- for its own hosted domain. Both role branches render independently, and an
    -- all-in-one dns+server node (no ui) shows both.
    local show_dns_hb    = roles.dns == true and ctx.dns ~= nil        -- DNS heartbeat + roster
    local show_link_hb   = (not show_dns_hb) and (ctx.server ~= nil or ctx.client ~= nil)
    local show_domain_hb = roles.server == true and ctx.server ~= nil

    local roster_names = {}
    if show_dns_hb then
        for d in pairs(ctx.dns.get_domains() or {}) do roster_names[#roster_names + 1] = d end
        table.sort(roster_names)
    end

    -- size guard: count the SAME predicates the layout stacks (Phase 7 lesson --
    -- a blanket height minimum accepted a turtle whose column overflowed and
    -- died on the frame assert). The status column owns h-6 rows (title 2 top;
    -- status line + blank + hardware = 4 bottom). Fixed heartbeats stack first,
    -- then the roster, reserving one row for a "...+N more" tail when it can't
    -- all fit.
    local avail = h - 6
    local fixed = (show_domain_hb and 1 or 0) + (show_dns_hb and 1 or 0)
        + (show_link_hb and 1 or 0)
    local roster_room = avail - fixed
    local roster_shown, roster_overflow
    if #roster_names <= roster_room then
        roster_shown, roster_overflow = #roster_names, false
    else
        roster_shown, roster_overflow = math.max(0, roster_room - 1), true
    end
    local col_rows = fixed + roster_shown + (roster_overflow and 1 or 0)
    if w < 20 or col_rows == 0 or roster_room < 0 or h < col_rows + 6 then
        target.clear()
        target.setCursorPos(1, 1)
        target.write("ThugNet " .. ctx.config.label)
        target.setCursorPos(1, 2)
        target.write("v" .. version .. " headless")
        return { destroy = function() end }
    end

    local display = ui.DisplayBox{ window = target, fg_bg = theme.fg_bg("text", "bg") }

    -- title bar
    ui.TextBox{ parent = display, x = 1, y = 1, width = w, height = 1,
                text = "", fg_bg = theme.fg_bg("text", "panel") }
    ui.TextBox{ parent = display, x = 2, y = 1, width = 10, height = 1,
                text = "\x07 THUGNET", fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.panel) }
    ui.TextBox{ parent = display, x = 13, y = 1,
                width = math.max(1, math.min(#ctx.config.label, w - 13)), height = 1,
                text = ctx.config.label, fg_bg = theme.fg_bg("dim", "panel") }

    -- status column: heartbeat LEDs auto-stack, one per line
    local col_w = math.min(20, w - 2)
    local col = ui.Div{ parent = display, x = 2, y = 3, width = col_w, height = avail }

    -- every heartbeat starts green; recolor flips it to solid red when down.
    -- on = ok_bright over the panel bg, so the "off" half of the blink reads dark
    local hb_green = ui.cpair(theme.tokens.ok_bright, theme.tokens.bg)
    local hb_red   = ui.cpair(theme.tokens.alert, theme.tokens.alert)

    local domain_hb = show_domain_hb and ui.LED{ parent = col,
        label = tostring(ctx.server.get_domain() or "DOMAIN"):upper():sub(1, col_w - 2),
        colors = hb_green } or nil
    local dns_hb = (show_dns_hb or show_link_hb) and ui.LED{ parent = col,
        label = "DNS", colors = hb_green } or nil
    local roster_leds = {}
    for i = 1, roster_shown do
        roster_leds[i] = ui.LED{ parent = col,
            label = tostring(roster_names[i]):sub(1, col_w - 2), colors = hb_green }
    end
    if roster_overflow then
        ui.TextBox{ parent = col, width = col_w, height = 1,
            text = ("...+%d more"):format(#roster_names - roster_shown),
            fg_bg = theme.fg_bg("dim", "bg") }
    end

    -- live status line (replaces the event-log scrape): recomputed every tick
    -- from the accessors, so it clears itself the instant the link recovers.
    local status_tb = ui.TextBox{ parent = display, x = 2, y = h - 3, width = w - 2, height = 1,
        text = "", fg_bg = theme.fg_bg("warn", "bg") }

    -- hardware box: version / protocol / serial (single-source constants)
    ui.TextBox{ parent = display, x = 2, y = h - 1, width = w - 2, height = 1,
        text = ("FW v%s  NET thugnet2  SN %04d"):format(version, os.getComputerID()),
        fg_bg = theme.fg_bg("dim", "bg") }

    local blink = false
    -- flip one heartbeat: a green/dark pulse while alive, solid red while down
    local function beat(led, alive)
        if alive then led.recolor(hb_green); led.set_value(blink)
        else led.recolor(hb_red); led.set_value(true) end
    end
    local function refresh()
        blink = not blink
        -- the status line reports link/domain liveness only (the spec's "a shown
        -- connection is down"); a stopped local server shows via its own
        -- <DOMAIN> LED going red, not via this line.
        local down = false
        if domain_hb then beat(domain_hb, ctx.server.is_active() == true) end
        if dns_hb then
            local ok
            if show_dns_hb then ok = ctx.dns.is_active() == true
            else ok = (ctx.server and ctx.server.dns_ok()) or (ctx.client and ctx.client.dns_ok()) end
            ok = ok == true
            if not ok then down = true end
            beat(dns_hb, ok)
        end
        for i = 1, roster_shown do
            local a = ctx.dns.is_alive(roster_names[i]) == true
            if not a then down = true end
            beat(roster_leds[i], a)
        end
        status_tb.set_value(down and (show_dns_hb and "domain down" or "DNS link down") or "")
    end

    refresh()
    local timer = ctx.kernel.every(1, refresh)

    return {
        destroy = function()
            timer.cancel()
            display.delete()
        end,
    }
end

return panel
