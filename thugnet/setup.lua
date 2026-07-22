-- First-boot setup wizard (cc-mek-scada lesson: unconfigured == validation
-- failure, and validation failure launches the configurator — one path covers
-- fresh nodes, corrupt configs, and upgrades that add required fields; never
-- a blank screen). Plain-terminal prompts, deliberately not the graphics
-- toolkit: this runs pre-kernel, asks five questions, and must work on any
-- node including headless servers.
local config = require("thugnet.config")

local setup = {}

-- Does this boot need the wizard? Absent file or invalid content — both,
-- because a hand-edited typo must route here rather than half-boot.
function setup.needed()
    if not config.exists() then return true end
    local ok = config.validate(config.load())
    return not ok
end

-- The provisioning seed for the server service: config.json's server_domain
-- names the domain ONLY until server_config2.json exists — after that the
-- live file owns the name (Rename edits it), and re-seeding on every boot
-- would silently revert an in-game rename.
---@param cfg table a loaded config
---@return string|nil domain to pass to server.start
function setup.server_seed(cfg)
    if cfg.roles and cfg.roles.server and not fs.exists("server_config2.json") then
        return cfg.server_domain
    end
    return nil
end

local function yes(answer, default)
    answer = tostring(answer or ""):lower()
    if answer == "" then return default end
    return answer:sub(1, 1) == "y"
end

-- Write a configuration from wizard answers. The single owner of config-write
-- semantics, so the plain-terminal wizard and the graphical one (ui/setup_ui)
-- cannot diverge: merge answers into the existing file (automation,
-- text_scale and anything future survive a re-provision), reset any
-- corrupt NON-asked field to its default so the wizard's own validate pass
-- can't be trapped in a loop, save, and return the loaded, defaults-applied cfg.
---@param answers table { label:string, roles:table, domain?:string }
---@param existing table|nil the current config, or nil on a fresh node
---@return table cfg
function setup.commit(answers, existing)
    local out = existing or {}
    out.label, out.roles, out.server_domain = answers.label, answers.roles, answers.domain
    if out.theme ~= "dark" then out.theme = nil end
    if type(out.text_scale) ~= "number"
        or out.text_scale < 0.5 or out.text_scale > 5 then
        out.text_scale = nil
    end
    if type(out.automation) ~= "boolean" then out.automation = nil end
    config.save(out)
    return config.load()
end

-- Run the wizard. `io` is injectable for tests:
--   io.print(line)
--   io.ask(question, default) -> string  (empty answer means the default)
-- Loops until a configuration is confirmed and saved — a node can leave this
-- function provisioned or not at all.
---@param io table { print, ask }
---@return table cfg the saved, defaults-applied configuration
function setup.run(io)
    -- re-provisioning an existing node: every prompt prefills the current
    -- value (an operator pressing Enter through the wizard changes NOTHING),
    -- and fields the wizard doesn't ask about are preserved, not reset
    local existing = config.exists() and config.load() or nil
    local ex_roles = (existing and existing.roles) or {}
    if existing then
        local ok, problems = config.validate(existing)
        if not ok then
            io.print("The saved config.json is not valid:")
            for _, p in ipairs(problems) do io.print("  problem: " .. p) end
            io.print("")
        end
    end
    -- a migrated/live server config owns the real domain name -- prefill it
    -- so Enter keeps it and config.json records the truth
    local live_domain = require("thugnet.core.store")
        .load("server_config2.json", {}).domain

    while true do
        io.print("ThugNet v" .. require("thugnet.version") .. " setup")
        io.print("This computer is not configured yet. A few questions:")
        io.print("")

        local label = io.ask("Computer label",
            (existing and existing.label) or ("node-" .. os.getComputerID()))
        local roles = {}
        if yes(io.ask("Host the DNS name server? (one per network)",
                      ex_roles.dns and "y" or "n"), false) then
            roles.dns = true
        end
        local domain
        if yes(io.ask("Host a domain? (control redstone here)",
                      ex_roles.server and "y" or "n"), false) then
            roles.server = true
            domain = (existing and existing.server_domain) or live_domain
            repeat
                domain = io.ask("Domain name", domain or "")
            until domain ~= nil and domain ~= ""
        end
        if yes(io.ask("Run the control-panel UI on this computer?",
                      ex_roles.ui and "y" or "n"), false) then
            roles.ui = true
        end

        if next(roles) == nil then
            io.print("")
            io.print("A node with no roles does nothing - pick at least one.")
            io.print("")
        else
            io.print("")
            io.print("  label:  " .. label)
            local names = {}
            for role in pairs(roles) do table.insert(names, role) end
            table.sort(names)
            io.print("  roles:  " .. table.concat(names, ", "))
            if domain then io.print("  domain: " .. domain) end
            io.print("")
            if yes(io.ask("Save this configuration?", "y"), true) then
                local cfg = setup.commit({ label = label, roles = roles, domain = domain }, existing)
                local ok, problems = config.validate(cfg)
                if ok then
                    io.print("Saved. Booting ThugNet...")
                    return cfg
                end
                -- should be unreachable (commit can only author valid shapes)
                -- but never boot on an invalid config regardless
                for _, p in ipairs(problems) do io.print("problem: " .. p) end
            end
        end
    end
end

-- The real terminal io, used by startup.lua and the root setup.lua program.
function setup.term_io()
    return {
        print = print,
        ask = function(question, default)
            if default ~= nil and default ~= "" then
                io.write(question .. " [" .. default .. "]: ")
            else
                io.write(question .. ": ")
            end
            local answer = read()
            if answer == nil or answer == "" then return default or "" end
            return answer
        end,
    }
end

-- Pick the front-end and run it: the graphical wizard (ui/setup_ui) when the
-- terminal is color AND at least the wizard's minimum size, else the plain
-- terminal wizard. Both save through setup.commit, so the outcome is identical
-- -- only the UX differs. Read the size/color off term.current(): the global
-- `term` API lacks getSize/isColor under the offline harness, current() has both.
---@return table cfg the saved, defaults-applied configuration
function setup.provision()
    local setup_ui = require("thugnet.ui.setup_ui")
    local t = term.current()
    local ok_color = type(t.isColor) == "function" and t.isColor()
    local w, h = t.getSize()
    if ok_color and w >= setup_ui.MIN_W and h >= setup_ui.MIN_H then
        return setup_ui.run()
    end
    return setup.run(setup.term_io())
end

return setup
