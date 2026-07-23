-- The single source of the ThugNet version (cc-mek-scada convention: one
-- constant in code, surfaced everywhere — boot log, front panel, README).
-- The wire protocol has its own axis (protocol.lua's v = 2); a UI change bumps
-- this string without implying anything about network compatibility.
return "2.2.6"
