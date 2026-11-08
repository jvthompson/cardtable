-- Shared fixtures for tests.
local models = require("src.core.models")

local H = {}

function H.card(f)
  return models.CardInstance.new({
    instanceId = f.instanceId or f.id,
    definitionId = f.definitionId or "def",
    x = f.x or 0,
    y = f.y or 0,
    zIndex = f.zIndex or 0,
    faceUp = f.faceUp or false,
    zone = f.zone or "table",
    ownerId = f.ownerId,
    stackParentId = f.stackParentId,
    zoneId = f.zoneId,
    rotationTurns = f.rotationTurns,
    unownable = f.unownable,
  })
end

function H.widget(f)
  local w = {}
  for k, v in pairs(f) do w[k] = v end
  w.instanceId = f.instanceId or f.id
  w.id = nil
  w.kind = f.kind or "token"
  w.x = f.x or 0
  w.y = f.y or 0
  w.zIndex = f.zIndex or 0
  return models.BoardWidgetInstance.new(w)
end

function H.player(id, name, role, color)
  return models.PlayerInfo.new({ id = id, name = name or id, role = role or "client", color = color or 0xFF000000 })
end

function H.state(f)
  return models.TableState.new({
    gameId = f.gameId or "g1",
    players = f.players or {},
    cards = f.cards or {},
    revision = f.revision or 0,
    widgets = f.widgets or {},
    searches = f.searches or {},
    log = f.log or {},
    currentPlayerId = f.currentPlayerId,
  })
end

function H.find(list, id, key)
  key = key or "instanceId"
  for _, v in ipairs(list) do
    if v[key] == id then return v end
  end
  return nil
end

function H.cardDef(id, types, extra)
  local f = { id = id, cardTitle = id, types = types or {} }
  for k, v in pairs(extra or {}) do f[k] = v end
  return models.CardDefinition.new(f)
end

return H
