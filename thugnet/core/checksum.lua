-- Adler-32. Deliberately NOT CRC32: CRC needs 32-bit XOR, and CC:Tweaked
-- (Lua 5.1 + bit32) and the fengari test harness (Lua 5.3, no bit32)
-- disagree on bitwise support -- code using either works in one and breaks
-- in the other. Adler-32 is pure modular addition, so this file and
-- tools/checksum.js are provably the same algorithm.
--
-- Weaker than CRC32 on short inputs, which does not matter: the updater
-- checks exact byte length too, and the threat is a truncated download, not
-- a forgery (signature verification is explicitly out of scope).
local checksum = {}

local MOD = 65521

---@param s string
---@return integer adler32 as b * 65536 + a
function checksum.sum(s)
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + s:byte(i)) % MOD
        b = (b + a) % MOD
    end
    return b * 65536 + a
end

return checksum
