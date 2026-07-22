-- THE redstone output module. All bundled-mask math lives here;
-- nothing else in the codebase calls the redstone API.
local rsio = {}

local _kernel

function rsio.init(kernel) _kernel = kernel end

-- names: array {"red","blue"} or set {red=true}; returns bitmask or nil
function rsio.mask(names)
    if type(names) ~= "table" then return nil end
    local m, any = 0, false
    for k, v in pairs(names) do
        local name = (type(k) == "number") and v or (v and k or nil)
        if name ~= nil then
            local c = colors[name]
            if type(c) ~= "number" then return nil end
            m = colors.combine(m, c)
            any = true
        end
    end
    if not any then return nil end
    return m
end

function rsio.set(side, mask, on)
    if mask then
        local cur = redstone.getBundledOutput(side)
        if on then
            redstone.setBundledOutput(side, colors.combine(cur, mask))
        else
            redstone.setBundledOutput(side, colors.subtract(cur, mask))
        end
    else
        redstone.setOutput(side, on and true or false)
    end
end

function rsio.get(side, mask)
    if mask then return colors.test(redstone.getBundledOutput(side), mask) end
    return redstone.getOutput(side)
end

---@return boolean new_state
function rsio.toggle(side, mask)
    local new_state = not rsio.get(side, mask)
    rsio.set(side, mask, new_state)
    return new_state
end

function rsio.pulse(side, mask, secs)
    rsio.set(side, mask, true)
    _kernel.after(secs, function() rsio.set(side, mask, false) end)
end

return rsio
