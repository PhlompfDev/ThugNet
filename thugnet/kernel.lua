-- THE event loop. Everything time- or event-driven registers here;
-- no other module touches os.startTimer or os.pullEvent.
local kernel = {}

local ev_handlers = {}   -- name -> { [handle] = fn }
local timers = {}        -- timer_id -> { fn, every }
local running = false

local function make_handle(unreg)
    local h = {}
    function h.cancel() unreg() end
    h.unwatch = h.cancel
    return h
end

function kernel.on_event(name, fn)
    ev_handlers[name] = ev_handlers[name] or {}
    local reg = ev_handlers[name]
    local h; h = make_handle(function() reg[h] = nil end)
    reg[h] = fn
    return h
end

function kernel.after(secs, fn)
    local id = os.startTimer(secs)
    timers[id] = { fn = fn }
    return make_handle(function()
        if timers[id] then timers[id] = nil; os.cancelTimer(id) end
    end)
end

function kernel.every(secs, fn)
    local rec = { fn = fn, every = secs, cancelled = false }
    local id = os.startTimer(secs)
    timers[id] = rec
    rec.id = id
    return make_handle(function()
        rec.cancelled = true
        if rec.id and timers[rec.id] then os.cancelTimer(rec.id); timers[rec.id] = nil end
    end)
end

function kernel.step(ev, p1, p2, p3, p4, p5)
    if ev == "timer" then
        local rec = timers[p1]
        if rec then
            timers[p1] = nil
            if rec.every and not rec.cancelled then
                local nid = os.startTimer(rec.every)
                timers[nid] = rec
                rec.id = nid
            end
            local ok, err = pcall(rec.fn)
            if not ok then print("kernel: timer handler error: " .. tostring(err)) end
        end
    end
    local reg = ev_handlers[ev]
    if reg then
        -- snapshot so handlers may cancel during dispatch
        local snap = {}
        for h, fn in pairs(reg) do snap[h] = fn end
        for h, fn in pairs(snap) do
            if reg[h] then
                local ok, err = pcall(fn, p1, p2, p3, p4, p5)
                if not ok then print("kernel: '" .. tostring(ev) .. "' handler error: " .. tostring(err)) end
            end
        end
    end
end

function kernel.run()
    running = true
    while running do
        local ev, p1, p2, p3, p4, p5 = os.pullEventRaw()
        if ev == "terminate" then
            kernel.step("terminate")
            running = false
        else
            kernel.step(ev, p1, p2, p3, p4, p5)
        end
    end
end

function kernel.stop() running = false end

-- test support: wipe all registries
function kernel.reset()
    ev_handlers = {}
    timers = {}
    running = false
end

return kernel
