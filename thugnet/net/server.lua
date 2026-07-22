-- Server service: hosts a domain. Executes commands through the step engine,
-- tracks static-face state for responses and boot restore, polls sensors,
-- keeps the DNS link alive (async discovery, hb + ack watchdog).
local server = {}

local CFG_PATH = "server_config2.json"

local HB_SECS         = 2
local ACK_TIMEOUT     = 4
local DISCOVER_SECS   = 5
local NET_STEP_TIMEOUT = 15

local D                -- deps { kernel, transport, protocol, store, events, rsio, steps, telemetry }
local active = false
local cfg = nil
local dns_id = nil
local dns_alive = false
local handles = {}     -- cancel-on-stop handles
local hb_handle, ack_handle, discover_handle
local poller = nil
local runs = {}        -- run_id -> steps run handle

-- ── config ───────────────────────────────────────────────────────────────

local function load_cfg()
    cfg = D.store.load(CFG_PATH, { domain = "myserver", dead = true, commands = {}, sensors = {} })
    cfg.commands = cfg.commands or {}
    cfg.sensors = cfg.sensors or {}
end

local function save_cfg() D.store.save(CFG_PATH, cfg) end

local function find_command(name)
    for _, c in ipairs(cfg.commands) do
        if c.name == name then return c end
    end
end

-- ── static face state ────────────────────────────────────────────────────

-- iterate every static face across a command's steps
local function each_static_face(cmd, fn)
    for _, step in ipairs(cmd.steps or {}) do
        if step.type == "redstone" then
            for side, face in pairs(step.faces or {}) do
                if face.mode == "static" then fn(side, face) end
            end
        end
    end
end

-- after a run: read actual outputs back into face.on (true or ABSENT, never false)
local function record_static_state(cmd)
    each_static_face(cmd, function(side, face)
        local mask = face.bundled and D.rsio.mask(face.bundled) or nil
        face.on = D.rsio.get(side, mask) or nil
    end)
    save_cfg()
end

local function any_static_on(cmd)
    local on = false
    each_static_face(cmd, function(_, face)
        if face.on then on = true end
    end)
    return on
end

-- ── DNS link ─────────────────────────────────────────────────────────────

local function publish_reading(name, reading)
    -- an unreadable sensor publishes an explicit ERROR reading rather than
    -- nothing: dropping it made a misconfigured sensor disappear from the
    -- panel completely (Monitoring/widgets key off published readings), with
    -- a single warn event as the only trace
    local numeric = type(reading.value) == "number"
    if dns_id and (numeric or reading.error) then
        D.transport.send(dns_id, D.protocol.new("telemetry", {
            domain = cfg.domain, sensor = name,
            value = numeric and reading.value or nil,
            fraction = reading.fraction, rate = reading.rate,
            unit = reading.unit, detail = reading.detail,
            error = reading.error,
        }))
    end
end

local function set_dns_alive(v)
    if dns_alive ~= v then
        dns_alive = v
        D.events.log(v and "info" or "warn", "server",
            v and "DNS link established" or "DNS link lost")
        -- fresh link: re-publish every current reading so the network's view
        -- is complete even though the throttle saw these values already
        if v and poller then
            for name, reading in pairs(poller.readings()) do
                if reading then publish_reading(name, reading) end
            end
        end
    end
end

local function send_register()
    if not dns_id then return end
    D.transport.send(dns_id, D.protocol.new("register",
        { domain = cfg.domain, commands = cfg.commands, sensors = cfg.sensors }))
end

local start_discovery   -- forward decl

local function start_heartbeat()
    if hb_handle then hb_handle.cancel() end
    hb_handle = D.kernel.every(HB_SECS, function()
        if not (active and dns_id) then return end
        D.transport.send(dns_id, D.protocol.new("hb", { domain = cfg.domain }))
        -- arm the ack watchdog only when none is outstanding: re-arming per
        -- hb would push the deadline forever and a dead DNS would never trip
        -- it (a latent v1 bug this rewrite fixes)
        if not ack_handle then
            ack_handle = D.kernel.after(ACK_TIMEOUT, function()
                ack_handle = nil
                set_dns_alive(false)
                dns_id = nil
                start_discovery()
            end)
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

-- ── command execution ────────────────────────────────────────────────────

local function exec_command(cmd, reply_to, fid)
    local multi = #(cmd.steps or {}) > 1
    local run
    run = D.steps.run{
        steps = cmd.steps or {},
        ctx = {
            rsio = D.rsio,
            kernel = D.kernel,
            send = function(domain, name, args, cb)
                if not dns_id then cb(false, nil) return end
                D.transport.request(dns_id,
                    D.protocol.new("cmd", { domain = domain, name = name, args = args, fid = 0 }),
                    NET_STEP_TIMEOUT,
                    function(ok, reply)
                        if ok then cb(reply.ok, reply.state) else cb(false, nil) end
                    end)
            end,
            telemetry = function(path)
                if not poller then return nil end
                local sensor = path:match("^[^:]+:(.+)$") or path
                local r = poller.get(sensor)
                return r and r.value
            end,
        },
        on_progress = function(p)
            if multi and dns_id then
                local step_def = (cmd.steps or {})[p.step] or {}
                D.transport.send(dns_id, D.protocol.new("seq_progress", {
                    domain = cfg.domain, cmd = cmd.name, run_id = p.run_id,
                    step = p.step, total = p.total,
                    step_name = step_def.name, status = p.status,
                }))
            end
        end,
        on_done = function(r)
            runs[r.run_id] = nil
            record_static_state(cmd)
            local state = nil
            if cmd.response_key and cmd.response_key ~= "" then
                state = { [cmd.response_key] = any_static_on(cmd) }
            end
            if reply_to then
                D.transport.send(reply_to, D.protocol.new("cmd_result", {
                    fid = fid, ok = r.status == "done", err = r.reason, state = state,
                }))
            end
            if state and dns_id then
                D.transport.send(dns_id, D.protocol.new("state_set",
                    { domain = cfg.domain, state = state }))
            end
            if r.status == "failed" then
                D.events.log("alert", "server", "command failed: " .. cmd.name
                    .. " (" .. tostring(r.reason) .. ")")
            end
        end,
    }
    runs[run.id] = run
    return run
end

-- ── message handlers ─────────────────────────────────────────────────────

local handlers = {}

handlers["dns_here"] = function(src)
    if dns_id then return end
    dns_id = src
    stop_discovery()
    send_register()
    start_heartbeat()
end

handlers["register_ok"] = function(src)
    if src == dns_id then set_dns_alive(true) end
end

handlers["hb_ack"] = function(src)
    if src ~= dns_id then return end
    if ack_handle then ack_handle.cancel(); ack_handle = nil end
    set_dns_alive(true)
end

handlers["cmd"] = function(src, msg)
    if not msg.routed then return end          -- only DNS-forwarded commands
    if msg.domain ~= cfg.domain then return end
    local cmd = find_command(msg.name)
    if not cmd then
        D.transport.send(src, D.protocol.new("cmd_result",
            { fid = msg.fid, ok = false, err = "unknown command: " .. msg.name }))
        return
    end
    exec_command(cmd, src, msg.fid)
end

handlers["admin"] = function(_, msg)
    if not msg.routed then return end
    if msg.domain ~= cfg.domain then return end
    if msg.action == "stop" then
        server.stop()
    elseif msg.action == "rename" then
        local new_name = msg.args and msg.args.name
        if type(new_name) == "string" and new_name ~= "" then
            cfg.domain = new_name
            save_cfg()
            send_register()
            D.events.log("info", "server", "renamed to " .. new_name)
        end
    elseif msg.action == "remove" then
        server.stop()
    elseif msg.action == "abort_seq" then
        local rid = msg.args and msg.args.run_id
        local run = rid and runs[rid]
        if run then run.abort() end
    end
end

handlers["ping"] = function(src, msg)
    -- echo fid: a pong is a REPLY_TYPE and must carry the request's fid or the
    -- caller's transport.request never resolves (its liveness probe times out)
    D.transport.send(src, D.protocol.new("pong", { t_sent = msg.t_sent, fid = msg.fid }))
end

-- ── sensors ──────────────────────────────────────────────────────────────

local function start_sensors()
    if poller then poller.stop() end
    poller = D.telemetry.poller(D.kernel, function(name, reading)
        -- error readings stay local (protocol telemetry requires a number value)
        publish_reading(name, reading)
        if reading.error then
            D.events.log("warn", "server", "sensor read failed: " .. name)
        end
    end)
    poller.set_sensors(cfg.sensors)
end

-- ── lifecycle / public API ───────────────────────────────────────────────

function server.start(deps, domain)
    if active then return end
    D = deps or D          -- argless restart reuses the previous deps
    if not D then return end
    load_cfg()
    if domain and domain ~= "" then cfg.domain = domain end
    cfg.dead = false
    save_cfg()
    active = true
    dns_id, dns_alive = nil, false

    -- boot restore: re-apply static faces that were on
    for _, cmd in ipairs(cfg.commands) do
        each_static_face(cmd, function(side, face)
            if face.on then
                D.rsio.set(side, face.bundled and D.rsio.mask(face.bundled) or nil, true)
            end
        end)
    end

    table.insert(handles, D.transport.on_message(function(src, msg)
        local h = handlers[msg.t]
        if h then h(src, msg) end
    end))

    start_sensors()
    start_discovery()
    D.events.log("info", "server", "server started: " .. cfg.domain)
end

function server.stop()
    if not active then return end
    active = false
    if dns_id then
        D.transport.send(dns_id, D.protocol.new("deregister", { domain = cfg.domain }))
    end
    for _, h in ipairs(handles) do h.cancel() end
    handles = {}
    if hb_handle then hb_handle.cancel(); hb_handle = nil end
    if ack_handle then ack_handle.cancel(); ack_handle = nil end
    stop_discovery()
    if poller then poller.stop(); poller = nil end
    for _, run in pairs(runs) do run.abort() end
    runs = {}
    -- clear every static output; remember nothing is on
    for _, cmd in ipairs(cfg.commands) do
        each_static_face(cmd, function(side, face)
            D.rsio.set(side, face.bundled and D.rsio.mask(face.bundled) or nil, false)
            face.on = nil
        end)
    end
    cfg.dead = true
    save_cfg()
    dns_id, dns_alive = nil, false
    D.events.log("info", "server", "server stopped")
end

function server.is_active() return active end
function server.get_domain() return cfg and cfg.domain end
function server.dns_ok() return dns_alive end
function server.get_commands() return (cfg and cfg.commands) or {} end
function server.get_sensors() return (cfg and cfg.sensors) or {} end
function server.get_runs() return runs end

function server.set_commands(cmds)
    cfg.commands = cmds or {}
    save_cfg()
    send_register()
end

function server.set_sensors(sensors)
    cfg.sensors = sensors or {}
    save_cfg()
    if active then start_sensors() end
    send_register()
end

-- local rename (the Server page); remote rename arrives via the admin handler
function server.rename(new_name)
    if type(new_name) ~= "string" or new_name == "" then return end
    if not cfg then load_cfg() end
    cfg.domain = new_name
    save_cfg()
    if active then
        send_register()
        D.events.log("info", "server", "renamed to " .. new_name)
    end
end

return server
