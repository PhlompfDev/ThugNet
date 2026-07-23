-- DNS service: domain registry, liveness watchdogs, command routing,
-- push relay to subscribers, diagnostics. Pure handlers on the kernel.
local dns = {}

local REG_PATH = "dns_registry2.json"

local WATCHDOG_SECS   = 3    -- hb silence -> domain_down
local BOOT_GRACE_SECS = 15   -- persisted domains get this long to reconnect
local ROUTE_TIMEOUT   = 8    -- forwarded cmd reply deadline
local SUB_SWEEP_SECS  = 20
local SUB_MAX_AGE     = 60

local D                 -- deps { kernel, transport, protocol, store, events }
local active = false
local registry = {}     -- domain -> { id, commands, sensors }
local alive = {}        -- domain -> boolean
local watchdogs = {}    -- domain -> kernel handle
local subs = {}         -- subscriber id -> last_seen clock
local state_cache = {}  -- domain -> merged state table
local tel_cache = {}    -- domain -> { sensor -> reading fields }
local diag = {}         -- src id -> { last_seen, msgs }
local handles = {}      -- listener/ticker handles to cancel on stop

local function persist() D.store.save(REG_PATH, registry) end

local function push(kind, fields)
    for id in pairs(subs) do
        local body = { kind = kind }
        for k, v in pairs(fields or {}) do body[k] = v end
        D.transport.send(id, D.protocol.new("push", body))
    end
end

local function arm_watchdog(domain, secs)
    if watchdogs[domain] then watchdogs[domain].cancel() end
    watchdogs[domain] = D.kernel.after(secs or WATCHDOG_SECS, function()
        watchdogs[domain] = nil
        alive[domain] = false
        D.events.log("warn", "dns", "domain silent: " .. domain)
        push("domain_down", { domain = domain })
    end)
end

local function remove_domain(domain)
    if not registry[domain] then return end
    registry[domain] = nil
    alive[domain] = nil
    state_cache[domain] = nil
    tel_cache[domain] = nil
    if watchdogs[domain] then watchdogs[domain].cancel(); watchdogs[domain] = nil end
    persist()
    push("domain_removed", { domain = domain })
end

-- ── per-type handlers ────────────────────────────────────────────────────

local handlers = {}

handlers["dns_discover"] = function(src)
    D.transport.send(src, D.protocol.new("dns_here", {}))
end

handlers["register"] = function(src, msg)
    -- dedup: one domain per computer id
    for other, rec in pairs(registry) do
        if rec.id == src and other ~= msg.domain then
            remove_domain(other)
        end
    end
    registry[msg.domain] = { id = src, commands = msg.commands, sensors = msg.sensors }
    -- Prune cached telemetry down to the newly-declared roster: a sensor removed
    -- from the server's config must not linger in the snapshots panels receive,
    -- or every node that resnapshots resurrects the removed sensor.
    local tc = tel_cache[msg.domain]
    if tc then
        local keep = {}
        for _, s in ipairs(msg.sensors or {}) do
            if type(s) == "table" and type(s.name) == "string" then keep[s.name] = true end
        end
        for sensor in pairs(tc) do
            if not keep[sensor] then tc[sensor] = nil end
        end
    end
    persist()
    arm_watchdog(msg.domain)
    D.transport.send(src, D.protocol.new("register_ok", { domain = msg.domain }))
    push("commands_changed", { domain = msg.domain, commands = msg.commands, sensors = msg.sensors })
    D.events.log("info", "dns", "registered: " .. msg.domain .. " -> " .. src)
end

handlers["hb"] = function(src, msg)
    local rec = registry[msg.domain]
    if not (rec and rec.id == src) then return end
    local was = alive[msg.domain]
    alive[msg.domain] = true
    arm_watchdog(msg.domain)
    D.transport.send(src, D.protocol.new("hb_ack", {}))
    if not was then push("domain_up", { domain = msg.domain }) end
end

handlers["deregister"] = function(src, msg)
    local rec = registry[msg.domain]
    if rec and rec.id == src then
        D.events.log("info", "dns", "deregistered: " .. msg.domain)
        remove_domain(msg.domain)
    end
end

handlers["sub"] = function(src) subs[src] = os.clock() end
handlers["unsub"] = function(src) subs[src] = nil end

handlers["state_set"] = function(src, msg)
    local rec = registry[msg.domain]
    if not (rec and rec.id == src) then return end
    state_cache[msg.domain] = state_cache[msg.domain] or {}
    for k, v in pairs(msg.state) do state_cache[msg.domain][k] = v end
    push("state", { domain = msg.domain, state = msg.state })
end

handlers["seq_progress"] = function(src, msg)
    local rec = registry[msg.domain]
    if not (rec and rec.id == src) then return end
    push("seq_progress", { domain = msg.domain, cmd = msg.cmd, run_id = msg.run_id,
                           step = msg.step, total = msg.total,
                           step_name = msg.step_name, status = msg.status })
end

handlers["telemetry"] = function(src, msg)
    local rec = registry[msg.domain]
    if not (rec and rec.id == src) then return end
    tel_cache[msg.domain] = tel_cache[msg.domain] or {}
    tel_cache[msg.domain][msg.sensor] = { value = msg.value, fraction = msg.fraction,
                                          rate = msg.rate, unit = msg.unit,
                                          detail = msg.detail, error = msg.error }
    for id in pairs(subs) do
        D.transport.send(id, D.protocol.new("telemetry", {
            domain = msg.domain, sensor = msg.sensor, value = msg.value,
            fraction = msg.fraction, rate = msg.rate, unit = msg.unit,
            detail = msg.detail, error = msg.error,
        }))
    end
end

handlers["cmd"] = function(src, msg)
    if msg.routed then return end   -- server's copy, not ours to route
    local rec = registry[msg.domain]
    if not rec then
        D.transport.send(src, D.protocol.new("cmd_result",
            { fid = msg.fid, ok = false, err = "unknown domain" }))
        return
    end
    local client_id, client_fid = src, msg.fid
    D.transport.request(rec.id,
        D.protocol.new("cmd", { domain = msg.domain, name = msg.name, args = msg.args,
                                fid = 0, routed = true }),
        ROUTE_TIMEOUT,
        function(ok, reply)
            if ok then
                D.transport.send(client_id, D.protocol.new("cmd_result",
                    { fid = client_fid, ok = reply.ok, err = reply.err, state = reply.state }))
            else
                D.transport.send(client_id, D.protocol.new("cmd_result",
                    { fid = client_fid, ok = false, err = "timeout" }))
            end
        end)
end

handlers["admin"] = function(src, msg)
    if msg.routed then return end
    local domain = msg.domain
    local rec = domain and registry[domain]
    if not rec then
        if msg.fid then
            D.transport.send(src, D.protocol.new("cmd_result",
                { fid = msg.fid, ok = false, err = "unknown domain" }))
        end
        return
    end
    D.transport.send(rec.id, D.protocol.new("admin",
        { action = msg.action, args = msg.args, domain = domain, routed = true }))
    if msg.action == "remove" then remove_domain(domain) end
    if msg.fid then
        D.transport.send(src, D.protocol.new("cmd_result", { fid = msg.fid, ok = true }))
    end
end

handlers["snapshot_req"] = function(src, msg)
    local list = {}
    for domain, rec in pairs(registry) do
        table.insert(list, {
            name = domain, id = rec.id, alive = alive[domain] == true,
            commands = rec.commands or {}, sensors = rec.sensors or {},
            state = state_cache[domain] or {}, telemetry = tel_cache[domain] or {},
        })
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    D.transport.send(src, D.protocol.new("snapshot", { domains = list, fid = msg.fid }))
end

handlers["ping"] = function(src, msg)
    -- echo fid: a pong is a REPLY_TYPE and must carry the request's fid or the
    -- caller's transport.request never resolves (its liveness probe times out)
    D.transport.send(src, D.protocol.new("pong", { t_sent = msg.t_sent, fid = msg.fid }))
end

-- ── lifecycle ────────────────────────────────────────────────────────────

function dns.start(deps)
    if active then return end
    D = deps
    active = true
    registry = D.store.load(REG_PATH, {})
    alive, state_cache, tel_cache, subs, diag = {}, {}, {}, {}, {}

    -- persisted domains get the boot grace to reconnect before showing down
    for domain in pairs(registry) do
        arm_watchdog(domain, BOOT_GRACE_SECS)
    end

    table.insert(handles, D.transport.on_message(function(src, msg)
        local dg = diag[src] or { msgs = 0 }
        dg.msgs = dg.msgs + 1
        dg.last_seen = os.clock()
        diag[src] = dg
        local h = handlers[msg.t]
        if h then h(src, msg) end
    end))

    table.insert(handles, D.kernel.every(SUB_SWEEP_SECS, function()
        local now = os.clock()
        for id, seen in pairs(subs) do
            if now - seen > SUB_MAX_AGE then subs[id] = nil end
        end
    end))

    D.events.log("info", "dns", "DNS service started")
end

function dns.stop()
    if not active then return end
    active = false
    for _, h in ipairs(handles) do h.cancel() end
    handles = {}
    for _, h in pairs(watchdogs) do h.cancel() end
    watchdogs = {}
    D.events.log("info", "dns", "DNS service stopped")
end

function dns.is_active() return active end
function dns.get_domains() return registry end
function dns.is_alive(domain) return alive[domain] == true end
function dns.get_diag() return diag end

return dns
