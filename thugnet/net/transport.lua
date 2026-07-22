-- Rednet wrapper: single receive point, validation gate, fid registry.
local transport = {}

local _kernel, _protocol
local listeners = {}   -- [handle] = fn(src, msg)
local pending = {}     -- fid -> { cb, timer_handle }
local fid_counter = 0

function transport.init(kernel, protocol)
    _kernel, _protocol = kernel, protocol
    peripheral.find("modem", function(name, _) rednet.open(name) end)

    kernel.on_event("rednet_message", function(src, msg, proto)
        if proto ~= _protocol.PROTOCOL then return end
        if not _protocol.validate(msg) then return end

        -- request resolution first — reply types only: an incoming `cmd`
        -- whose fid happens to match one of OUR pending fids must not
        -- resolve it (fids are per-computer counters, collisions are legal)
        if _protocol.REPLY_TYPES[msg.t] and type(msg.fid) == "number" and pending[msg.fid] then
            local req = pending[msg.fid]
            pending[msg.fid] = nil
            if req.timer then req.timer.cancel() end
            local ok, err = pcall(req.cb, true, msg)
            if not ok then print("transport: request cb error: " .. tostring(err)) end
            return
        end

        local snap = {}
        for h, fn in pairs(listeners) do snap[h] = fn end
        for h, fn in pairs(snap) do
            if listeners[h] then
                local ok, err = pcall(fn, src, msg)
                if not ok then print("transport: listener error: " .. tostring(err)) end
            end
        end
    end)
end

function transport.send(dest, msg)
    rednet.send(dest, msg, _protocol.PROTOCOL)
end

function transport.broadcast(msg)
    rednet.broadcast(msg, _protocol.PROTOCOL)
    -- rednet loops a DIRECTED send back to the sender (rednet.send special-cases
    -- recipient == own id) but a BROADCAST is never heard by the sender's own
    -- modem. On an all-in-one node the local dns/server/client must still see
    -- each other's dns_discover, so deliver the broadcast to ourselves the same
    -- way a directed self-send would arrive.
    os.queueEvent("rednet_message", os.getComputerID(), msg, _protocol.PROTOCOL)
end

function transport.on_message(fn)
    local h = {}
    h.cancel = function() listeners[h] = nil end
    listeners[h] = fn
    return h
end

function transport.next_fid()
    fid_counter = fid_counter + 1
    return fid_counter
end

---@return integer fid
function transport.request(dest, msg, timeout_secs, cb)
    local fid = transport.next_fid()
    msg.fid = fid
    local rec = { cb = cb }
    rec.timer = _kernel.after(timeout_secs, function()
        if pending[fid] then
            pending[fid] = nil
            local ok, err = pcall(cb, false, "timeout")
            if not ok then print("transport: timeout cb error: " .. tostring(err)) end
        end
    end)
    pending[fid] = rec
    transport.send(dest, msg)
    return fid
end

return transport
