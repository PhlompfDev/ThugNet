-- Feature Request page: file a request into the public ThugNet-Requests
-- inbox from inside the game. Reached from Settings > Updates; hidden from
-- the sidebar. Pure UI -- all GitHub I/O lives in core/requests.lua.
local ui = require("graphics.ui")
local widgets = require("thugnet.ui.widgets")
local requests = require("thugnet.core.requests")
local config_mod = require("thugnet.config")

return {
    id = "feature_request",
    name = "Feature Request",
    category = "system",
    min_w = 26,
    min_h = 12,
    requires_role = "ui",
    hidden = true,
    build = function(content, ui_ctx)
        local theme = ui_ctx.theme
        local w, h = content.window().getSize()

        local y = widgets.section(content, 2, 1, w - 2, "FEATURE REQUEST", theme)

        local hint = ui.TextBox{
            parent = content, x = 2, y = h, width = w - 3, height = 1, text = "",
            fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
        local function say(msg) hint.set_value(msg) end

        local field_fg = ui.cpair(theme.tokens.text, theme.tokens.raised)

        ui.TextBox{ parent = content, x = 2, y = y, width = w - 3, height = 1,
            text = "Title:", fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
        local f_title = ui.TextField{ parent = content, x = 2, y = y + 1,
            width = w - 3, max_len = 60, fg_bg = field_fg }

        ui.TextBox{ parent = content, x = 2, y = y + 3, width = w - 3, height = 1,
            text = "Requested change:", fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
        -- one long field that scrolls horizontally (ifield frame-shifts once
        -- the value outgrows the visible width)
        local f_body = ui.TextField{ parent = content, x = 2, y = y + 4,
            width = w - 3, max_len = 300, fg_bg = field_fg }

        -- Sending is async; this page can be torn down (nav away, rebuild)
        -- before the callback lands. Touching dead elements from a live
        -- callback is the domain-tile lesson all over again -- gate on a
        -- liveness flag released in the own() teardown.
        local alive = true
        ui_ctx.own({ cancel = function() alive = false end })

        local function on_send()
            if not requests.has_token() then
                return say("set a github token first (Set Token...)")
            end
            local title = requests.clean_title(f_title.get_value())
            if title == "" then return say("give the request a title") end
            say("sending...")
            requests.submit(title, f_body.get_value(), function(ok, err)
                if not alive then return end
                if ok then
                    f_title.set_value("")
                    f_body.set_value("")
                    say("sent! the agent picks it up within ~5 min")
                else
                    say(tostring(err or "send failed"))
                end
            end)
        end

        -- The write path needs a fine-grained PAT (the requests repo only,
        -- contents read/write). It lives in config.json -- runtime state the
        -- updater never ships or overwrites -- and is entered once via the
        -- prompt (paste works: app.lua routes paste events to the prompt).
        local function on_token()
            ui_ctx.prompt("GitHub token (paste it)", "", function(v)
                if v == nil or v == "" then return end
                local cfg = ui_ctx.config
                cfg.requests_token = v
                config_mod.save(cfg)
                say("token saved")
                if ui_ctx.request_rebuild then ui_ctx.request_rebuild() end
            end)
        end

        -- Buttons flow onto wrapped rows: a single fixed-offset row is only
        -- safe when the labels provably fit the narrowest parent (the Events
        -- page overflow lesson), and this page must hold up on a pocket.
        local token_label = requests.has_token() and "Change Token" or "Set Token..."
        local defs = {
            { text = "Send Request",  cb = on_send },
            { text = "Sent Requests", cb = function() ui_ctx.nav_to("sent_requests") end },
            { text = token_label,     cb = on_token, dimmed = true },
            { text = "Back",          cb = function() ui_ctx.nav_to("settings") end },
        }
        local bx, by = 2, y + 6
        for _, d in ipairs(defs) do
            local bw = #d.text + 2
            if bx > 2 and bx + bw - 1 > w - 2 then bx = 2; by = by + 1 end
            ui.PushButton{
                parent = content, x = bx, y = by, width = bw, text = d.text,
                fg_bg = ui.cpair(d.dimmed and theme.tokens.dim or theme.tokens.text,
                                 theme.tokens.raised),
                active_fg_bg = ui.cpair(theme.tokens.bg, theme.tokens.accent),
                callback = d.cb,
            }
            bx = bx + bw + 1
        end

        if not requests.has_token() then
            say("no github token set -- Set Token... first")
        end
    end,
}
