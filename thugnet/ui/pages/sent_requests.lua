-- Sent Requests page: every feature request filed from this node, with the
-- status the agent loop last published for it. Statuses come from the public
-- inbox's receipt lines (read anonymously -- no token needed to look).
-- Hidden from the sidebar; reached from the Feature Request page.
local ui = require("graphics.ui")
local widgets = require("thugnet.ui.widgets")
local requests = require("thugnet.core.requests")

-- status -> theme token. Every legal state/NNN.json status gets an explicit
-- entry; anything unknown renders dim rather than crashing or lying.
local STATUS_FG = {
    sent        = "dim",     -- submitted, not yet seen in the inbox
    waiting     = "dim",     -- still above the --- rule, not picked up yet
    queued      = "info",
    in_progress = "info",
    review      = "info",
    soaking     = "info",
    blocked     = "warn",    -- the worker asked a question; needs the owner
    failed      = "alert",
    rejected    = "accent2",
    shipped     = "ok",
}

return {
    id = "sent_requests",
    name = "Sent Requests",
    category = "system",
    min_w = 26,
    min_h = 12,
    requires_role = "ui",
    hidden = true,
    build = function(content, ui_ctx)
        local theme = ui_ctx.theme
        local w, h = content.window().getSize()

        local y = widgets.section(content, 2, 1, w - 2, "SENT REQUESTS", theme)

        local hint = ui.TextBox{
            parent = content, x = 2, y = h, width = w - 3, height = 1, text = "",
            fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
        local function say(msg) hint.set_value(msg) end

        -- rows live in one Div refilled in place (house rule: page-local
        -- refresh = refill a container, never re-set the active page).
        -- Two rows above the hint are reserved for the button strip, which
        -- flows onto a second row on narrow parents (Events-page lesson).
        local list_h = h - y - 3
        local list = ui.Div{ parent = content, x = 2, y = y, width = w - 3,
                             height = list_h }

        local function refill()
            list.remove_all()
            local recs = requests.list()
            if #recs == 0 then
                ui.TextBox{ parent = list, x = 1, y = 1, width = w - 5, height = 2,
                    text = "Nothing sent from this node yet.",
                    fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
            else
                -- newest first; one row per record, capped at the list height
                local row = 1
                for i = #recs, 1, -1 do
                    if row > list_h then break end
                    local rec = recs[i]
                    local status = tostring(rec.status or "sent")
                    local tag = status
                    if rec.id then tag = ("#%03d %s"):format(rec.id, status) end
                    if rec.version then tag = tag .. " v" .. rec.version end
                    local fg = STATUS_FG[status] or "dim"
                    local tag_w = math.min(#tag, w - 7)
                    ui.TextBox{ parent = list, x = 1, y = row, width = tag_w,
                        height = 1, text = tag,
                        fg_bg = ui.cpair(theme.tokens[fg], theme.tokens.bg) }
                    local tx = tag_w + 2
                    if tx < w - 5 then
                        ui.TextBox{ parent = list, x = tx, y = row,
                            width = w - 5 - tx + 1, height = 1,
                            text = tostring(rec.title or "?"),
                            fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
                    end
                    row = row + 1
                end
            end
            list.redraw()
        end

        -- refresh() is async; the page may be gone before the inbox answers
        local alive = true
        ui_ctx.own({ cancel = function() alive = false end })

        local function do_refresh()
            say("checking the inbox...")
            requests.refresh(function(ok, err)
                if not alive then return end
                if ok then
                    refill()
                    say("statuses up to date")
                else
                    say(tostring(err or "refresh failed"))
                end
            end)
        end

        local defs = {
            { text = "Refresh",     cb = do_refresh },
            { text = "New Request", cb = function() ui_ctx.nav_to("feature_request") end },
            { text = "Back",        cb = function() ui_ctx.nav_to("settings") end },
        }
        local bx, by = 2, h - 3
        for _, d in ipairs(defs) do
            local bw = #d.text + 2
            if bx > 2 and bx + bw - 1 > w - 2 then bx = 2; by = by + 1 end
            ui.PushButton{
                parent = content, x = bx, y = by, width = bw, text = d.text,
                fg_bg = ui.cpair(theme.tokens.text, theme.tokens.raised),
                active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                callback = d.cb,
            }
            bx = bx + bw + 1
        end

        refill()
        -- kick a refresh on open so the list is honest without a click
        do_refresh()
    end,
}
