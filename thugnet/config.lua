-- Per-computer configuration with defaults.
local store = require("thugnet.core.store")

local config = {}

local PATH = "config.json"

local function defaults()
    return {
        label = "node-" .. os.getComputerID(),
        roles = {},
        theme = "dark",
        text_scale = 1.0,
        automation = false,
    }
end

function config.load()
    local cfg = store.load(PATH, {})
    for k, v in pairs(defaults()) do
        if cfg[k] == nil then cfg[k] = v end
    end
    return cfg
end

function config.exists()
    return fs.exists(PATH)
end

local ROLES = { dns = true, server = true, client = true, ui = true }

-- Validate a defaults-applied config. Defaults are the migration mechanism
-- (a new optional field can never fail here), so everything this rejects is a
-- genuine provisioning problem: the unprovisioned zero-roles state, a typo'd
-- hand edit, or a server node with no domain to host. Messages are meant for
-- the person at the terminal — name the field and say what to do.
---@param cfg table a config.load()-shaped table
---@return boolean ok, string[] problems
function config.validate(cfg)
    local problems = {}
    local function bad(msg) table.insert(problems, msg) end

    if type(cfg.label) ~= "string" or cfg.label == "" then
        bad("label must be a non-empty string")
    end

    if type(cfg.roles) ~= "table" then
        bad("roles must be a table of role = true entries")
    else
        local enabled = 0
        for role, on in pairs(cfg.roles) do
            if not ROLES[role] then
                bad(("unknown role %q (valid: dns, server, client, ui)"):format(tostring(role)))
            elseif type(on) ~= "boolean" then
                bad(("role %s must be true or false"):format(tostring(role)))
            elseif on then
                enabled = enabled + 1
            end
        end
        if enabled == 0 then
            bad("no roles enabled - run setup (or set roles in config.json)")
        end
        -- the seed is required only while there is something to seed: once
        -- server_config2.json exists it owns the domain (Rename edits it), and
        -- nodes deployed before this field existed must keep booting straight
        -- through rather than blocking a headless server on a wizard prompt
        if cfg.roles.server == true
            and not fs.exists("server_config2.json")
            and (type(cfg.server_domain) ~= "string" or cfg.server_domain == "") then
            bad("server_domain must name the domain this server hosts")
        end
    end

    if cfg.theme ~= "dark" then
        bad(("unknown theme %q (valid: dark)"):format(tostring(cfg.theme)))
    end
    if type(cfg.text_scale) ~= "number" or cfg.text_scale < 0.5 or cfg.text_scale > 5 then
        bad("text_scale must be a number between 0.5 and 5")
    end
    if type(cfg.automation) ~= "boolean" then
        bad("automation must be true or false")
    end

    return #problems == 0, problems
end

function config.save(cfg)
    return store.save(PATH, cfg)
end

return config
