-- Port of lib/game/save_game_remap.dart.
local models = require("src.core.models")
local util = require("src.core.util")

local R = {}

-- Matches saved players to current players by exact, unique name.
-- Returns { matched = {savedId -> currentId}, unmatchedSaved = {...}, unmatchedCurrent = {...} }.
function R.matchPlayersByName(savedPlayers, currentPlayers)
  local savedByName, currentByName = {}, {}
  for _, p in ipairs(savedPlayers) do
    savedByName[p.name] = savedByName[p.name] or {}
    table.insert(savedByName[p.name], p)
  end
  for _, p in ipairs(currentPlayers) do
    currentByName[p.name] = currentByName[p.name] or {}
    table.insert(currentByName[p.name], p)
  end
  local matched, claimed = {}, {}
  for _, saved in ipairs(savedPlayers) do
    local sg, cg = savedByName[saved.name], currentByName[saved.name]
    if #sg == 1 and cg ~= nil and #cg == 1 then
      matched[saved.id] = cg[1].id
      claimed[cg[1].id] = true
    end
  end
  return {
    matched = matched,
    unmatchedSaved = util.filter(savedPlayers, function(p) return matched[p.id] == nil end),
    unmatchedCurrent = util.filter(currentPlayers, function(p) return not claimed[p.id] end),
  }
end

-- Rebuilds a saved TableState for the current players. Unlike the Flutter
-- app, the game log is kept (its entries name players as they were then).
-- validDefinitionIds is a set {id -> true}. Returns state, droppedCardCount.
function R.buildLoadedTableState(saved, currentPlayers, savedIdToCurrentId, validDefinitionIds)
  local currentById = {}
  for _, p in ipairs(currentPlayers) do currentById[p.id] = p end
  local players = {}
  for _, sp in ipairs(saved.players) do
    local cid = savedIdToCurrentId[sp.id]
    local cur = cid and currentById[cid]
    if cur then players[#players + 1] = cur end
  end

  local function remap(id)
    if id == nil then return util.NIL end
    return savedIdToCurrentId[id] or util.NIL
  end

  local kept, dropped = {}, 0
  for _, card in ipairs(saved.cards) do
    if not validDefinitionIds[card.definitionId] then
      dropped = dropped + 1
    else
      kept[#kept + 1] = util.copyWith(card, { ownerId = remap(card.ownerId) })
    end
  end
  local keptIds = {}
  for _, c in ipairs(kept) do keptIds[c.instanceId] = true end
  local cards = util.map(kept, function(c)
    if c.stackParentId ~= nil and not keptIds[c.stackParentId] then
      return util.copyWith(c, { stackParentId = util.NIL })
    end
    return c
  end)
  local widgets = util.map(saved.widgets, function(w)
    return util.copyWith(w, {
      ownerId = remap(w.ownerId),
      creatorId = remap(w.creatorId),
      attachedCardId = (w.attachedCardId ~= nil and not keptIds[w.attachedCardId]) and util.NIL or w.attachedCardId or util.NIL,
    })
  end)
  -- Not run through remap(): that returns util.NIL for copyWith's benefit,
  -- but TableState.new wants a plain nil when there's no match.
  local currentPlayerId = saved.currentPlayerId and savedIdToCurrentId[saved.currentPlayerId] or nil

  return models.TableState.new({
    gameId = saved.gameId, players = players, cards = cards, revision = saved.revision, widgets = widgets,
    log = saved.log, loadedZones = saved.loadedZones, loadedScenarioIds = saved.loadedScenarioIds,
    currentPlayerId = currentPlayerId,
  }), dropped
end

return R
