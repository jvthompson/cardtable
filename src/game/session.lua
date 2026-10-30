-- Port of lib/game/game_session.dart: owns the authoritative TableState,
-- wraps every TableActions call with game-log entries, and notifies
-- listeners on change.
--
-- Time: `opts.now` (seconds, default love.timer.getTime) drives the log
-- clock and the arrow-lifetime timer; call session:update() each frame so
-- pending timers fire.
local models = require("src.core.models")
local util = require("src.core.util")
local uuid = require("src.core.uuid")
local A = require("src.core.table_actions")
local stacks = require("src.core.stack_utils")
local dwz = require("src.core.deck_widget_zones")
local packs = require("src.core.pack_generator")

local Session = {}
Session.__index = Session

Session.arrowLifetime = 5 -- seconds

local function defaultNow() return love.timer.getTime() end

-- opts: { game, localPlayerId, initialState, isLocalPractice, clockStart, now }
function Session.new(opts)
  local self = setmetatable({}, Session)
  self.game = opts.game
  self.localPlayerId = opts.localPlayerId
  self.state = opts.initialState
  self.isLocalPractice = opts.isLocalPractice or false
  self.now = opts.now or defaultNow
  self.clockStart = opts.clockStart or self.now()
  self.activeSeatId = nil
  self.listeners = {}
  self.timers = {}
  -- Cosmetic drag previews from other players: playerId -> preview.
  self.cardDragPreviews = {}
  self.arrowDragPreviews = {}
  self.definitionsById = {}
  for _, c in ipairs(self.game.cards) do
    if self.definitionsById[c.id] == nil then self.definitionsById[c.id] = c end
  end
  return self
end

function Session:actingPlayerId() return self.activeSeatId or self.localPlayerId end

function Session:setActiveSeat(playerId)
  if not self.isLocalPractice then return end
  self.activeSeatId = playerId
  self:notify()
end

function Session:addListener(fn)
  self.listeners[#self.listeners + 1] = fn
  return fn
end

function Session:removeListener(fn)
  for i, l in ipairs(self.listeners) do
    if l == fn then table.remove(self.listeners, i) return end
  end
end

function Session:notify()
  for _, l in ipairs(util.shallowCopy(self.listeners)) do l(self) end
end

function Session:update()
  if #self.timers == 0 then return end
  local now = self.now()
  local due = {}
  local keep = {}
  for _, t in ipairs(self.timers) do
    if now >= t.at then due[#due + 1] = t else keep[#keep + 1] = t end
  end
  self.timers = keep
  for _, t in ipairs(due) do t.fn() end
end

function Session:after(seconds, fn)
  self.timers[#self.timers + 1] = { at = self.now() + seconds, fn = fn }
end

---------------------------------------------------------------------------
-- Initial deal
---------------------------------------------------------------------------

-- opts: { game, players, localPlayerId, deckConfigsByPlayerId,
--         sharedDeckConfigsByZoneId, isLocalPractice, now, rng }
function Session.dealFromZones(opts)
  local game = opts.game
  local standardDeckCards = util.any(game.zones, function(z) return z.shared and z.standardDeck end)
    and models.buildStandardDeckCards() or {}
  local defs = {}
  for _, c in ipairs(game.cards) do defs[c.id] = c end
  for _, c in ipairs(standardDeckCards) do defs[c.id] = c end
  local function entriesOf(list)
    return util.map(list, function(c) return models.DeckEntry.new(c.id, 1) end)
  end
  local fullDeckEntries = entriesOf(game.cards)
  local standardDeckEntries = entriesOf(standardDeckCards)
  local cards = {}
  local i = 0

  local function deal(entries, zoneId, ownerId, faceUp, autoShuffle)
    local ids = {}
    for _, e in ipairs(entries) do
      if defs[e.definitionId] then
        for _ = 1, e.quantity do ids[#ids + 1] = e.definitionId end
      end
    end
    if autoShuffle then util.shuffle(ids, opts.rng) end
    for _, id in ipairs(ids) do
      cards[#cards + 1] = models.CardInstance.new({
        instanceId = uuid.v4(), definitionId = id, x = 0.5, y = 0.5, zIndex = i, faceUp = faceUp,
        zone = "zone", zoneId = zoneId, ownerId = ownerId, unownable = defs[id].unownable,
      })
      i = i + 1
    end
  end

  for _, player in ipairs(opts.players) do
    for _, zone in ipairs(game.zones) do
      if not zone.shared and zone.kind == "card" then
        local entries
        if zone.dealsBuiltDeck then
          if opts.deckConfigsByPlayerId == nil then
            entries = fullDeckEntries
          else
            local deck = opts.deckConfigsByPlayerId[player.id]
            entries = deck and models.DeckConfig.entriesFor(deck, zone.deckType) or {}
          end
        else
          entries = zone.entries
        end
        deal(entries, zone.id, player.id, zone.faceUp, zone.autoShuffle)
      end
    end
  end

  local widgets = {}
  for _, player in ipairs(opts.players) do
    for _, zone in ipairs(game.zones) do
      if not zone.shared and zone.kind == "widget" then
        widgets[#widgets + 1] = models.BoardWidgetInstance.new({
          instanceId = uuid.v4(), kind = "simpleCounter", x = 0.5, y = 0.5, zIndex = #widgets,
          value = zone.counterStartingValue, backgroundColor = zone.counterStartingColor,
          textColor = zone.counterStartingTextColor, ownerId = player.id, zoneId = zone.id,
        })
      end
    end
  end

  for _, zone in ipairs(game.zones) do
    if zone.shared then
      local entries
      if zone.standardDeck then
        entries = standardDeckEntries
      else
        local loaded = opts.sharedDeckConfigsByZoneId and opts.sharedDeckConfigsByZoneId[zone.id]
        if loaded then
          entries = models.DeckConfig.entriesFor(loaded, "main_deck")
        elseif #zone.entries > 0 or zone.isDiscardPile then
          entries = zone.entries
        else
          entries = fullDeckEntries
        end
      end
      deal(entries, zone.id, nil, zone.faceUp, zone.autoShuffle)
    end
  end

  return Session.new({
    game = game,
    localPlayerId = opts.localPlayerId,
    initialState = models.TableState.new({ gameId = game.id, players = opts.players, cards = cards, widgets = widgets, revision = 0 }),
    isLocalPractice = opts.isLocalPractice,
    now = opts.now,
  })
end

function Session.localPractice(opts)
  return Session.dealFromZones({
    game = opts.game, players = opts.players, localPlayerId = opts.players[1].id,
    deckConfigsByPlayerId = opts.deckConfigsByPlayerId,
    sharedDeckConfigsByZoneId = opts.sharedDeckConfigsByZoneId,
    isLocalPractice = true, now = opts.now, rng = opts.rng,
  })
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

function Session:findCard(id) return models.TableState.cardById(self.state, id) end
function Session:findWidget(id) return models.TableState.widgetById(self.state, id) end

function Session:definition(definitionId) return self.definitionsById[definitionId] end

function Session:playerName(playerId)
  local p = models.TableState.playerById(self.state, playerId)
  return p and p.name or playerId
end

-- game.zones followed by any zones loaded into the session from a scenario.
function Session:effectiveZones()
  local zones = {}
  for _, z in ipairs(self.game.zones) do zones[#zones + 1] = z end
  for _, z in ipairs(self.state.loadedZones) do zones[#zones + 1] = z end
  return zones
end

function Session:zoneDefinition(zoneId)
  local parsed = dwz.parse(zoneId)
  local realId = parsed and parsed.realZoneId or zoneId
  local zone = models.GameDefinition.zoneById(self.game, realId)
  if not zone then
    for _, z in ipairs(self.state.loadedZones) do
      if z.id == realId then
        zone = z
        break
      end
    end
  end
  if not zone then error("unknown zone '" .. tostring(zoneId) .. "'", 2) end
  return zone
end

function Session:isPubliclyVisible(card)
  if not card.faceUp then return false end
  if card.zone == "table" then return true end
  if card.zone == "hand" then return false end
  if card.ownerId == nil then return true end
  if dwz.isDeckWidgetZoneId(card.zoneId) then return false end
  return self:zoneDefinition(card.zoneId).visibleToAll
end

function Session:titleOf(card)
  local def = card and self.definitionsById[card.definitionId]
  return def and def.cardTitle or nil
end

function Session:revealedCardName(oldCard, newCard)
  local revealed = (oldCard ~= nil and self:isPubliclyVisible(oldCard)) or (newCard ~= nil and self:isPubliclyVisible(newCard))
  if not revealed then return nil end
  return self:titleOf(newCard or oldCard)
end

local function cardText(name) return name and ('"' .. name .. '"') or "a card" end

function Session:elapsedMs()
  return math.max(0, math.floor((self.now() - self.clockStart) * 1000))
end

function Session:log(actingPlayerId, action)
  local log = util.shallowCopy(self.state.log)
  log[#log + 1] = models.LogEntry.new(self:elapsedMs(), self:playerName(actingPlayerId) .. " " .. action)
  self.state = util.copyWith(self.state, { log = log })
end

function Session:logPlayedToTable(actingPlayerId, oldCard, instanceId)
  local name = self:revealedCardName(oldCard, self:findCard(instanceId))
  local origin = oldCard.zone == "hand" and "hand" or ("the " .. self:zoneDefinition(oldCard.zoneId).name)
  self:log(actingPlayerId, "played " .. cardText(name) .. " to the table from " .. origin .. ".")
end

---------------------------------------------------------------------------
-- Card operations
---------------------------------------------------------------------------

function Session:moveCard(instanceId, x, y, actingPlayerId)
  local old = self:findCard(instanceId)
  self.state = A.moveCard(self.state, instanceId, x, y)
  if old and old.zone ~= "table" then self:logPlayedToTable(actingPlayerId, old, instanceId) end
  self:notify()
end

function Session:moveStack(rootInstanceId, x, y)
  self.state = A.moveStack(self.state, rootInstanceId, x, y)
  self:notify()
end

function Session:moveGroup(primaryInstanceId, passengerRootIds, x, y, actingPlayerId)
  local old = self:findCard(primaryInstanceId)
  self.state = A.moveGroup(self.state, primaryInstanceId, passengerRootIds, x, y)
  if old and old.zone ~= "table" then self:logPlayedToTable(actingPlayerId, old, primaryInstanceId) end
  self:notify()
end

function Session:rotateStack(rootInstanceId, clockwise, actingPlayerId)
  self.state = A.rotateStack(self.state, rootInstanceId, clockwise)
  local card = self:findCard(rootInstanceId)
  if card then
    local name = self:isPubliclyVisible(card) and self:titleOf(card) or nil
    self:log(actingPlayerId, name and ('rotated "' .. name .. '".') or "rotated a card.")
  end
  self:notify()
end

function Session:bringToFront(rootInstanceId)
  self.state = A.bringToFront(self.state, rootInstanceId)
  self:notify()
end

function Session:flipCard(instanceId, actingPlayerId)
  self.state = A.flipCard(self.state, instanceId)
  local card = self:findCard(instanceId)
  if card and card.zone ~= "hand" then
    local direction = card.faceUp and "face up" or "face down"
    local name = self:isPubliclyVisible(card) and self:titleOf(card) or nil
    self:log(actingPlayerId, name and ('flipped "' .. name .. '" ' .. direction .. ".") or ("flipped a card " .. direction .. "."))
  end
  self:notify()
end

-- Whether the card sits in a table pile with other cards.
function Session:isInPile(instanceId)
  local c = self:findCard(instanceId)
  if not c or c.zone ~= "table" then return false end
  return #stacks.stackOf(self.state.cards, stacks.rootIdOf(self.state.cards, c)) > 1
end

-- A card in a pile can't change owner (refused silently): piles never mix
-- owners, so neither giving it away nor releasing it is allowed.
function Session:giveCard(instanceId, newOwnerId, actingPlayerId)
  if self:isInPile(instanceId) then return end
  self.state = A.giveCard(self.state, instanceId, newOwnerId)
  local card = self:findCard(instanceId)
  local name = (card and self:isPubliclyVisible(card)) and self:titleOf(card) or nil
  if newOwnerId ~= nil then
    self:log(actingPlayerId, "gave " .. cardText(name) .. " to " .. self:playerName(newOwnerId) .. ".")
  else
    self:log(actingPlayerId, "released " .. cardText(name) .. " back to the table.")
  end
  self:notify()
end

-- Whether card instanceId may join the pile containing ontoInstanceId.
-- Piles never mix owners: the card's owner once stacked (unownable cards
-- become unowned) must match every card in the pile, so your cards only go
-- onto your piles and unowned cards only onto unowned piles.
function Session:canStackOnto(instanceId, ontoInstanceId)
  local card, onto = self:findCard(instanceId), self:findCard(ontoInstanceId)
  if not card or not onto then return false end
  local owner = (not card.unownable) and card.ownerId or nil
  for _, c in ipairs(stacks.stackOf(self.state.cards, stacks.rootIdOf(self.state.cards, onto))) do
    if c.instanceId ~= instanceId and c.ownerId ~= owner then return false end
  end
  return true
end

-- Fails silently (nothing moves) when the pile's owner differs.
function Session:stackCard(instanceId, ontoInstanceId, actingPlayerId)
  if not self:canStackOnto(instanceId, ontoInstanceId) then return end
  local old = self:findCard(instanceId)
  self.state = A.stackCard(self.state, instanceId, ontoInstanceId)
  if old and old.zone ~= "table" then self:logPlayedToTable(actingPlayerId, old, instanceId) end
  self:notify()
end

function Session:reorderHand(instanceId, targetIndex, ownerId)
  self.state = A.reorderHand(self.state, instanceId, ownerId or self.localPlayerId, targetIndex)
  self:notify()
end

function Session:moveToHand(instanceId, ownerId)
  local acting = ownerId or self.localPlayerId
  local old = self:findCard(instanceId)
  self.state = A.moveToHand(self.state, instanceId, acting)
  local name = (old and self:isPubliclyVisible(old)) and self:titleOf(old) or nil
  self:log(acting, name and ('picked up "' .. name .. '" into their hand.') or "picked up a card into their hand.")
  self:notify()
end

function Session:drawCard(pileInstanceId, ownerId, count)
  count = count or 1
  local acting = ownerId or self.localPlayerId
  self.state = A.drawCard(self.state, pileInstanceId, acting, count)
  self:log(acting, count == 1 and "drew a card." or ("drew " .. count .. " cards."))
  self:notify()
end

function Session:shufflePile(pileRootInstanceId, actingPlayerId)
  self.state = A.shufflePile(self.state, pileRootInstanceId)
  self:log(actingPlayerId, "shuffled a pile of cards.")
  self:notify()
end

function Session:drawFromZone(zoneId, zoneOwnerId, toOwnerId, count)
  count = count or 1
  local acting = toOwnerId or self.localPlayerId
  local zoneName = self:zoneDefinition(zoneId).name
  self.state = A.drawFromZone(self.state, zoneId, zoneOwnerId, acting, count)
  self:log(acting, count == 1 and ("drew a card from the " .. zoneName .. ".")
    or ("drew " .. count .. " cards from the " .. zoneName .. "."))
  self:notify()
end

function Session:returnToZone(instanceId, zoneId, zoneOwnerId, toBottom, actingPlayerId)
  local zone = self:zoneDefinition(zoneId)
  local old = self:findCard(instanceId)
  self.state = A.returnToZone(self.state, instanceId, zoneId, zoneOwnerId, zone.faceUp, toBottom)
  local name = self:revealedCardName(old, self:findCard(instanceId))
  if zone.isDiscardPile then
    self:log(actingPlayerId, "discarded " .. cardText(name) .. ".")
  else
    self:log(actingPlayerId, "returned " .. cardText(name) .. " to the " .. zone.name .. ".")
  end
  self:notify()
end

function Session:shuffleZone(zoneId, zoneOwnerId, actingPlayerId)
  local zone = self:zoneDefinition(zoneId)
  if not zone.shuffleable then return end
  self.state = A.shuffleZone(self.state, zoneId, zoneOwnerId)
  self:log(actingPlayerId, "shuffled the " .. zone.name .. ".")
  self:notify()
end

-- A deck can contain multiple subdecks (one per deck-building zone's
-- deckType, e.g. a main deck plus a location deck). Loading it fills every
-- matching zone, not just the one the player clicked - mirroring the
-- per-zone subdeck matching that Session.dealFromZones does for the
-- initial deal.
function Session:loadDeckIntoZone(zoneId, deck, actingPlayerId)
  local targetZone = self:zoneDefinition(zoneId)
  local zones = { targetZone }
  for _, z in ipairs(models.GameDefinition.deckBuildingZones(self.game)) do
    if z.id ~= targetZone.id then zones[#zones + 1] = z end
  end
  local newCards, names = {}, {}
  for _, zone in ipairs(zones) do
    local ids = {}
    for _, e in ipairs(models.DeckConfig.entriesFor(deck, zone.deckType)) do
      if self.definitionsById[e.definitionId] then
        for _ = 1, e.quantity do ids[#ids + 1] = e.definitionId end
      end
    end
    if #ids > 0 then
      if zone.autoShuffle then util.shuffle(ids) end
      -- Note: Flutter stamps the zone definition's own id here (not a deck
      -- widget's synthetic id), matching game_session.dart.
      for _, id in ipairs(ids) do
        newCards[#newCards + 1] = models.CardInstance.new({
          instanceId = uuid.v4(), definitionId = id, x = 0.5, y = 0.5, zIndex = 0, faceUp = zone.faceUp,
          zone = "zone", zoneId = zone.id, ownerId = actingPlayerId, unownable = self.definitionsById[id].unownable,
        })
      end
      names[#names + 1] = zone.name
    end
  end
  self.state = A.dealNewCards(self.state, newCards)
  local label
  if #names <= 1 then
    label = names[1] or targetZone.name
  elseif #names == 2 then
    label = names[1] .. " and " .. names[2]
  else
    label = table.concat(names, ", ", 1, #names - 1) .. ", and " .. names[#names]
  end
  self:log(actingPlayerId, "loaded a deck into the " .. label .. ".")
  self:notify()
end

local function containsString(list, v)
  for _, x in ipairs(list) do
    if x == v then return true end
  end
  return false
end

-- Loads a named scenario: appends its shared zones (skipping any id
-- collision with an existing effective zone), deals each newly added
-- zone's starting cards (or its built subdeck, if dealsBuiltDeck), and
-- spawns its authored table placements. No-op for an unknown scenario or
-- one already loaded this session.
function Session:loadScenario(scenarioId, actingPlayerId)
  local scenario = models.GameDefinition.scenarioById(self.game, scenarioId)
  if not scenario or containsString(self.state.loadedScenarioIds, scenarioId) then return end

  local existingIds = {}
  for _, z in ipairs(self:effectiveZones()) do existingIds[z.id] = true end

  local newZones = {}
  for _, z in ipairs(scenario.zones) do
    if not existingIds[z.id] then
      newZones[#newZones + 1] = z
      existingIds[z.id] = true
    end
  end

  local loadedZones = util.shallowCopy(self.state.loadedZones)
  for _, z in ipairs(newZones) do loadedZones[#loadedZones + 1] = z end
  local loadedScenarioIds = util.shallowCopy(self.state.loadedScenarioIds)
  loadedScenarioIds[#loadedScenarioIds + 1] = scenarioId
  self.state = util.copyWith(self.state, { loadedZones = loadedZones, loadedScenarioIds = loadedScenarioIds })

  local newCards = {}
  for _, zone in ipairs(newZones) do
    local entries = zone.dealsBuiltDeck and models.Scenario.entriesFor(scenario, zone.deckType) or zone.entries
    local ids = {}
    for _, e in ipairs(entries) do
      if self.definitionsById[e.definitionId] then
        for _ = 1, e.quantity do ids[#ids + 1] = e.definitionId end
      end
    end
    if zone.autoShuffle then util.shuffle(ids) end
    for _, id in ipairs(ids) do
      newCards[#newCards + 1] = models.CardInstance.new({
        instanceId = uuid.v4(), definitionId = id, x = 0.5, y = 0.5, zIndex = 0, faceUp = zone.faceUp,
        zone = "zone", zoneId = zone.id, ownerId = nil, unownable = self.definitionsById[id].unownable,
      })
    end
  end

  for _, p in ipairs(scenario.placements) do
    if self.definitionsById[p.definitionId] then
      newCards[#newCards + 1] = models.CardInstance.new({
        instanceId = uuid.v4(), definitionId = p.definitionId, x = p.x, y = p.y, zIndex = 0, faceUp = p.faceUp,
        zone = "table", ownerId = nil, unownable = self.definitionsById[p.definitionId].unownable,
      })
    end
  end

  self.state = A.dealNewCards(self.state, newCards)
  self:log(actingPlayerId, 'loaded the "' .. scenario.name .. '" scenario.')
  self:notify()
end

---------------------------------------------------------------------------
-- Searches
---------------------------------------------------------------------------

function Session:startSearchZone(zoneId, zoneOwnerId, searcherId)
  local acting = searcherId or self.localPlayerId
  local zoneName = self:zoneDefinition(zoneId).name
  self.state = A.startSearch(self.state, acting, "zone", zoneId, zoneOwnerId)
  self:log(acting, "opened a search on the " .. zoneName .. ".")
  self:notify()
end

function Session:startSearchPile(pileRootInstanceId, searcherId)
  local acting = searcherId or self.localPlayerId
  self.state = A.startSearch(self.state, acting, "pile", pileRootInstanceId)
  self:log(acting, "opened a search on a pile of cards.")
  self:notify()
end

function Session:stopSearch(searcherId)
  local acting = searcherId or self.localPlayerId
  local had = util.any(self.state.searches, function(s) return s.searcherId == acting end)
  self.state = A.stopSearch(self.state, acting)
  if had then self:log(acting, "closed their search.") end
  self:notify()
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------

function Session:createWidget(instanceId, kind, x, y, actingPlayerId, imagePath)
  self.state = A.createWidget(self.state, instanceId, kind, x, y, kind == "deckBuilder" and actingPlayerId or nil, imagePath)
  self:notify()
end

function Session:createArrow(instanceId, x, y, x2, y2, creatorId)
  self.state = A.createArrow(self.state, instanceId, x, y, x2, y2, creatorId)
  self:notify()
  self:after(Session.arrowLifetime, function()
    if self:findWidget(instanceId) then self:deleteWidget(instanceId) end
  end)
end

function Session:moveWidget(instanceId, x, y)
  self.state = A.moveWidget(self.state, instanceId, x, y)
  self:notify()
end

function Session:setWidgetValue(instanceId, value, actingPlayerId)
  local widget = self:findWidget(instanceId)
  self.state = A.setWidgetValue(self.state, instanceId, value)
  if widget and widget.kind == "simpleCounter" then
    local clamped = util.clamp(value, models.boardWidgetCounterMin, models.boardWidgetCounterMax)
    local label = widget.zoneId and self:zoneDefinition(widget.zoneId).name or "a counter"
    self:log(actingPlayerId, "set " .. label .. " to " .. clamped .. ".")
  end
  self:notify()
end

function Session:deleteWidget(instanceId)
  self.state = A.deleteWidget(self.state, instanceId)
  self:notify()
end

function Session:setWidgetColors(instanceId, backgroundColor, textColor)
  self.state = A.setWidgetColors(self.state, instanceId, backgroundColor, textColor)
  self:notify()
end

function Session:duplicateWidget(sourceInstanceId, newInstanceId, x, y)
  self.state = A.duplicateWidget(self.state, sourceInstanceId, newInstanceId, x, y)
  self:notify()
end

local KIND_LABELS = { simpleCounter = "a counter", token = "a token" }

function Session:attachWidgetToCard(instanceId, cardId, x, y, actingPlayerId)
  local widget = self:findWidget(instanceId)
  local card = self:findCard(cardId)
  self.state = A.attachWidgetToCard(self.state, instanceId, cardId, x, y)
  local kindLabel = widget and KIND_LABELS[widget.kind] or "a widget"
  local name = (card and self:isPubliclyVisible(card)) and self:titleOf(card) or nil
  self:log(actingPlayerId, "attached " .. kindLabel .. " to " .. cardText(name) .. ".")
  self:notify()
end

function Session:generatePack(setId, actingPlayerId, rng)
  local set = util.find(self.game.sets, function(s) return s.id == setId end)
  local setCards = util.filter(self.game.cards, function(c) return c.setId == setId end)
  local selected = packs.selectPackCards(setCards, set and set.packSettings or {}, rng)
  local newCards = util.map(selected, function(def)
    return models.CardInstance.new({
      instanceId = uuid.v4(), definitionId = def.id, x = 0.5, y = 0.5, zIndex = 0, faceUp = true,
      zone = "hand", ownerId = actingPlayerId, unownable = def.unownable,
    })
  end)
  self.state = A.dealNewCards(self.state, newCards)
  self:log(actingPlayerId, "generated a pack from the " .. (set and set.name or setId) .. " set.")
  self:notify()
end

function Session:createCardFromLibrary(definitionId, x, y, actingPlayerId)
  local def = self.definitionsById[definitionId]
  if not def then return end
  self.state = A.dealNewCards(self.state, { models.CardInstance.new({
    instanceId = uuid.v4(), definitionId = definitionId, x = x, y = y, zIndex = 0, faceUp = true,
    zone = "table", ownerId = actingPlayerId, unownable = def.unownable,
  }) })
  self:log(actingPlayerId, 'created "' .. def.cardTitle .. '" from the card library.')
  self:notify()
end

---------------------------------------------------------------------------
-- Networking hooks
---------------------------------------------------------------------------

-- Client side: adopt a newer host state.
function Session:applyRemoteState(newState)
  if newState.revision <= self.state.revision then return end
  self.state = newState
  self:notify()
end

-- Host side: connectedNonHostIds is a set {id -> true}.
function Session:syncConnectedPlayerIds(connectedNonHostIds)
  local updated = {}
  for i, p in ipairs(self.state.players) do
    local now = p.role == "host" or connectedNonHostIds[p.id] == true
    if now ~= p.connected then self:log(p.id, now and "connected." or "disconnected.") end
    updated[i] = util.copyWith(p, { connected = now })
  end
  self.state = util.copyWith(self.state, { players = updated, revision = self.state.revision + 1 })
  self:notify()
end

return Session
