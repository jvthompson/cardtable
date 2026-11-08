-- Local seed for the F11 (on/off) + F12 (cycle) playmat choice, persisted
-- per game id (not folderPath, which can change -- see rulebook_settings.lua).
-- This is only ever the *seed* used to initialize TableState when hosting or
-- joining a game; the live values during a session are the synced TableState
-- fields (see session.lua's setSharedPlaymat/setIndividualPlaymat) -- one
-- pair serves as the host's seed for the shared mat when game.playmatType
-- is "shared", and as each local player's own seed for their individual mat
-- when it's "individual".
local settings = require("src.data.settings")

local P = {}

local function onKey(gameId) return "playmat_on_" .. tostring(gameId) end
local function indexKey(gameId) return "playmat_index_" .. tostring(gameId) end

function P.on(gameId) return settings.get(onKey(gameId)) == true end
function P.index(gameId) return tonumber(settings.get(indexKey(gameId))) or 0 end

function P.set(gameId, on, index)
  if on then settings.set(onKey(gameId), true) else settings.remove(onKey(gameId)) end
  if index and index ~= 0 then settings.set(indexKey(gameId), index) else settings.remove(indexKey(gameId)) end
end

return P
