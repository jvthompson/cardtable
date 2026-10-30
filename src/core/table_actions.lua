-- Port of lib/game/table_actions.dart: pure state transitions. Every
-- function takes a TableState and returns a new TableState (copy-on-write:
-- untouched cards/widgets are shared, changed ones are fresh tables), so the
-- caller can still diff old vs new for logging. Revision bumps exactly where
-- the Dart version bumps (including when the target id isn't found, for the
-- ops where Dart doesn't guard).
local models = require("src.core.models")
local util = require("src.core.util")
local stacks = require("src.core.stack_utils")
local dwz = require("src.core.deck_widget_zones")

local NIL = util.NIL
local copyWith = util.copyWith

local A = {}

local function withState(state, changes)
  return copyWith(state, changes)
end

local function bumped(state, changes)
  changes = changes or {}
  changes.revision = state.revision + 1
  return withState(state, changes)
end

local function nextZIndex(state)
  if #state.cards == 0 then return 0 end
  local m = state.cards[1].zIndex
  for i = 2, #state.cards do
    if state.cards[i].zIndex > m then m = state.cards[i].zIndex end
  end
  return m + 1
end
A.nextZIndex = nextZIndex

local function findById(state, id)
  return models.TableState.cardById(state, id)
end

local function mapCards(state, fn)
  local out = {}
  for i, c in ipairs(state.cards) do out[i] = fn(c) end
  return out
end

local function mapWidgets(state, fn)
  local out = {}
  for i, w in ipairs(state.widgets) do out[i] = fn(w) end
  return out
end

local function idSet(list)
  local s = {}
  for _, c in ipairs(list) do s[c.instanceId] = true end
  return s
end

-- Keeps every card-attached widget at its card's position + attach offset.
local function syncAttachedWidgets(state)
  if #state.widgets == 0 then return state end
  local changed = false
  local widgets = mapWidgets(state, function(w)
    local attachedId = w.attachedCardId
    if attachedId == nil then return w end
    local card = findById(state, attachedId)
    if card == nil then return w end
    local newX, newY = card.x + w.attachOffsetX, card.y + w.attachOffsetY
    if w.x == newX and w.y == newY then return w end
    changed = true
    return copyWith(w, { x = newX, y = newY })
  end)
  if not changed then return state end
  return withState(state, { widgets = widgets })
end

function A.moveCard(state, instanceId, x, y)
  local nextZ = nextZIndex(state)
  local cards = mapCards(state, function(c)
    if c.instanceId ~= instanceId then return c end
    return copyWith(c, {
      x = x, y = y, zone = "table", stackParentId = NIL, zoneId = NIL, zIndex = nextZ,
      ownerId = c.unownable and NIL or c.ownerId or NIL,
    })
  end)
  return syncAttachedWidgets(bumped(state, { cards = cards }))
end

function A.moveStack(state, rootInstanceId, x, y)
  local stack = stacks.stackOf(state.cards, rootInstanceId)
  if #stack == 0 then return state end
  local ids = idSet(stack)
  local topId = stacks.topOf(stack).instanceId
  local nextZ = nextZIndex(state)
  local cards = mapCards(state, function(c)
    if not ids[c.instanceId] then return c end
    return copyWith(c, { x = x, y = y, zIndex = c.instanceId == topId and nextZ or c.zIndex })
  end)
  return syncAttachedWidgets(bumped(state, { cards = cards }))
end

function A.rotateStack(state, rootInstanceId, clockwise)
  local stack = stacks.stackOf(state.cards, rootInstanceId)
  if #stack == 0 then return state end
  local ids = idSet(stack)
  local topId = stacks.topOf(stack).instanceId
  local nextZ = nextZIndex(state)
  local delta = clockwise and 1 or -1
  local cards = mapCards(state, function(c)
    if not ids[c.instanceId] or c.zone ~= "table" then return c end
    return copyWith(c, {
      rotationTurns = c.rotationTurns + delta,
      zIndex = c.instanceId == topId and nextZ or c.zIndex,
    })
  end)
  return bumped(state, { cards = cards })
end

function A.bringToFront(state, rootInstanceId)
  local stack = stacks.stackOf(state.cards, rootInstanceId)
  if #stack == 0 then return state end
  local topId = stacks.topOf(stack).instanceId
  local nextZ = nextZIndex(state)
  local cards = mapCards(state, function(c)
    if c.instanceId ~= topId then return c end
    return copyWith(c, { zIndex = nextZ })
  end)
  return bumped(state, { cards = cards })
end

function A.moveToHand(state, instanceId, ownerId)
  local nextZ = nextZIndex(state)
  local cards = mapCards(state, function(c)
    if c.instanceId ~= instanceId then return c end
    return copyWith(c, {
      zone = "hand", ownerId = ownerId, faceUp = true, stackParentId = NIL, zoneId = NIL,
      rotationTurns = 0, zIndex = nextZ,
    })
  end)
  return bumped(state, { cards = cards })
end

local function sortedByZ(list)
  -- Stable sort by zIndex (Dart's List.sort is not guaranteed stable, but
  -- hands never share a zIndex in practice; stability keeps tests deterministic).
  local indexed = {}
  for i, c in ipairs(list) do indexed[i] = { c = c, i = i } end
  table.sort(indexed, function(a, b)
    if a.c.zIndex ~= b.c.zIndex then return a.c.zIndex < b.c.zIndex end
    return a.i < b.i
  end)
  local out = {}
  for i, e in ipairs(indexed) do out[i] = e.c end
  return out
end
A.sortedByZ = sortedByZ

function A.handCards(state, ownerId)
  return sortedByZ(util.filter(state.cards, function(c) return c.zone == "hand" and c.ownerId == ownerId end))
end

function A.reorderHand(state, instanceId, ownerId, targetIndex)
  local hand = A.handCards(state, ownerId)
  local currentIndex
  for i, c in ipairs(hand) do
    if c.instanceId == instanceId then currentIndex = i break end
  end
  if not currentIndex then return state end
  local moved = table.remove(hand, currentIndex)
  -- targetIndex is 0-based like Dart's, clamped to [0, len].
  local t = util.clamp(targetIndex, 0, #hand)
  table.insert(hand, t + 1, moved)
  local baseZ = nextZIndex(state)
  local newZ = {}
  for i, c in ipairs(hand) do newZ[c.instanceId] = baseZ + i - 1 end
  local cards = mapCards(state, function(c)
    local z = newZ[c.instanceId]
    if z == nil then return c end
    return copyWith(c, { zIndex = z })
  end)
  return bumped(state, { cards = cards })
end

function A.flipCard(state, instanceId)
  local nextZ = nextZIndex(state)
  local cards = mapCards(state, function(c)
    if c.instanceId ~= instanceId then return c end
    return copyWith(c, { faceUp = not c.faceUp, zIndex = nextZ })
  end)
  return bumped(state, { cards = cards })
end

function A.giveCard(state, instanceId, newOwnerId)
  local nextZ = nextZIndex(state)
  local cards = mapCards(state, function(c)
    if c.instanceId ~= instanceId then return c end
    local owner = (c.unownable or newOwnerId == nil) and NIL or newOwnerId
    return copyWith(c, { ownerId = owner, zIndex = nextZ })
  end)
  return bumped(state, { cards = cards })
end

function A.stackCard(state, instanceId, ontoInstanceId)
  if instanceId == ontoInstanceId then return state end
  local target = findById(state, ontoInstanceId)
  if target == nil then return state end
  local nextZ = nextZIndex(state)
  local cards = mapCards(state, function(c)
    if c.instanceId ~= instanceId then return c end
    return copyWith(c, {
      x = target.x, y = target.y, zone = target.zone, stackParentId = ontoInstanceId, zoneId = NIL,
      zIndex = nextZ, ownerId = c.unownable and NIL or c.ownerId or NIL,
    })
  end)
  return syncAttachedWidgets(bumped(state, { cards = cards }))
end

function A.moveGroup(state, primaryInstanceId, passengerRootInstanceIds, x, y)
  local primary = findById(state, primaryInstanceId)
  if primary == nil then return state end
  local dx, dy = x - primary.x, y - primary.y
  local nextZ = nextZIndex(state)
  local primaryNewZ = nextZ
  nextZ = nextZ + 1
  local passengerTopNewZ, passengerIds = {}, {}
  for _, rootId in ipairs(passengerRootInstanceIds) do
    local stack = stacks.stackOf(state.cards, rootId)
    if #stack > 0 then
      for _, c in ipairs(stack) do passengerIds[c.instanceId] = true end
      passengerTopNewZ[stacks.topOf(stack).instanceId] = nextZ
      nextZ = nextZ + 1
    end
  end
  local cards = mapCards(state, function(c)
    if c.instanceId == primaryInstanceId then
      return copyWith(c, {
        x = x, y = y, zone = "table", stackParentId = NIL, zoneId = NIL, zIndex = primaryNewZ,
        ownerId = c.unownable and NIL or c.ownerId or NIL,
      })
    end
    if passengerIds[c.instanceId] then
      return copyWith(c, { x = c.x + dx, y = c.y + dy, zIndex = passengerTopNewZ[c.instanceId] or c.zIndex })
    end
    return c
  end)
  return syncAttachedWidgets(bumped(state, { cards = cards }))
end

local function applyDrawn(state, drawnIds, changesFor)
  local baseZ = nextZIndex(state)
  local newZ = {}
  for i, id in ipairs(drawnIds) do newZ[id] = baseZ + i - 1 end
  local cards = mapCards(state, function(c)
    local z = newZ[c.instanceId]
    if z == nil then return c end
    local ch = changesFor(c)
    ch.zIndex = z
    return copyWith(c, ch)
  end)
  return bumped(state, { cards = cards })
end

-- Returns new state and the list of drawn instance ids (in draw order).
function A.drawCard(state, pileInstanceId, ownerId, count)
  count = count or 1
  local stack = stacks.stackOf(state.cards, pileInstanceId)
  if #stack == 0 or count <= 0 then return state, {} end
  local remaining = util.shallowCopy(stack)
  local drawnIds = {}
  local i = 0
  while i < count and #remaining > 0 do
    local candidates = remaining
    if #remaining > 1 then
      candidates = util.filter(remaining, function(c) return c.instanceId ~= pileInstanceId end)
    end
    local top = stacks.topOf(candidates)
    drawnIds[#drawnIds + 1] = top.instanceId
    remaining = util.filter(remaining, function(c) return c.instanceId ~= top.instanceId end)
    i = i + 1
  end
  if #drawnIds == 0 then return state, {} end
  return applyDrawn(state, drawnIds, function()
    return { zone = "hand", ownerId = ownerId, faceUp = true, stackParentId = NIL, rotationTurns = 0 }
  end), drawnIds
end

function A.zoneCards(state, zoneId, zoneOwnerId)
  return util.filter(state.cards, function(c)
    return c.zone == "zone" and c.zoneId == zoneId and c.ownerId == zoneOwnerId
  end)
end

function A.drawFromZone(state, zoneId, zoneOwnerId, toOwnerId, count)
  count = count or 1
  local zoneCards = A.zoneCards(state, zoneId, zoneOwnerId)
  if #zoneCards == 0 or count <= 0 then return state, {} end
  local remaining = util.shallowCopy(zoneCards)
  local drawnIds = {}
  local i = 0
  while i < count and #remaining > 0 do
    local top = stacks.topOf(remaining)
    drawnIds[#drawnIds + 1] = top.instanceId
    remaining = util.filter(remaining, function(c) return c.instanceId ~= top.instanceId end)
    i = i + 1
  end
  if #drawnIds == 0 then return state, {} end
  return applyDrawn(state, drawnIds, function()
    return { zone = "hand", ownerId = toOwnerId, faceUp = true, zoneId = NIL, rotationTurns = 0 }
  end), drawnIds
end

function A.dealNewCards(state, newCards)
  if #newCards == 0 then return state end
  local baseZ = nextZIndex(state)
  local cards = util.shallowCopy(state.cards)
  for i, c in ipairs(newCards) do
    cards[#cards + 1] = copyWith(c, { zIndex = baseZ + i - 1 })
  end
  return bumped(state, { cards = cards })
end

function A.returnToZone(state, instanceId, zoneId, zoneOwnerId, faceUp, toBottom)
  local zoneCards = A.zoneCards(state, zoneId, zoneOwnerId)
  for _, c in ipairs(zoneCards) do
    if c.instanceId == instanceId then return state end
  end
  local newZ
  if toBottom and #zoneCards > 0 then
    local m = zoneCards[1].zIndex
    for _, c in ipairs(zoneCards) do
      if c.zIndex < m then m = c.zIndex end
    end
    newZ = m - 1
  else
    newZ = nextZIndex(state)
  end
  local anchor = zoneCards[1]
  local cards = mapCards(state, function(c)
    if c.instanceId ~= instanceId then return c end
    return copyWith(c, {
      x = anchor and anchor.x or c.x,
      y = anchor and anchor.y or c.y,
      zone = "zone", zoneId = zoneId, ownerId = zoneOwnerId == nil and NIL or zoneOwnerId,
      faceUp = faceUp, stackParentId = NIL, rotationTurns = 0, zIndex = newZ,
    })
  end)
  return bumped(state, { cards = cards })
end

local function reshuffle(state, list, seed)
  local ids = util.map(list, function(c) return c.instanceId end)
  util.shuffle(ids, seed and util.seededRng(seed) or nil)
  local baseZ = nextZIndex(state)
  local newZ = {}
  for i, id in ipairs(ids) do newZ[id] = baseZ + i - 1 end
  local cards = mapCards(state, function(c)
    local z = newZ[c.instanceId]
    if z == nil then return c end
    return copyWith(c, { zIndex = z, faceUp = false })
  end)
  return bumped(state, { cards = cards })
end

function A.shuffleZone(state, zoneId, zoneOwnerId, seed)
  local zoneCards = A.zoneCards(state, zoneId, zoneOwnerId)
  if #zoneCards < 2 then return state end
  return reshuffle(state, zoneCards, seed)
end

function A.shufflePile(state, pileRootInstanceId, seed)
  local stack = stacks.stackOf(state.cards, pileRootInstanceId)
  if #stack < 2 then return state end
  return reshuffle(state, stack, seed)
end

---------------------------------------------------------------------------
-- Searches
---------------------------------------------------------------------------

function A.startSearch(state, searcherId, targetType, targetId, targetOwnerId)
  local searches = util.filter(state.searches, function(s) return s.searcherId ~= searcherId end)
  searches[#searches + 1] = models.ActiveSearch.new({
    searcherId = searcherId, targetType = targetType, targetId = targetId, targetOwnerId = targetOwnerId,
  })
  return bumped(state, { searches = searches })
end

function A.stopSearch(state, searcherId)
  local searches = util.filter(state.searches, function(s) return s.searcherId ~= searcherId end)
  if #searches == #state.searches then return state end
  return bumped(state, { searches = searches })
end

---------------------------------------------------------------------------
-- Board widgets
---------------------------------------------------------------------------

local function nextWidgetZIndex(state)
  if #state.widgets == 0 then return 0 end
  local m = state.widgets[1].zIndex
  for i = 2, #state.widgets do
    if state.widgets[i].zIndex > m then m = state.widgets[i].zIndex end
  end
  return m + 1
end

local function appendWidget(state, w)
  local widgets = util.shallowCopy(state.widgets)
  widgets[#widgets + 1] = w
  return bumped(state, { widgets = widgets })
end

function A.createWidget(state, instanceId, kind, x, y, ownerId, imagePath)
  return appendWidget(state, models.BoardWidgetInstance.new({
    instanceId = instanceId, kind = kind, x = x, y = y, zIndex = nextWidgetZIndex(state), ownerId = ownerId,
    imagePath = imagePath,
  }))
end

-- Adds a widget with extra fields (used by the initial deal for docked
-- counters): fields override the defaults and zIndex is assigned here.
function A.addWidget(state, fields)
  local f = util.shallowCopy(fields)
  f.zIndex = nextWidgetZIndex(state)
  return appendWidget(state, models.BoardWidgetInstance.new(f))
end

function A.createArrow(state, instanceId, x, y, x2, y2, creatorId)
  return appendWidget(state, models.BoardWidgetInstance.new({
    instanceId = instanceId, kind = "arrow", x = x, y = y, x2 = x2, y2 = y2, creatorId = creatorId,
    zIndex = nextWidgetZIndex(state),
  }))
end

function A.moveWidget(state, instanceId, x, y)
  local nextZ = nextWidgetZIndex(state)
  local widgets = mapWidgets(state, function(w)
    if w.instanceId ~= instanceId then return w end
    return copyWith(w, { x = x, y = y, zIndex = nextZ, attachedCardId = NIL, attachOffsetX = 0, attachOffsetY = 0 })
  end)
  return bumped(state, { widgets = widgets })
end

function A.attachWidgetToCard(state, instanceId, cardId, x, y)
  local card = findById(state, cardId)
  if card == nil then return state end
  local nextZ = nextWidgetZIndex(state)
  local widgets = mapWidgets(state, function(w)
    if w.instanceId ~= instanceId then return w end
    return copyWith(w, {
      x = x, y = y, zIndex = nextZ, attachedCardId = cardId, attachOffsetX = x - card.x, attachOffsetY = y - card.y,
    })
  end)
  return bumped(state, { widgets = widgets })
end

function A.setWidgetValue(state, instanceId, value)
  local clamped = util.clamp(value, models.boardWidgetCounterMin, models.boardWidgetCounterMax)
  local widgets = mapWidgets(state, function(w)
    if w.instanceId ~= instanceId then return w end
    return copyWith(w, { value = clamped })
  end)
  return bumped(state, { widgets = widgets })
end

function A.deleteWidget(state, instanceId)
  local removed
  for _, w in ipairs(state.widgets) do
    if w.instanceId == instanceId then removed = w break end
  end
  local cards = state.cards
  if removed ~= nil and removed.kind == "deckBuilder" then
    -- Spill the deck widget's held cards onto the table at its position.
    local baseZ = nextZIndex(state)
    local i = 0
    cards = mapCards(state, function(c)
      if c.zone ~= "zone" then return c end
      local parsed = dwz.parse(c.zoneId or "")
      if parsed == nil or parsed.widgetInstanceId ~= instanceId then return c end
      local spilled = copyWith(c, {
        zone = "table", zoneId = NIL, stackParentId = NIL, x = removed.x, y = removed.y, zIndex = baseZ + i,
        ownerId = c.unownable and NIL or c.ownerId or NIL,
      })
      i = i + 1
      return spilled
    end)
  end
  local widgets = util.filter(state.widgets, function(w) return w.instanceId ~= instanceId end)
  return bumped(state, { cards = cards, widgets = widgets })
end

function A.setWidgetColors(state, instanceId, backgroundColor, textColor)
  local widgets = mapWidgets(state, function(w)
    if w.instanceId ~= instanceId then return w end
    return copyWith(w, { backgroundColor = backgroundColor, textColor = textColor })
  end)
  return bumped(state, { widgets = widgets })
end

function A.duplicateWidget(state, sourceInstanceId, newInstanceId, x, y)
  local source
  for _, w in ipairs(state.widgets) do
    if w.instanceId == sourceInstanceId then source = w break end
  end
  if source == nil then return state end
  return appendWidget(state, models.BoardWidgetInstance.new({
    instanceId = newInstanceId, kind = source.kind, x = x, y = y, zIndex = nextWidgetZIndex(state),
    value = source.value, backgroundColor = source.backgroundColor, textColor = source.textColor,
    imagePath = source.imagePath,
  }))
end

---------------------------------------------------------------------------
-- Token bag (a kind="widget" zone's "tokenBag" widgetKind)
---------------------------------------------------------------------------

-- Appends every widget in newWidgets with sequential zIndex, one revision
-- bump total (used when a scenario loads new widget-kind zones; mirrors
-- A.dealNewCards).
function A.addWidgets(state, newWidgets)
  if #newWidgets == 0 then return state end
  local baseZ = nextWidgetZIndex(state)
  local widgets = util.shallowCopy(state.widgets)
  for i, w in ipairs(newWidgets) do widgets[#widgets + 1] = copyWith(w, { zIndex = baseZ + i - 1 }) end
  return bumped(state, { widgets = widgets })
end

-- Moves one occurrence of imagePath out of the bag's bagRemaining into
-- bagRevealed under slotId.
function A.revealBagToken(state, instanceId, imagePath, slotId)
  local widgets = mapWidgets(state, function(w)
    if w.instanceId ~= instanceId then return w end
    local remaining = util.shallowCopy(w.bagRemaining)
    for i, p in ipairs(remaining) do
      if p == imagePath then
        table.remove(remaining, i)
        break
      end
    end
    local revealed = util.shallowCopy(w.bagRevealed)
    revealed[#revealed + 1] = models.RevealedToken.new(slotId, imagePath)
    return copyWith(w, { bagRemaining = remaining, bagRevealed = revealed })
  end)
  return bumped(state, { widgets = widgets })
end

-- Removes slotId from bagRevealed; its image goes back into bagRemaining
-- only when returnToBag (otherwise it's gone until the bag is reset).
function A.resolveBagToken(state, instanceId, slotId, returnToBag)
  local widgets = mapWidgets(state, function(w)
    if w.instanceId ~= instanceId then return w end
    local entry, revealed = nil, {}
    for _, r in ipairs(w.bagRevealed) do
      if r.slotId == slotId then entry = r else revealed[#revealed + 1] = r end
    end
    if not entry then return w end
    local remaining = w.bagRemaining
    if returnToBag then
      remaining = util.shallowCopy(remaining)
      remaining[#remaining + 1] = entry.imagePath
    end
    return copyWith(w, { bagRemaining = remaining, bagRevealed = revealed })
  end)
  return bumped(state, { widgets = widgets })
end

-- Removes slotId from the bag's bagRevealed and appends a brand-new free
-- imageToken widget at (x, y) carrying that token's image. `size` (when
-- given) becomes the new widget's sizeOverride; "native" renders the token
-- at the image's own actual pixel size rather than shrinking to the default
-- imageToken marker size.
function A.placeBagTokenOnTable(state, instanceId, slotId, newInstanceId, x, y, ownerId, size)
  local revealedEntry
  for _, w in ipairs(state.widgets) do
    if w.instanceId == instanceId then
      for _, r in ipairs(w.bagRevealed) do
        if r.slotId == slotId then revealedEntry = r end
      end
    end
  end
  if not revealedEntry then return state end
  local widgets = mapWidgets(state, function(w)
    if w.instanceId ~= instanceId then return w end
    return copyWith(w, { bagRevealed = util.filter(w.bagRevealed, function(r) return r.slotId ~= slotId end) })
  end)
  widgets[#widgets + 1] = models.BoardWidgetInstance.new({
    instanceId = newInstanceId, kind = "imageToken", x = x, y = y, zIndex = nextWidgetZIndex(state),
    imagePath = revealedEntry.imagePath, ownerId = ownerId, sizeOverride = size,
  })
  return bumped(state, { widgets = widgets })
end

-- Restores the bag to a freshly-expanded pool and clears anything revealed
-- (tokens already placed on the table as free imageToken widgets are left
-- untouched -- they have no further relationship to the bag by then).
function A.resetBag(state, instanceId, freshRemaining)
  local widgets = mapWidgets(state, function(w)
    if w.instanceId ~= instanceId then return w end
    return copyWith(w, { bagRemaining = freshRemaining, bagRevealed = {} })
  end)
  return bumped(state, { widgets = widgets })
end

-- Deletes a free imageToken widget outright (dragged back onto a bag);
-- when returnToBag, its image is pushed onto the target bag's
-- bagRemaining instead of just vanishing. Not scoped to "this token came
-- from this bag" -- any imageToken dropped on any bag is put away there.
function A.returnImageTokenToBag(state, bagInstanceId, tokenInstanceId, returnToBag)
  local token
  for _, w in ipairs(state.widgets) do
    if w.instanceId == tokenInstanceId then token = w end
  end
  if not token then return state end
  local widgets = util.filter(state.widgets, function(w) return w.instanceId ~= tokenInstanceId end)
  if returnToBag then
    widgets = util.map(widgets, function(w)
      if w.instanceId ~= bagInstanceId then return w end
      local remaining = util.shallowCopy(w.bagRemaining)
      remaining[#remaining + 1] = token.imagePath
      return copyWith(w, { bagRemaining = remaining })
    end)
  end
  return bumped(state, { widgets = widgets })
end

return A
