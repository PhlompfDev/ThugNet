-- Client service: subscribes to DNS, mirrors the network's state locally
-- (domains, commands, sensors, state, telemetry), sends commands/admin.
local client = {}

local DISCOVER_SECS = 5
local REFRESH_SECS  = 20   -- sub refresh + dns liveness ping
local SEND_TIMEOUT  = 8
local SNAPSHOT_TIMEOUT = 5

local D              -- deps { kernel, transport, protocol, store, events, telemetry_cache }
local active = false
local dns_id = nil
local dns_alive = false
local domains = {}   -- name -> { id, alive, commands, sensors, state }
local handles = {}
local discover_handle, refresh_handle
local change_hooks = {}  -- [h] = fn(kind, domain)
local dns_hooks = {}     -- [h] = fn(ok)

local function notify(kind, domain)
    for h, fn in pairs(change_hooks) do
        if change_hooks[h] then pcall(fn, kind, domain) end
    end
end

-- The declared roster is the authority for which sensors exist. The panel
-- telemetry cache only ever grows (it remembers the last reading of every
-- sensor that ever published), so after a sensor is removed -- or its whole
-- domain is -- its stale reading lingers in the cache and keeps surfacing on
-- the Monitoring page. Prune the cache down to the sensors still declared,
-- called at every point the roster changes (snapshot, commands_changed,
-- domain_removed). This also defeats DNS re-injection: a snapshot may carry a
-- stale reading for a since-removed sensor, and this evicts it right after.
local function declared_paths()
    local keep = {}
    for name, d in pairs(domains) do
        for _, s in ipairs(d.sensors or {}) do
            if type(s) == "table" and type(s.name) == "string" then
                keep[name .. ":" .. s.name] = true
            end
        end
    end
    return keep
end

local function prune_cache()
    if D and D.telemetry_cache and D.telemetry_cache.retain then
        D.telemetry_cache.retain(declared_paths())
    end
end

local function set_dns(ok)
    if dns_alive ~= ok then
        dns_alive = ok
        for h, fn in pairs(dns_hooks) do
            if dns_hooks[h] then pcall(fn, ok) end
        end
        if not ok then
            D.events.log("warn", "client", "DNS link lost")
        end
    end
end

local start_discovery   -- fwd

local function apply_snapshot(snap)
    domains = {}
    for _, d in ipairs(snap.domains or {}) do
        domains[d.name] = { id = d.id, alive = d.alive == true,
                            commands = d.commands or {}, sensors = d.sensors or {},
                            state = d.state or {} }
        for sensor, reading in pairs(d.telemetry or {}) do
            D.telemetry_cache.update(d.name, sensor, reading)
        end
    end
    prune_cache()   -- evict any cached path the new roster no longer declares
    notify("snapshot", nil)
end

local function request_snapshot()
    if not dns_id then return end
    D.transport.request(dns_id, D.protocol.new("snapshot_req", { fid = 0 }),
        SNAPSHOT_TIMEOUT,
        function(ok, reply)
            if ok then
                set_dns(true)
                apply_snapshot(reply)
            else
                set_dns(false)
                dns_id = nil
                start_discovery()
            end
        end)
end

local function refresh()
    if not (active and dns_id) then return end
    D.transport.send(dns_id, D.protocol.new("sub", {}))
    -- liveness probe: pong resolves, timeout drops the link
    D.transport.request(dns_id, D.protocol.new("ping", { t_sent = os.clock(), fid = 0 }),
        SNAPSHOT_TIMEOUT,
        function(ok)
            if ok then
                set_dns(true)
            else
                set_dns(false)
                dns_id = nil
                start_discovery()
            end
        end)
end

start_discovery = function()
    if discover_handle then return end
    local function attempt()
        if not active or dns_id then return end
        D.transport.broadcast(D.protocol.new("dns_discover", {}))
    end
    discover_handle = D.kernel.every(DISCOVER_SECS, attempt)
    attempt()
end

local function stop_discovery()
    if discover_handle then discover_handle.cancel(); discover_handle = nil end
end

-- ── message handlers ─────────────────────────────────────────────────────

local handlers = {}

handlers["dns_here"] = function(src)
    if dns_id then return end
    dns_id = src
    stop_discovery()
    D.transport.send(dns_id, D.protocol.new("sub", {}))
    request_snapshot()
end

handlers["push"] = function(src, msg)
    if src ~= dns_id then return end
    local d = msg.domain and domains[msg.domain]
    if msg.kind == "domain_up" then
        if d then
            d.alive = true
            notify("up", msg.domain)
        else
            -- a domain we don't know is alive: our mirror is out of sync
            -- (e.g. it re-registered after a removal) — resnapshot
            request_snapshot()
        end
    elseif msg.kind == "domain_down" then
        if d then d.alive = false end
        notify("down", msg.domain)
    elseif msg.kind == "domain_removed" then
        domains[msg.domain] = nil
        prune_cache()   -- drop the removed domain's cached sensors
        notify("removed", msg.domain)
    elseif msg.kind == "state" then
        if d then
            for k, v in pairs(msg.state or {}) do d.state[k] = v end
            notify("state", msg.domain)
        else
            request_snapshot()
        end
    elseif msg.kind == "commands_changed" then
        if not d then
            domains[msg.domain] = { alive = false, commands = {}, sensors = {}, state = {} }
            d = domains[msg.domain]
        end
        d.commands = msg.commands or d.commands
        d.sensors = msg.sensors or d.sensors
        prune_cache()   -- a shrunk roster evicts the sensors it dropped
        notify("commands", msg.domain)
    elseif msg.kind == "seq_progress" then
        notify("seq_progress", msg.domain)
        client.last_progress = msg
    end
end

handlers["telemetry"] = function(src, msg)
    if src ~= dns_id then return end
    D.telemetry_cache.update(msg.domain, msg.sensor, {
        value = msg.value, fraction = msg.fraction, rate = msg.rate,
        unit = msg.unit, detail = msg.detail, error = msg.error,
    })
end

-- ── lifecycle / public API ───────────────────────────────────────────────

function client.start(deps)
    if active then return end
    D = deps
    active = true
    dns_id, dns_alive = nil, false
    domains = {}

    table.insert(handles, D.transport.on_message(function(src, msg)
        local h = handlers[msg.t]
        if h then h(src, msg) end
    end))
    refresh_handle = D.kernel.every(REFRESH_SECS, refresh)
    table.insert(handles, refresh_handle)

    start_discovery()
    D.events.log("info", "client", "client started")
end

function client.stop()
    if not active then return end
    active = false
    if dns_id then D.transport.send(dns_id, D.protocol.new("unsub", {})) end
    for _, h in ipairs(handles) do h.cancel() end
    handles = {}
    stop_discovery()
    dns_id, dns_alive = nil, false
end

function client.is_active() return active end
function client.dns_ok() return dns_alive end

---@return string[] sorted domain names
function client.get_domains()
    local out = {}
    for name in pairs(domains) do table.insert(out, name) end
    table.sort(out)
    return out
end

function client.get(domain) return domains[domain] end
function client.is_alive(domain) return domains[domain] and domains[domain].alive == true end
function client.get_commands(domain) return (domains[domain] and domains[domain].commands) or {} end
function client.get_state(domain) return (domains[domain] and domains[domain].state) or {} end

---@param cb fun(ok:boolean, state:table|nil, err:string|nil)
function client.send(domain, name, args, cb)
    if not dns_id then
        if cb then cb(false, nil, "no DNS") end
        return
    end
    D.transport.request(dns_id,
        D.protocol.new("cmd", { domain = domain, name = name, args = args, fid = 0 }),
        SEND_TIMEOUT,
        function(ok, reply)
            if not cb then return end
            if ok then cb(reply.ok, reply.state, reply.err)
            else cb(false, nil, "timeout") end
        end)
end

---@param cb? fun(ok:boolean, err:string|nil)
function client.admin(domain, action, args, cb)
    if not dns_id then
        if cb then cb(false, "no DNS") end
        return
    end
    D.transport.request(dns_id,
        D.protocol.new("admin", { action = action, domain = domain, args = args, fid = 0 }),
        SEND_TIMEOUT,
        function(ok, reply)
            if not cb then return end
            if ok then cb(reply.ok, reply.err) else cb(false, "timeout") end
        end)
end

function client.request_refresh() request_snapshot() end

-- Locally dismiss a sensor from this panel: drop it from the mirrored roster
-- and evict its cached reading. This does NOT touch the remote server config --
-- if the sensor still exists there, a later register/telemetry re-learns it.
-- It's the manual escape hatch for a sensor whose domain is gone for good.
---@param domain string
---@param name string
function client.forget_sensor(domain, name)
    local d = domains[domain]
    if d and d.sensors then
        for i, s in ipairs(d.sensors) do
            if type(s) == "table" and s.name == name then
                table.remove(d.sensors, i); break
            end
        end
    end
    if D and D.telemetry_cache and D.telemetry_cache.forget then
        D.telemetry_cache.forget(domain .. ":" .. name)
    end
    notify("commands", domain)
end

---@return table handle
function client.on_change(fn)
    local h = {}
    h.cancel = function() change_hooks[h] = nil end
    h.unwatch = h.cancel
    change_hooks[h] = fn
    return h
end

---@return table handle
function client.on_dns(fn)
    local h = {}
    h.cancel = function() dns_hooks[h] = nil end
    h.unwatch = h.cancel
    dns_hooks[h] = fn
    return h
end

return client
