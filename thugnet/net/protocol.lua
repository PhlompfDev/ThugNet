-- Protocol v2: the single source of truth for message shapes.
local protocol = {}

protocol.PROTOCOL = "thugnet2"

-- required fields per type: name -> lua type
protocol.TYPES = {
    register     = { domain = "string", commands = "table", sensors = "table" },
    register_ok  = { domain = "string" },
    hb           = { domain = "string" },
    hb_ack       = {},
    deregister   = { domain = "string" },
    snapshot_req = {},
    snapshot     = { domains = "table" },
    sub          = {},
    unsub        = {},
    push         = { kind = "string" },
    cmd          = { domain = "string", name = "string", fid = "number" },
    cmd_result   = { fid = "number", ok = "boolean" },
    state_set    = { domain = "string", state = "table" },
    seq_progress = { domain = "string", cmd = "string", run_id = "number",
                     step = "number", total = "number", status = "string" },
    -- `value` is OPTIONAL (see protocol.OPTIONAL): a sensor whose peripheral
    -- can't be read publishes an error reading with no value. Requiring a
    -- number here made such a sensor undeliverable, so it vanished from the
    -- panel entirely instead of showing as broken.
    telemetry    = { domain = "string", sensor = "string" },
    admin        = { action = "string" },
    ping         = { t_sent = "number" },
    pong         = { t_sent = "number" },
    dns_discover = {},
    dns_here     = {},
}

-- Fields that may be absent but are type-checked when present. This keeps a
-- field optional without letting a wrong-typed one onto the wire: readings
-- reach builders raw, and a non-number `value`/`fraction` would throw inside
-- a widget (the 6c shared-cache lesson).
protocol.OPTIONAL = {
    telemetry = { value = "number", fraction = "number", rate = "number",
                  unit = "string", detail = "table", error = "boolean" },
}

-- message types that RESOLVE a pending transport.request (carry a reply fid);
-- request types like `cmd` also carry an fid but must never resolve one.
protocol.REPLY_TYPES = { cmd_result = true, pong = true, snapshot = true }

local seq = 0

function protocol.new(t, fields)
    seq = seq + 1
    local msg = { v = 2, t = t, src = os.getComputerID(), seq = seq }
    for k, v in pairs(fields or {}) do msg[k] = v end
    return msg
end

---@return boolean ok, string|nil err
function protocol.validate(msg)
    if type(msg) ~= "table" then return false, "not a table" end
    if msg.v ~= 2 then return false, "wrong version" end
    local spec = protocol.TYPES[msg.t]
    if not spec then return false, "unknown type: " .. tostring(msg.t) end
    if type(msg.src) ~= "number" or type(msg.seq) ~= "number" then
        return false, "missing src/seq"
    end
    for field, want in pairs(spec) do
        if type(msg[field]) ~= want then
            return false, ("field '%s' must be %s"):format(field, want)
        end
    end
    for field, want in pairs(protocol.OPTIONAL[msg.t] or {}) do
        if msg[field] ~= nil and type(msg[field]) ~= want then
            return false, ("optional field '%s' must be %s"):format(field, want)
        end
    end
    return true
end

return protocol
