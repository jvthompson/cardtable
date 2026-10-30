-- Data models: port of lib/models/*.dart.
--
-- Models are plain Lua tables. Each kind has `new(fields)` (fills defaults),
-- `fromJson(t)` and `toJson(obj)`. toJson reproduces Dart's sparse JSON
-- exactly: fields equal to their default are omitted, keys keep Dart's order.
-- Update models with util.copyWith(obj, {...}); util.NIL clears a field.
local json = require("lib.json")
local util = require("src.core.util")

local M = {}

local function arr(list) return json.array(list or {}) end
-- Builds an ordered JSON object from alternating key/value args; nil values
-- are skipped (false is kept).
local function obj(...)
  local o = json.object()
  local n = select("#", ...)
  local args = { ... }
  for i = 1, n, 2 do
    local v = args[i + 1]
    if v ~= nil then o[args[i]] = v end
  end
  return o
end

local function mapJson(list, fn)
  local out = {}
  for i, v in ipairs(list or {}) do out[i] = fn(v) end
  return out
end

local function stringList(list)
  local out = {}
  for i, v in ipairs(list or {}) do out[i] = v end
  return out
end

local function requireField(t, key, kind)
  local v = t[key]
  if v == nil then error(string.format("%s: missing required field '%s'", kind, key), 0) end
  return v
end

-- When a field equals its default, return nil so it's omitted from JSON.
local function unlessDefault(v, default)
  if v == default then return nil end
  return v
end

local function nonEmptyList(list, fn)
  if list == nil or #list == 0 then return nil end
  return arr(fn and mapJson(list, fn) or stringList(list))
end

local function enumValue(v, allowed, default, kind)
  if v == nil then return default end
  if not allowed[v] then error(string.format("%s: invalid value '%s'", kind, tostring(v)), 0) end
  return v
end

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

M.CardOrientation = { portrait = true, left = true, right = true }
M.CardZone = { table = true, hand = true, zone = true }
M.BoardWidgetKind = { simpleCounter = true, token = true, imageToken = true, arrow = true, packGenerator = true,
  deckBuilder = true, tokenBag = true }
M.SharedZoneSide = { left = true, right = true }
M.ZoneKind = { card = true, widget = true }
-- Adding a new kind here needs fields in BOTH src/ui/screens/gamedef/zones_tab.lua's
-- T:drawWidgetZoneFields AND scenario_tab.lua's T.drawScenarioZoneDetail widget
-- branch -- the Token Bag and Counter-image features each initially missed the
-- scenario side.
M.ZoneWidgetKind = { counter = true, tokenBag = true }
M.PlayerRole = { host = true, client = true }
M.SearchTargetType = { zone = true, pile = true }

M.hiddenDefinitionId = "__hidden__"
M.uniqueCardBackId = "__unique__"
M.cardBackFileSuffix = "_BACK"
M.standardDeckIdPrefix = "__standard52_"

M.boardWidgetCounterMin = 0
M.boardWidgetCounterMax = 99999
M.defaultBoardWidgetBackgroundColor = 0xFF455A64
M.defaultBoardWidgetTextColor = 0xFFFFFFFF

---------------------------------------------------------------------------
-- CardDefinition
---------------------------------------------------------------------------

local CardDefinition = {}
M.CardDefinition = CardDefinition

function CardDefinition.new(f)
  return {
    id = f.id,
    cardTitle = f.cardTitle,
    colorHex = f.colorHex,
    suit = f.suit,
    rank = f.rank,
    imagePath = f.imagePath,
    extraFields = f.extraFields or {},
    types = f.types or {},
    orientation = f.orientation or "portrait",
    setId = f.setId,
    unownable = f.unownable or false,
    isFreeCard = f.isFreeCard or false,
    cardBackId = f.cardBackId,
    uniqueBackOrientation = f.uniqueBackOrientation or "portrait",
    isScenarioCard = f.isScenarioCard or false,
  }
end

function CardDefinition.fromJson(t)
  local extra = {}
  if t.extraFields then
    for k, v in pairs(t.extraFields) do extra[k] = v end
  end
  return CardDefinition.new({
    id = requireField(t, "id", "CardDefinition"),
    cardTitle = requireField(t, "cardTitle", "CardDefinition"),
    colorHex = t.colorHex,
    suit = t.suit,
    rank = t.rank,
    imagePath = t.imagePath,
    extraFields = extra,
    types = stringList(t.types),
    orientation = enumValue(t.orientation, M.CardOrientation, "portrait", "CardDefinition.orientation"),
    setId = t.setId,
    unownable = t.unownable == true,
    isFreeCard = t.isFreeCard == true,
    cardBackId = t.cardBackId,
    uniqueBackOrientation = enumValue(t.uniqueBackOrientation, M.CardOrientation, "portrait",
      "CardDefinition.uniqueBackOrientation"),
    isScenarioCard = t.isScenarioCard == true,
  })
end

-- Preserve the extraFields key order where we have it (decoded tables carry
-- it); otherwise sort keys for stable output.
local function extraFieldsJson(extra)
  if extra == nil or next(extra) == nil then return nil end
  local mt = getmetatable(extra)
  if mt and mt.__order then return extra end
  local keys = {}
  for k in pairs(extra) do keys[#keys + 1] = k end
  table.sort(keys)
  local o = json.object()
  for _, k in ipairs(keys) do o[k] = extra[k] end
  return o
end

function CardDefinition.toJson(c, omitSetId)
  return obj(
    "id", c.id,
    "cardTitle", c.cardTitle,
    "colorHex", c.colorHex,
    "suit", c.suit,
    "rank", c.rank,
    "imagePath", c.imagePath,
    "extraFields", extraFieldsJson(c.extraFields),
    "types", nonEmptyList(c.types),
    "orientation", unlessDefault(c.orientation, "portrait"),
    "setId", (not omitSetId) and c.setId or nil,
    "unownable", c.unownable and true or nil,
    "isFreeCard", c.isFreeCard and true or nil,
    "cardBackId", c.cardBackId,
    "uniqueBackOrientation", unlessDefault(c.uniqueBackOrientation, "portrait"),
    "isScenarioCard", c.isScenarioCard and true or nil
  )
end

---------------------------------------------------------------------------
-- CardBackDefinition
---------------------------------------------------------------------------

local CardBackDefinition = {}
M.CardBackDefinition = CardBackDefinition

function CardBackDefinition.new(f)
  return { id = f.id, name = f.name, imagePath = f.imagePath, orientation = f.orientation or "portrait" }
end

function CardBackDefinition.fromJson(t)
  return CardBackDefinition.new({
    id = requireField(t, "id", "CardBackDefinition"),
    name = requireField(t, "name", "CardBackDefinition"),
    imagePath = t.imagePath,
    orientation = enumValue(t.orientation, M.CardOrientation, "portrait", "CardBackDefinition.orientation"),
  })
end

function CardBackDefinition.toJson(b)
  return obj("id", b.id, "name", b.name, "imagePath", b.imagePath,
    "orientation", unlessDefault(b.orientation, "portrait"))
end

---------------------------------------------------------------------------
-- PackSetting / GameSet / TagGroup
---------------------------------------------------------------------------

local PackSetting = {}
M.PackSetting = PackSetting

function PackSetting.new(f) return { tag = f.tag, count = f.count } end

function PackSetting.fromJson(t)
  return PackSetting.new({ tag = requireField(t, "tag", "PackSetting"), count = requireField(t, "count", "PackSetting") })
end

function PackSetting.toJson(p) return obj("tag", p.tag, "count", p.count) end

local GameSet = {}
M.GameSet = GameSet

function GameSet.new(f) return { id = f.id, name = f.name, packSettings = f.packSettings or {} } end

function GameSet.fromJson(t)
  return GameSet.new({
    id = requireField(t, "id", "GameSet"),
    name = requireField(t, "name", "GameSet"),
    packSettings = mapJson(t.packSettings, PackSetting.fromJson),
  })
end

function GameSet.toJson(s)
  return obj("id", s.id, "name", s.name, "packSettings", nonEmptyList(s.packSettings, PackSetting.toJson))
end

local TagGroup = {}
M.TagGroup = TagGroup

function TagGroup.new(f) return { id = f.id, name = f.name, tags = f.tags or {} } end

function TagGroup.fromJson(t)
  return TagGroup.new({
    id = requireField(t, "id", "TagGroup"),
    name = requireField(t, "name", "TagGroup"),
    tags = stringList(t.tags),
  })
end

function TagGroup.toJson(g) return obj("id", g.id, "name", g.name, "tags", arr(stringList(g.tags))) end

---------------------------------------------------------------------------
-- DeckEntry / SubDeck / DeckConfig
---------------------------------------------------------------------------

local DeckEntry = {}
M.DeckEntry = DeckEntry

function DeckEntry.new(definitionId, quantity) return { definitionId = definitionId, quantity = quantity } end

function DeckEntry.fromJson(t)
  return DeckEntry.new(requireField(t, "definitionId", "DeckEntry"), requireField(t, "quantity", "DeckEntry"))
end

function DeckEntry.toJson(e) return obj("definitionId", e.definitionId, "quantity", e.quantity) end

local SubDeck = {}
M.SubDeck = SubDeck

function SubDeck.new(name, entries) return { name = name, entries = entries or {} } end

function SubDeck.fromJson(t)
  return SubDeck.new(requireField(t, "name", "SubDeck"), mapJson(requireField(t, "entries", "SubDeck"), DeckEntry.fromJson))
end

function SubDeck.toJson(s) return obj("name", s.name, "entries", arr(mapJson(s.entries, DeckEntry.toJson))) end

-- Raised (as an error table) when a deck file predates the subdeck format.
M.LegacyDeckFormatError = {
  legacyDeckFormat = true,
  message = "This deck was saved in an older format and needs to be rebuilt in the Deck Editor.",
}

local DeckConfig = {}
M.DeckConfig = DeckConfig

-- isStarter: optional flag (default false); on a collection-mode server a
-- game's built-in starter decks can be bought with tokens.
function DeckConfig.new(gameId, subdecks, isStarter)
  return { gameId = gameId, subdecks = subdecks or {}, isStarter = isStarter == true }
end

function DeckConfig.subdeck(d, name)
  for _, s in ipairs(d.subdecks) do
    if s.name == name then return s end
  end
  return nil
end

function DeckConfig.entriesFor(d, name)
  local s = DeckConfig.subdeck(d, name)
  return s and s.entries or {}
end

function DeckConfig.cardCountFor(d, name)
  local n = 0
  for _, e in ipairs(DeckConfig.entriesFor(d, name)) do n = n + e.quantity end
  return n
end

function DeckConfig.totalCardCount(d)
  local n = 0
  for _, s in ipairs(d.subdecks) do
    for _, e in ipairs(s.entries) do n = n + e.quantity end
  end
  return n
end

-- One copy of every card in every deck type the game uses.
function DeckConfig.full(game)
  local function entries()
    return util.map(game.cards, function(c) return DeckEntry.new(c.id, 1) end)
  end
  local types = M.GameDefinition.deckTypes(game)
  local subdecks = {}
  if #types == 0 then
    subdecks[1] = SubDeck.new("main_deck", entries())
  else
    for _, t in ipairs(types) do subdecks[#subdecks + 1] = SubDeck.new(t, entries()) end
  end
  return DeckConfig.new(game.id, subdecks)
end

function DeckConfig.fromJson(t)
  if t.subdecks == nil then error(M.LegacyDeckFormatError, 0) end
  return DeckConfig.new(requireField(t, "gameId", "DeckConfig"), mapJson(t.subdecks, SubDeck.fromJson),
    t.isStarter == true or t.IsStarter == true)
end

function DeckConfig.toJson(d)
  return obj("gameId", d.gameId, "subdecks", arr(mapJson(d.subdecks, SubDeck.toJson)), "isStarter", d.isStarter and true or nil)
end

---------------------------------------------------------------------------
-- ZoneDefinition
---------------------------------------------------------------------------

local ZoneDefinition = {}
M.ZoneDefinition = ZoneDefinition

local function default(v, d)
  if v == nil then return d end
  return v
end

function ZoneDefinition.new(f)
  return {
    id = f.id,
    name = f.name,
    shared = f.shared or false,
    dealsBuiltDeck = f.dealsBuiltDeck or false,
    deckType = f.deckType or "main_deck",
    deckOptional = f.deckOptional or false,
    entries = f.entries or {},
    faceUp = f.faceUp or false,
    shuffleable = default(f.shuffleable, true),
    visibleToAll = f.visibleToAll or false,
    isDiscardPile = f.isDiscardPile or false,
    autoShuffle = f.autoShuffle or false,
    standardDeck = f.standardDeck or false,
    deckName = f.deckName,
    side = f.side or "left",
    orientation = f.orientation or "portrait",
    kind = f.kind or "card",
    widgetKind = f.widgetKind or "counter",
    counterStartingValue = f.counterStartingValue or 0,
    counterStartingColor = f.counterStartingColor or M.defaultBoardWidgetBackgroundColor,
    counterStartingTextColor = f.counterStartingTextColor or M.defaultBoardWidgetTextColor,
    counterImagePath = f.counterImagePath,
    bagImagePath = f.bagImagePath,
    bagReturnable = default(f.bagReturnable, true),
    bagEntries = f.bagEntries or {},
  }
end

function ZoneDefinition.fromJson(t)
  return ZoneDefinition.new({
    id = requireField(t, "id", "ZoneDefinition"),
    name = requireField(t, "name", "ZoneDefinition"),
    shared = t.shared == true,
    dealsBuiltDeck = t.dealsBuiltDeck == true,
    deckType = t.deckType,
    deckOptional = t.deckOptional == true,
    entries = mapJson(t.entries, DeckEntry.fromJson),
    faceUp = t.faceUp == true,
    shuffleable = default(t.shuffleable, true),
    visibleToAll = t.visibleToAll == true,
    isDiscardPile = t.isDiscardPile == true,
    autoShuffle = t.autoShuffle == true,
    standardDeck = t.standardDeck == true,
    deckName = t.deckName,
    side = enumValue(t.side, M.SharedZoneSide, "left", "ZoneDefinition.side"),
    orientation = enumValue(t.orientation, M.CardOrientation, "portrait", "ZoneDefinition.orientation"),
    kind = enumValue(t.kind, M.ZoneKind, "card", "ZoneDefinition.kind"),
    widgetKind = enumValue(t.widgetKind, M.ZoneWidgetKind, "counter", "ZoneDefinition.widgetKind"),
    counterStartingValue = t.counterStartingValue,
    counterStartingColor = t.counterStartingColor,
    counterStartingTextColor = t.counterStartingTextColor,
    counterImagePath = t.counterImagePath,
    bagImagePath = t.bagImagePath,
    bagReturnable = default(t.bagReturnable, true),
    bagEntries = mapJson(t.bagEntries, DeckEntry.fromJson),
  })
end

function ZoneDefinition.toJson(z)
  return obj(
    "id", z.id,
    "name", z.name,
    "shared", z.shared or nil,
    "dealsBuiltDeck", z.dealsBuiltDeck or nil,
    "deckType", unlessDefault(z.deckType, "main_deck"),
    "deckOptional", z.deckOptional or nil,
    "entries", nonEmptyList(z.entries, DeckEntry.toJson),
    "faceUp", z.faceUp or nil,
    "shuffleable", unlessDefault(z.shuffleable, true),
    "visibleToAll", z.visibleToAll or nil,
    "isDiscardPile", z.isDiscardPile or nil,
    "autoShuffle", z.autoShuffle or nil,
    "standardDeck", z.standardDeck or nil,
    "deckName", z.deckName,
    "side", unlessDefault(z.side, "left"),
    "orientation", unlessDefault(z.orientation, "portrait"),
    "kind", unlessDefault(z.kind, "card"),
    "widgetKind", unlessDefault(z.widgetKind, "counter"),
    "counterStartingValue", unlessDefault(z.counterStartingValue, 0),
    "counterStartingColor", unlessDefault(z.counterStartingColor, M.defaultBoardWidgetBackgroundColor),
    "counterStartingTextColor", unlessDefault(z.counterStartingTextColor, M.defaultBoardWidgetTextColor),
    "counterImagePath", z.counterImagePath,
    "bagImagePath", z.bagImagePath,
    "bagReturnable", unlessDefault(z.bagReturnable, true),
    "bagEntries", nonEmptyList(z.bagEntries, DeckEntry.toJson)
  )
end

---------------------------------------------------------------------------
-- ScenarioPlacement
---------------------------------------------------------------------------

local ScenarioPlacement = {}
M.ScenarioPlacement = ScenarioPlacement

function ScenarioPlacement.new(f)
  return { definitionId = f.definitionId, x = f.x, y = f.y, faceUp = default(f.faceUp, true) }
end

function ScenarioPlacement.fromJson(t)
  return ScenarioPlacement.new({
    definitionId = requireField(t, "definitionId", "ScenarioPlacement"),
    x = requireField(t, "x", "ScenarioPlacement"),
    y = requireField(t, "y", "ScenarioPlacement"),
    faceUp = default(t.faceUp, true),
  })
end

function ScenarioPlacement.toJson(p)
  return obj("definitionId", p.definitionId, "x", p.x, "y", p.y, "faceUp", unlessDefault(p.faceUp, true))
end

---------------------------------------------------------------------------
-- Scenario
---------------------------------------------------------------------------

local Scenario = {}
M.Scenario = Scenario

function Scenario.new(f)
  return { id = f.id, name = f.name, zones = f.zones or {}, placements = f.placements or {}, decks = f.decks or {} }
end

function Scenario.fromJson(t)
  return Scenario.new({
    id = requireField(t, "id", "Scenario"),
    name = requireField(t, "name", "Scenario"),
    zones = mapJson(t.zones, ZoneDefinition.fromJson),
    placements = mapJson(t.placements, ScenarioPlacement.fromJson),
    decks = mapJson(t.decks, SubDeck.fromJson),
  })
end

function Scenario.toJson(s)
  return obj("id", s.id, "name", s.name, "zones", nonEmptyList(s.zones, ZoneDefinition.toJson),
    "placements", nonEmptyList(s.placements, ScenarioPlacement.toJson),
    "decks", nonEmptyList(s.decks, SubDeck.toJson))
end

function Scenario.subdeck(s, name)
  for _, d in ipairs(s.decks) do
    if d.name == name then return d end
  end
  return nil
end

function Scenario.entriesFor(s, name)
  local d = Scenario.subdeck(s, name)
  return d and d.entries or {}
end

---------------------------------------------------------------------------
-- GameDefinition
---------------------------------------------------------------------------

local GameDefinition = {}
M.GameDefinition = GameDefinition

function GameDefinition.new(f)
  return {
    id = f.id,
    name = f.name,
    cards = f.cards or {},
    cardBacks = f.cardBacks or {},
    zones = f.zones or {},
    tagGroups = f.tagGroups or {},
    sets = f.sets or {},
    tableColor = f.tableColor, -- optional "#RRGGBB"; nil defers to the player's/app's default
    playmatBorderColor = f.playmatBorderColor,
    hasScenarios = f.hasScenarios or false,
    scenarios = f.scenarios or {},
    sameOrientationForAll = f.sameOrientationForAll or false,
    folderPath = f.folderPath, -- local only, never serialized
  }
end

function GameDefinition.deckBuildingZones(g)
  return util.filter(g.zones, function(z) return not z.shared and z.dealsBuiltDeck end)
end

-- Ordered, de-duplicated list of deck types (Dart's insertion-ordered Set).
function GameDefinition.deckTypes(g)
  local seen, out = {}, {}
  for _, z in ipairs(GameDefinition.deckBuildingZones(g)) do
    if not seen[z.deckType] then
      seen[z.deckType] = true
      out[#out + 1] = z.deckType
    end
  end
  return out
end

function GameDefinition.needsDeckBuilding(g)
  return #GameDefinition.deckBuildingZones(g) > 0
end

function GameDefinition.cardById(g, id)
  if not g._cardIndex or g._cardIndexSize ~= #g.cards then
    local idx = {}
    for _, c in ipairs(g.cards) do
      if idx[c.id] == nil then idx[c.id] = c end
    end
    g._cardIndex = idx
    g._cardIndexSize = #g.cards
  end
  return g._cardIndex[id]
end

-- Call after mutating g.cards in place (the editor) to drop the lookup cache.
function GameDefinition.invalidateIndex(g)
  g._cardIndex = nil
end

function GameDefinition.zoneById(g, id)
  for _, z in ipairs(g.zones) do
    if z.id == id then return z end
  end
  return nil
end

function GameDefinition.scenarioById(g, id)
  for _, s in ipairs(g.scenarios) do
    if s.id == id then return s end
  end
  return nil
end

function GameDefinition.fromJson(t)
  local sets, cards = {}, {}
  if t.sets ~= nil then
    for _, rawSet in ipairs(t.sets) do
      sets[#sets + 1] = GameSet.fromJson(rawSet)
      local setId = requireField(rawSet, "id", "GameSet")
      for _, rawCard in ipairs(requireField(rawSet, "cards", "GameSet")) do
        local c = CardDefinition.fromJson(rawCard)
        c.setId = setId
        cards[#cards + 1] = c
      end
    end
  else
    cards = mapJson(requireField(t, "cards", "GameDefinition"), CardDefinition.fromJson)
  end
  local cardBacks
  if t.cardBacks ~= nil then
    cardBacks = mapJson(t.cardBacks, CardBackDefinition.fromJson)
  elseif t.cardBackImagePath ~= nil then
    -- Pre-multiple-card-backs file: the single legacy path becomes the default.
    cardBacks = { CardBackDefinition.new({ id = "default", name = "Default", imagePath = t.cardBackImagePath }) }
  else
    cardBacks = {}
  end
  return GameDefinition.new({
    id = requireField(t, "id", "GameDefinition"),
    name = requireField(t, "name", "GameDefinition"),
    cards = cards,
    sets = sets,
    cardBacks = cardBacks,
    zones = mapJson(t.zones, ZoneDefinition.fromJson),
    tagGroups = mapJson(t.tagGroups, TagGroup.fromJson),
    tableColor = t.tableColor,
    playmatBorderColor = t.playmatBorderColor,
    hasScenarios = t.hasScenarios == true,
    scenarios = mapJson(t.scenarios, Scenario.fromJson),
    sameOrientationForAll = t.sameOrientationForAll == true,
  })
end

function GameDefinition.toJson(g)
  local o = json.object()
  o.id = g.id
  o.name = g.name
  if #g.sets > 0 then
    local setsJson = {}
    for _, s in ipairs(g.sets) do
      local sj = GameSet.toJson(s)
      local setCards = {}
      for _, c in ipairs(g.cards) do
        if c.setId == s.id then setCards[#setCards + 1] = CardDefinition.toJson(c, true) end
      end
      sj.cards = arr(setCards)
      setsJson[#setsJson + 1] = sj
    end
    o.sets = arr(setsJson)
  else
    o.cards = arr(mapJson(g.cards, function(c) return CardDefinition.toJson(c) end))
  end
  o.cardBacks = nonEmptyList(g.cardBacks, CardBackDefinition.toJson)
  o.zones = nonEmptyList(g.zones, ZoneDefinition.toJson)
  o.tagGroups = nonEmptyList(g.tagGroups, TagGroup.toJson)
  if g.tableColor then o.tableColor = g.tableColor end
  if g.playmatBorderColor then o.playmatBorderColor = g.playmatBorderColor end
  if g.hasScenarios then o.hasScenarios = true end
  o.scenarios = nonEmptyList(g.scenarios, Scenario.toJson)
  if g.sameOrientationForAll then o.sameOrientationForAll = true end
  return o
end

---------------------------------------------------------------------------
-- StandardDeck
---------------------------------------------------------------------------

local SUITS = {
  { "hearts", "Hearts", "#D32F2F" },
  { "diamonds", "Diamonds", "#D32F2F" },
  { "clubs", "Clubs", "#212121" },
  { "spades", "Spades", "#212121" },
}
local RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }

function M.buildStandardDeckCards()
  local out = {}
  for _, s in ipairs(SUITS) do
    for _, rank in ipairs(RANKS) do
      out[#out + 1] = CardDefinition.new({
        id = M.standardDeckIdPrefix .. s[1] .. "_" .. rank,
        cardTitle = rank,
        colorHex = s[3],
        suit = s[1],
        rank = rank,
        types = { s[2] },
        unownable = true,
      })
    end
  end
  return out
end

---------------------------------------------------------------------------
-- CardInstance
---------------------------------------------------------------------------

local CardInstance = {}
M.CardInstance = CardInstance

function CardInstance.new(f)
  return {
    instanceId = f.instanceId,
    definitionId = f.definitionId,
    x = f.x,
    y = f.y,
    zIndex = f.zIndex,
    faceUp = f.faceUp,
    zone = f.zone,
    ownerId = f.ownerId,
    stackParentId = f.stackParentId,
    zoneId = f.zoneId,
    rotationTurns = f.rotationTurns or 0,
    unownable = f.unownable or false,
  }
end

function CardInstance.fromJson(t)
  return CardInstance.new({
    instanceId = requireField(t, "instanceId", "CardInstance"),
    definitionId = requireField(t, "definitionId", "CardInstance"),
    x = requireField(t, "x", "CardInstance"),
    y = requireField(t, "y", "CardInstance"),
    zIndex = requireField(t, "zIndex", "CardInstance"),
    faceUp = requireField(t, "faceUp", "CardInstance"),
    zone = enumValue(requireField(t, "zone", "CardInstance"), M.CardZone, nil, "CardInstance.zone"),
    ownerId = t.ownerId,
    stackParentId = t.stackParentId,
    zoneId = t.zoneId,
    rotationTurns = t.rotationTurns or 0,
    unownable = t.unownable == true,
  })
end

function CardInstance.toJson(c)
  return obj(
    "instanceId", c.instanceId,
    "definitionId", c.definitionId,
    "x", c.x,
    "y", c.y,
    "zIndex", c.zIndex,
    "faceUp", c.faceUp,
    "zone", c.zone,
    "ownerId", c.ownerId,
    "stackParentId", c.stackParentId,
    "zoneId", c.zoneId,
    "rotationTurns", unlessDefault(c.rotationTurns, 0),
    "unownable", c.unownable and true or nil
  )
end

---------------------------------------------------------------------------
-- RevealedToken
---------------------------------------------------------------------------

local RevealedToken = {}
M.RevealedToken = RevealedToken

function RevealedToken.new(slotId, imagePath) return { slotId = slotId, imagePath = imagePath } end

function RevealedToken.fromJson(t)
  return RevealedToken.new(requireField(t, "slotId", "RevealedToken"), requireField(t, "imagePath", "RevealedToken"))
end

function RevealedToken.toJson(r) return obj("slotId", r.slotId, "imagePath", r.imagePath) end

---------------------------------------------------------------------------
-- BoardWidgetInstance
---------------------------------------------------------------------------

local BoardWidgetInstance = {}
M.BoardWidgetInstance = BoardWidgetInstance

function BoardWidgetInstance.new(f)
  return {
    instanceId = f.instanceId,
    kind = f.kind,
    x = f.x,
    y = f.y,
    zIndex = f.zIndex,
    value = f.value or 0,
    backgroundColor = f.backgroundColor or M.defaultBoardWidgetBackgroundColor,
    textColor = f.textColor or M.defaultBoardWidgetTextColor,
    attachedCardId = f.attachedCardId,
    attachOffsetX = f.attachOffsetX or 0,
    attachOffsetY = f.attachOffsetY or 0,
    x2 = f.x2,
    y2 = f.y2,
    creatorId = f.creatorId,
    ownerId = f.ownerId,
    zoneId = f.zoneId,
    imagePath = f.imagePath,
    sizeOverride = f.sizeOverride,
    bagRemaining = f.bagRemaining or {},
    bagRevealed = f.bagRevealed or {},
  }
end

function BoardWidgetInstance.fromJson(t)
  return BoardWidgetInstance.new({
    instanceId = requireField(t, "instanceId", "BoardWidgetInstance"),
    kind = enumValue(requireField(t, "kind", "BoardWidgetInstance"), M.BoardWidgetKind, nil, "BoardWidgetInstance.kind"),
    x = requireField(t, "x", "BoardWidgetInstance"),
    y = requireField(t, "y", "BoardWidgetInstance"),
    zIndex = requireField(t, "zIndex", "BoardWidgetInstance"),
    value = t.value,
    backgroundColor = t.backgroundColor,
    textColor = t.textColor,
    attachedCardId = t.attachedCardId,
    attachOffsetX = t.attachOffsetX,
    attachOffsetY = t.attachOffsetY,
    x2 = t.x2,
    y2 = t.y2,
    creatorId = t.creatorId,
    ownerId = t.ownerId,
    zoneId = t.zoneId,
    imagePath = t.imagePath,
    sizeOverride = t.sizeOverride,
    bagRemaining = stringList(t.bagRemaining),
    bagRevealed = mapJson(t.bagRevealed, RevealedToken.fromJson),
  })
end

function BoardWidgetInstance.toJson(w)
  return obj(
    "instanceId", w.instanceId,
    "kind", w.kind,
    "x", w.x,
    "y", w.y,
    "zIndex", w.zIndex,
    "value", unlessDefault(w.value, 0),
    "backgroundColor", unlessDefault(w.backgroundColor, M.defaultBoardWidgetBackgroundColor),
    "textColor", unlessDefault(w.textColor, M.defaultBoardWidgetTextColor),
    "attachedCardId", w.attachedCardId,
    "attachOffsetX", unlessDefault(w.attachOffsetX, 0),
    "attachOffsetY", unlessDefault(w.attachOffsetY, 0),
    "x2", w.x2,
    "y2", w.y2,
    "creatorId", w.creatorId,
    "ownerId", w.ownerId,
    "zoneId", w.zoneId,
    "imagePath", w.imagePath,
    "sizeOverride", w.sizeOverride,
    "bagRemaining", nonEmptyList(w.bagRemaining),
    "bagRevealed", nonEmptyList(w.bagRevealed, RevealedToken.toJson)
  )
end

-- Ownership helpers (see board_widget_instance.dart:133-151).
function BoardWidgetInstance.isDocked(w) return w.zoneId ~= nil end

---------------------------------------------------------------------------
-- PlayerInfo
---------------------------------------------------------------------------

local PlayerInfo = {}
M.PlayerInfo = PlayerInfo

function PlayerInfo.new(f)
  return { id = f.id, name = f.name, role = f.role, color = f.color, connected = default(f.connected, true) }
end

function PlayerInfo.fromJson(t)
  return PlayerInfo.new({
    id = requireField(t, "id", "PlayerInfo"),
    name = requireField(t, "name", "PlayerInfo"),
    role = enumValue(requireField(t, "role", "PlayerInfo"), M.PlayerRole, nil, "PlayerInfo.role"),
    color = requireField(t, "color", "PlayerInfo"),
    connected = default(t.connected, true),
  })
end

function PlayerInfo.toJson(p)
  return obj("id", p.id, "name", p.name, "role", p.role, "color", p.color, "connected", p.connected)
end

---------------------------------------------------------------------------
-- ActiveSearch
---------------------------------------------------------------------------

local ActiveSearch = {}
M.ActiveSearch = ActiveSearch

function ActiveSearch.new(f)
  return { searcherId = f.searcherId, targetType = f.targetType, targetId = f.targetId, targetOwnerId = f.targetOwnerId }
end

function ActiveSearch.fromJson(t)
  return ActiveSearch.new({
    searcherId = requireField(t, "searcherId", "ActiveSearch"),
    targetType = enumValue(requireField(t, "targetType", "ActiveSearch"), M.SearchTargetType, nil, "ActiveSearch.targetType"),
    targetId = requireField(t, "targetId", "ActiveSearch"),
    targetOwnerId = t.targetOwnerId,
  })
end

function ActiveSearch.toJson(s)
  return obj("searcherId", s.searcherId, "targetType", s.targetType, "targetId", s.targetId,
    "targetOwnerId", s.targetOwnerId)
end

---------------------------------------------------------------------------
-- LogEntry
---------------------------------------------------------------------------

local LogEntry = {}
M.LogEntry = LogEntry

function LogEntry.new(elapsedMs, message) return { elapsedMs = elapsedMs, message = message } end

function LogEntry.fromJson(t)
  return LogEntry.new(requireField(t, "elapsedMs", "LogEntry"), requireField(t, "message", "LogEntry"))
end

function LogEntry.toJson(e) return obj("elapsedMs", e.elapsedMs, "message", e.message) end

function M.formatElapsedTime(ms)
  local total = math.floor(ms / 1000)
  return string.format("%02d:%02d:%02d", math.floor(total / 3600), math.floor((total % 3600) / 60), total % 60)
end

---------------------------------------------------------------------------
-- TableState
---------------------------------------------------------------------------

local TableState = {}
M.TableState = TableState

function TableState.new(f)
  return {
    gameId = f.gameId,
    players = f.players or {},
    cards = f.cards or {},
    revision = f.revision or 0,
    widgets = f.widgets or {},
    searches = f.searches or {},
    log = f.log or {},
    loadedZones = f.loadedZones or {},
    loadedScenarioIds = f.loadedScenarioIds or {},
  }
end

function TableState.fromJson(t)
  return TableState.new({
    gameId = requireField(t, "gameId", "TableState"),
    players = mapJson(requireField(t, "players", "TableState"), PlayerInfo.fromJson),
    cards = mapJson(requireField(t, "cards", "TableState"), CardInstance.fromJson),
    revision = requireField(t, "revision", "TableState"),
    widgets = mapJson(t.widgets, BoardWidgetInstance.fromJson),
    searches = mapJson(t.searches, ActiveSearch.fromJson),
    log = mapJson(t.log, LogEntry.fromJson),
    loadedZones = mapJson(t.loadedZones, ZoneDefinition.fromJson),
    loadedScenarioIds = stringList(t.loadedScenarioIds),
  })
end

function TableState.toJson(s)
  return obj(
    "gameId", s.gameId,
    "players", arr(mapJson(s.players, PlayerInfo.toJson)),
    "cards", arr(mapJson(s.cards, CardInstance.toJson)),
    "revision", s.revision,
    "widgets", nonEmptyList(s.widgets, BoardWidgetInstance.toJson),
    "searches", nonEmptyList(s.searches, ActiveSearch.toJson),
    "log", nonEmptyList(s.log, LogEntry.toJson),
    "loadedZones", nonEmptyList(s.loadedZones, ZoneDefinition.toJson),
    "loadedScenarioIds", nonEmptyList(s.loadedScenarioIds)
  )
end

function TableState.playerById(s, id)
  for _, p in ipairs(s.players) do
    if p.id == id then return p end
  end
  return nil
end

-- table_actions.lua treats TableState as copy-on-write: any actual change to
-- .cards/.widgets builds a fresh array (util.copyWith shallow-copies every
-- field, cache included, onto the new state). So unlike GameDefinition's
-- size check above, staleness here is keyed on the array's identity, not
-- its length -- a move/flip keeps the same card count, and a stale index
-- would otherwise look "still valid" by size and hand back the pre-mutation
-- card.
function TableState.cardById(s, id)
  if s._cardIndexFor ~= s.cards then
    local idx = {}
    for _, c in ipairs(s.cards) do idx[c.instanceId] = c end
    s._cardIndex = idx
    s._cardIndexFor = s.cards
  end
  return s._cardIndex[id]
end

function TableState.widgetById(s, id)
  if s._widgetIndexFor ~= s.widgets then
    local idx = {}
    for _, w in ipairs(s.widgets) do idx[w.instanceId] = w end
    s._widgetIndex = idx
    s._widgetIndexFor = s.widgets
  end
  return s._widgetIndex[id]
end

---------------------------------------------------------------------------
-- SavedGame
---------------------------------------------------------------------------

local SavedGame = {}
M.SavedGame = SavedGame

-- savedAt is kept as the ISO-8601 string Dart wrote ("2026-01-02T03:04:05.678").
function SavedGame.new(savedAt, state) return { savedAt = savedAt, state = state } end

function SavedGame.fromJson(t)
  return SavedGame.new(requireField(t, "savedAt", "SavedGame"), TableState.fromJson(requireField(t, "state", "SavedGame")))
end

function SavedGame.toJson(g) return obj("savedAt", g.savedAt, "state", TableState.toJson(g.state)) end

-- Local-time ISO-8601 timestamp with milliseconds, like Dart's
-- DateTime.now().toIso8601String().
function M.isoNow(nowSeconds)
  nowSeconds = nowSeconds or os.time()
  local ms = 0
  if type(nowSeconds) == "number" and nowSeconds % 1 ~= 0 then
    ms = math.floor((nowSeconds % 1) * 1000)
    nowSeconds = math.floor(nowSeconds)
  end
  return os.date("%Y-%m-%dT%H:%M:%S", nowSeconds) .. string.format(".%03d", ms)
end

-- Parses "YYYY-MM-DDTHH:MM:SS[.fff...][Z|±hh:mm]" -> table {year,..} or nil.
function M.parseIso(s)
  local y, mo, d, h, mi, sec = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):?(%d*)")
  if not y then
    y, mo, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then return nil end
    h, mi, sec = 0, 0, 0
  end
  return {
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec) or 0,
  }
end

return M
