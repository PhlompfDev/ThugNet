-- Events page: the unified feed. Severity-colored rows with in-game
-- timestamps, source filter, clear, live append. Replaces v1's three
-- separate service logs.
local ui = require("graphics.ui")
local widgets = require("thugnet.ui.widgets")

-- filter buttons: the high-traffic sources only (scenes/automation/ui events
-- still appear under "all"; dedicated buttons for them cost more width than
-- they were worth — owner call, 2026-07-22)
local SOURCES = { "all", "dns", "server", "client" }

return {
    id = "events",
    name = "Events",
    category = "overview",
    min_w = 26,
    min_h = 8,
    build = function(content, ui_ctx)
        local theme = ui_ctx.theme
        local w, h = content.window().getSize()
        local filter = nil   -- nil = all

        -- header rule stops short of the Clear button instead of running
        -- underneath it
        local y = widgets.section(content, 2, 1, w - 11, "EVENT FEED", theme)

        -- filter strip: one toggle button per source, flowed onto as many
        -- rows as the width allows. A single-row MultiButton pads every
        -- option to the widest label, so on a terminal the strip ran far
        -- past the right edge and buried the later sources.
        local avail = w - 2
        local function strip_rows()
            local rows, px = 1, 1
            for _, s in ipairs(SOURCES) do
                local bw = #s + 2
                if px > 1 and (px + bw - 1) > avail then rows = rows + 1; px = 1 end
                px = px + bw + 1
            end
            return rows
        end
        local n_rows = strip_rows()
        local strip = ui.Div{ parent = content, x = 2, y = y, width = avail, height = n_rows,
                              fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }

        -- a breathing row between the strip and the feed when there is room
        local list_y = y + n_rows + ((h - (y + n_rows)) >= 8 and 1 or 0)
        local list = ui.ListBox{
            parent = content, x = 2, y = list_y, width = w - 2, height = h - list_y,
            scroll_height = 200,
            fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg),
            nav_fg_bg = ui.cpair(theme.tokens.raised, theme.tokens.bg),
            nav_active = ui.cpair(theme.tokens.accent, theme.tokens.bg),
        }

        local function sev_color(sev)
            return theme.severity[sev] or theme.tokens.dim
        end

        -- "d3 14:20" from the in-game day + hour-of-day captured at log time;
        -- entries persisted before timestamps existed simply have no prefix
        local function when(e)
            if not (e.t_day and e.t_ig) then return "" end
            return (" d%d %02d:%02d"):format(e.t_day,
                math.floor(e.t_ig), math.floor((e.t_ig % 1) * 60))
        end

        local function add_row(e)
            ui.TextBox{
                parent = list, height = 1,
                text = ("%s%s %s: %s"):format(
                    e.severity == "alert" and "!" or (e.severity == "warn" and "\x13" or "\x07"),
                    when(e), e.source, e.text),
                fg_bg = ui.cpair(sev_color(e.severity), theme.tokens.bg),
                alignment = ui.ALIGN.LEFT,
            }
        end

        local function refill()
            list.remove_all()
            for _, e in ipairs(ui_ctx.events.list(filter and { source = filter } or nil)) do
                add_row(e)
            end
            -- full repaint: removing rows alone leaves stale characters
            -- behind (the v1 hide()-doesn't-clear gotcha)
            list.redraw()
        end

        local rebuild_strip
        rebuild_strip = function()
            strip.remove_all()
            local px, py = 1, 1
            for _, s in ipairs(SOURCES) do
                local src = s
                local bw = #s + 2
                if px > 1 and (px + bw - 1) > avail then py = py + 1; px = 1 end
                local is_active = (filter == src) or (filter == nil and src == "all")
                ui.PushButton{
                    parent = strip, x = px, y = py, width = bw, text = s,
                    fg_bg = is_active and ui.cpair(theme.tokens.bg, theme.tokens.accent)
                                       or ui.cpair(theme.tokens.dim, theme.tokens.raised),
                    active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                    callback = function()
                        filter = src ~= "all" and src or nil
                        rebuild_strip()
                        refill()
                    end,
                }
                px = px + bw + 1
            end
            strip.redraw()
        end
        rebuild_strip()

        -- Clear lives on the header row so it can never cover the filters
        ui.PushButton{
            parent = content, x = w - 8, y = 1, width = 7, text = "Clear",
            fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.raised),
            active_fg_bg = ui.cpair(theme.tokens.text, theme.tokens.alert),
            callback = function()
                ui_ctx.events.clear()
                refill()
            end,
        }

        refill()

        -- live append (owned: unhooked on page teardown)
        ui_ctx.own(ui_ctx.events.on_log(function(e)
            if filter == nil or e.source == filter then add_row(e) end
        end))
    end,
}
