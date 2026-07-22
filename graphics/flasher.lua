--
-- Indicator Light Flasher
--
-- Drives LED blinking via a self-managed OS timer.  The timer ID is tracked
-- internally so any coroutine that receives the timer event can forward it to
-- flasher.step() — whichever coroutine gets it first will tick the flasher
-- and schedule the next timer, with no event bouncing or starvation.
--
-- Integration:
--   • In every parallel coroutine's timer branch, call flasher.step(timer_id).
--   • flasher.step() returns true if it consumed the event (so callers can
--     skip their own timer handling for that ID).
--

local flasher = {}

---@alias PERIOD integer
local PERIOD = {
    BLINK_250_MS  = 1,
    BLINK_500_MS  = 2,
    BLINK_1000_MS = 3
}

flasher.PERIOD = PERIOD

local active           = false
local registry         = { {}, {}, {} } ---@type function[][]
local callback_counter = 0
local timer_id         = nil  -- the currently pending OS timer ID (nil when stopped)

-- Schedule the next 250ms tick. Cancels any existing timer first to avoid
-- double-firing if called redundantly (e.g. from both run() and step()).
local function schedule()
    if timer_id then os.cancelTimer(timer_id) end
    timer_id = os.startTimer(0.25)
end

-- Execute one flasher tick and reschedule.
local function tick()
    if not active then return end

    for _, f in ipairs(registry[PERIOD.BLINK_250_MS]) do f() end

    if callback_counter % 2 == 0 then
        for _, f in ipairs(registry[PERIOD.BLINK_500_MS]) do f() end
    end

    if callback_counter % 4 == 0 then
        for _, f in ipairs(registry[PERIOD.BLINK_1000_MS]) do f() end
    end

    callback_counter = callback_counter + 1
    schedule()
end

-- Call this from every parallel coroutine's timer event handler.
-- If the event belongs to the flasher, executes the tick and returns true.
-- Otherwise returns false so the caller can handle its own timers normally.
---@param id integer timer event ID
---@return boolean consumed
function flasher.step(id)
    if id == timer_id then
        timer_id = nil  -- clear before tick so schedule() inside tick() sets a fresh one
        tick()
        return true
    end
    return false
end

-- Start/resume the flasher periodic.
function flasher.run()
    if not active then
        active = true
        schedule()
    end
end

-- Clear all blinking indicators and stop the flasher periodic.
function flasher.clear()
    active = false
    callback_counter = 0
    registry = { {}, {}, {} }
    if timer_id then os.cancelTimer(timer_id) end
    timer_id = nil
end

-- Pause all flashing without clearing registrations.
function flasher.pause()
    active = false
    if timer_id then os.cancelTimer(timer_id) end
    timer_id = nil
end

-- Resume flashing (restart the tick chain).
function flasher.resume()
    if not active then
        active = true
        schedule()
    end
end

-- Register a function to be called on the selected blink period.
---@param f function function to call each period
---@param period PERIOD time period option (1, 2, or 3)
function flasher.start(f, period)
    if type(registry[period]) == "table" then
        table.insert(registry[period], f)
        flasher.run()
    end
end

-- Stop a function from being called at the blink period.
---@param f function callback to remove
function flasher.stop(f)
    for i = 1, #registry do
        for key, val in ipairs(registry[i]) do
            if val == f then
                table.remove(registry[i], key)
                return
            end
        end
    end
end

-- Test support: how many callbacks are registered across every period bucket.
-- The editor destroys and rebuilds elements constantly, and element.delete()
-- never calls flasher.stop -- so "did teardown release the callback?" needs to
-- be assertable.
---@return integer count
function flasher.registered()
    local n = 0
    for i = 1, #registry do n = n + #registry[i] end
    return n
end

return flasher
