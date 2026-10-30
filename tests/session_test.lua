-- Port of test/game_session_test.dart (condensed) plus controller checks.
local H = require("tests.helpers")
local models = require("src.core.models")
local util = require("src.core.util")
local Session = require("src.game.session")
local controller = require("src.game.controller")
local json = require("lib.json")

return function(t)
  local p1 = H.player("p1", "Alice", "host")
  local p2 = H.player("p2", "Bob", "client")

  local function zone(f) return models.ZoneDefinition.new(f) end
  local function game(f)
    f.id = f.id or "g"
    f.name = f.name or "G"
    f.cards = f.cards or { H.cardDef("a"), H.cardDef("b"), H.cardDef("c") }
    return models.GameDefinition.new(f)
  end
  local function deck(subdecks)
    local list = {}
    for name, entries in pairs(subdecks) do
      list[#list + 1] = models.SubDeck.new(name, util.map(entries, function(e) return models.DeckEntry.new(e[1], e[2]) end))
    end
    return models.DeckConfig.new("g", list)
  end
  local function inZone(s, zoneId, ownerId)
    return util.filter(s.state.cards, function(c) return c.zone == "zone" and c.zoneId == zoneId and c.ownerId == ownerId end)
  end
  local function defIds(cards)
    local ids = util.map(A and cards or cards, function(c) return c.definitionId end)
    table.sort(ids)
    return ids
  end
  -- Fake clock so log timestamps are deterministic.
  local clock = 100
  local function now() return clock end
  local function lastLog(s) return s.state.log[#s.state.log].message end

  t.describe("dealFromZones", function()
    t.it("built decks per player, full-deck fallback, missing optional subdeck", function()
      local g = game({ zones = {
        zone({ id = "draw", name = "Draw", dealsBuiltDeck = true }),
        zone({ id = "side", name = "Side", dealsBuiltDeck = true, deckType = "side", deckOptional = true }),
      } })
      local s = Session.dealFromZones({ game = g, players = { p1, p2 }, localPlayerId = "p1", now = now,
        deckConfigsByPlayerId = { p1 = deck({ main_deck = { { "a", 2 }, { "zzz", 5 } }, side = { { "c", 1 } } }), p2 = deck({ main_deck = { { "b", 1 } } }) } })
      t.eq(defIds(inZone(s, "draw", "p1")), { "a", "a" })
      t.eq(defIds(inZone(s, "side", "p1")), { "c" })
      t.eq(defIds(inZone(s, "draw", "p2")), { "b" })
      t.eq(#inZone(s, "side", "p2"), 0)
      t.eq(s.state.revision, 0)
      local zs = util.map(s.state.cards, function(c) return c.zIndex end)
      t.eq(zs, { 0, 1, 2, 3 })
      local full = Session.dealFromZones({ game = g, players = { p1 }, localPlayerId = "p1", now = now })
      t.eq(defIds(inZone(full, "draw", "p1")), { "a", "b", "c" })
    end)
    t.it("static entries, faceUp, widget zones", function()
      local g = game({ zones = {
        zone({ id = "z", name = "Z", faceUp = true, entries = { models.DeckEntry.new("b", 2) } }),
        zone({ id = "life", name = "Life", kind = "widget", counterStartingValue = 20, counterStartingColor = 0xFFD32F2F }),
      } })
      local s = Session.dealFromZones({ game = g, players = { p1, p2 }, localPlayerId = "p1", now = now })
      t.eq(#inZone(s, "z", "p2"), 2)
      t.ok(inZone(s, "z", "p1")[1].faceUp)
      t.eq(#s.state.widgets, 2)
      local w = s.state.widgets[2]
      t.eq({ w.kind, w.value, w.backgroundColor, w.ownerId, w.zoneId, w.zIndex }, { "simpleCounter", 20, 0xFFD32F2F, "p2", "life", 1 })
    end)
    t.it("owned token bag zone deals one widget per player, contents expanded from bagEntries", function()
      local g = game({ zones = {
        zone({ id = "bag", name = "Bag", kind = "widget", widgetKind = "tokenBag", bagImagePath = "bag.png",
          bagEntries = { models.DeckEntry.new("plus1.png", 2), models.DeckEntry.new("skull.png", 1) } }),
      } })
      local s = Session.dealFromZones({ game = g, players = { p1, p2 }, localPlayerId = "p1", now = now })
      t.eq(#s.state.widgets, 2)
      local w1 = util.find(s.state.widgets, function(w) return w.ownerId == "p1" end)
      t.eq(w1.kind, "tokenBag")
      t.eq(w1.imagePath, "bag.png")
      t.eq(w1.bagRevealed, {})
      local sorted = util.map(w1.bagRemaining, function(x) return x end)
      table.sort(sorted)
      t.eq(sorted, { "plus1.png", "plus1.png", "skull.png" })
    end)
    t.it("shared token bag zone deals exactly one unowned widget, and no stray cards", function()
      local g = game({ zones = {
        zone({ id = "bag", name = "Bag", shared = true, kind = "widget", widgetKind = "tokenBag",
          bagEntries = { models.DeckEntry.new("plus1.png", 1) } }),
      } })
      local s = Session.dealFromZones({ game = g, players = { p1, p2 }, localPlayerId = "p1", now = now })
      t.eq(#s.state.widgets, 1)
      t.isNil(s.state.widgets[1].ownerId)
      t.eq(s.state.widgets[1].kind, "tokenBag")
      t.eq(s.state.widgets[1].zoneId, "bag")
      t.eq(#s.state.cards, 0, "a shared widget zone must never fall back to dealing the full card deck")
    end)
    t.it("shared zones: discard empty, default full deck, standard 52, deckName, unownable", function()
      local g = game({ cards = { H.cardDef("a", {}, { unownable = true }), H.cardDef("b") }, zones = {
        zone({ id = "discard", name = "Discard", shared = true, isDiscardPile = true }),
        zone({ id = "pool", name = "Pool", shared = true }),
        zone({ id = "deck52", name = "Deck", shared = true, standardDeck = true }),
        zone({ id = "named", name = "Named", shared = true, deckName = "X", entries = { models.DeckEntry.new("a", 9) } }),
      } })
      local s = Session.dealFromZones({ game = g, players = { p1 }, localPlayerId = "p1", now = now,
        sharedDeckConfigsByZoneId = { named = deck({ main_deck = { { "b", 3 } } }) } })
      t.eq(#inZone(s, "discard", nil), 0)
      t.eq(defIds(inZone(s, "pool", nil)), { "a", "b" })
      t.eq(#inZone(s, "deck52", nil), 52)
      t.eq(defIds(inZone(s, "named", nil)), { "b", "b", "b" })
      local a = util.find(inZone(s, "pool", nil), function(c) return c.definitionId == "a" end)
      t.ok(a.unownable)
    end)
    t.it("autoShuffle keeps the multiset and sequential zIndex", function()
      local entries = {}
      for i = 1, 20 do entries[i] = models.DeckEntry.new(i % 2 == 0 and "a" or "b", 1) end
      local g = game({ zones = { zone({ id = "z", name = "Z", shared = true, autoShuffle = true, entries = entries }) } })
      local s = Session.dealFromZones({ game = g, players = { p1 }, localPlayerId = "p1", now = now, rng = util.seededRng(3) })
      local ids = defIds(s.state.cards)
      t.eq(#ids, 20)
      t.eq(ids[10], "a")
      t.eq(ids[11], "b")
    end)
  end)

  t.describe("practice seats", function()
    t.it("acts as the first player and can switch; no-op outside practice", function()
      local g = game({ zones = {} })
      local s = Session.localPractice({ game = g, players = { p1, p2 }, now = now })
      t.eq(s:actingPlayerId(), "p1")
      local notified = 0
      s:addListener(function() notified = notified + 1 end)
      s:setActiveSeat("p2")
      t.eq(s:actingPlayerId(), "p2")
      t.eq(notified, 1)
      local host = Session.new({ game = g, localPlayerId = "p1", initialState = H.state({}), now = now })
      host:setActiveSeat("p2")
      t.eq(host:actingPlayerId(), "p1")
    end)
  end)

  t.describe("action log", function()
    local g = game({ cards = { H.cardDef("a", {}, { cardTitle = "Ace" }), H.cardDef("b", {}, { cardTitle = "Bee" }) }, zones = {
      zone({ id = "draw", name = "Draw Deck" }),
      zone({ id = "discard", name = "Discard", isDiscardPile = true, faceUp = true, visibleToAll = true }),
      zone({ id = "life", name = "Life", kind = "widget" }),
    }, sets = { models.GameSet.new({ id = "s1", name = "Core" }) } })
    local function session(cards, widgets)
      clock = 100
      return Session.new({ game = g, localPlayerId = "p1", now = now, clockStart = 100,
        initialState = H.state({ players = { p1, p2 }, cards = cards or {}, widgets = widgets or {} }) })
    end
    t.it("plays to table: names visible hand cards, generic for hidden zone cards, none for repositions", function()
      local s = session({
        H.card({ id = "h", definitionId = "a", zone = "hand", ownerId = "p1", faceUp = true }),
        H.card({ id = "z", definitionId = "b", zone = "zone", zoneId = "draw", ownerId = "p1", zIndex = 1 }),
        H.card({ id = "t", definitionId = "b", faceUp = true, zIndex = 2 }),
      })
      clock = 161.5
      s:moveCard("h", 0.5, 0.5, "p1")
      t.eq(s.state.log[1], { elapsedMs = 61500, message = 'Alice played "Ace" to the table from hand.' })
      s:moveCard("z", 0.5, 0.5, "p1")
      t.eq(lastLog(s), "Alice played a card to the table from the Draw Deck.")
      s:moveCard("t", 0.2, 0.2, "p1")
      t.eq(#s.state.log, 2)
    end)
    t.it("flip, draw, zone draw, shuffles, discard, return", function()
      local s = session({
        H.card({ id = "x", definitionId = "a", zone = "hand", ownerId = "p1" }),
        H.card({ id = "z1", definitionId = "a", zone = "zone", zoneId = "draw", ownerId = "p1", zIndex = 1 }),
        H.card({ id = "z2", definitionId = "b", zone = "zone", zoneId = "draw", ownerId = "p1", zIndex = 2 }),
        H.card({ id = "p", definitionId = "a", zIndex = 3 }),
        H.card({ id = "q", definitionId = "b", zIndex = 4, stackParentId = "p" }),
      })
      local logCountBeforeHandFlip = #s.state.log
      s:flipCard("x", "p1")
      t.eq(#s.state.log, logCountBeforeHandFlip)
      s:flipCard("p", "p1")
      t.eq(lastLog(s), 'Alice flipped "Ace" face up.')
      s:drawCard("p", "p1", 1)
      t.eq(lastLog(s), "Alice drew a card.")
      s:drawFromZone("draw", "p1", "p1", 2)
      t.eq(lastLog(s), "Alice drew 2 cards from the Draw Deck.")
      s:shufflePile("p", "p2")
      t.eq(lastLog(s), "Bob shuffled a pile of cards.")
      s:returnToZone("x", "discard", "p1", false, "p1")
      t.eq(lastLog(s), 'Alice discarded "Ace".')
      s:returnToZone("q", "draw", "p1", false, "p1")
      t.eq(lastLog(s), "Alice returned a card to the Draw Deck.")
      s:shuffleZone("draw", "p1", "p1")
      t.eq(lastLog(s), "Alice shuffled the Draw Deck.")
    end)
    t.it("non-shuffleable zones don't shuffle or log", function()
      local g2 = game({ zones = { zone({ id = "d", name = "D", shuffleable = false }) } })
      local s = Session.new({ game = g2, localPlayerId = "p1", now = now, initialState = H.state({ players = { p1 }, cards = {
        H.card({ id = "1", zone = "zone", zoneId = "d", ownerId = "p1" }), H.card({ id = "2", zone = "zone", zoneId = "d", ownerId = "p1", zIndex = 1 }) } }) })
      s:shuffleZone("d", "p1", "p1")
      t.eq(#s.state.log, 0)
      t.eq(s.state.revision, 0)
    end)
    t.it("give, pick up, rotate", function()
      local s = session({ H.card({ id = "c", definitionId = "a", faceUp = true, ownerId = "p1" }) })
      s:giveCard("c", "p2", "p1")
      t.eq(lastLog(s), 'Alice gave "Ace" to Bob.')
      s:giveCard("c", nil, "p2")
      t.eq(lastLog(s), 'Bob released "Ace" back to the table.')
      s:rotateStack("c", true, "p1")
      t.eq(lastLog(s), 'Alice rotated "Ace".')
      s:moveToHand("c", "p1")
      t.eq(lastLog(s), 'Alice picked up "Ace" into their hand.')
    end)
    t.it("widgets and searches", function()
      local s = session({ H.card({ id = "c", definitionId = "a" }) }, {
        H.widget({ id = "zc", kind = "simpleCounter", ownerId = "p1", zoneId = "life" }),
        H.widget({ id = "fc", kind = "simpleCounter" }),
        H.widget({ id = "tok", kind = "token" }),
      })
      s:setWidgetValue("zc", 120000, "p1")
      t.eq(lastLog(s), "Alice set Life to 99999.")
      s:setWidgetValue("fc", 3, "p2")
      t.eq(lastLog(s), "Bob set a counter to 3.")
      local n = #s.state.log
      s:setWidgetValue("tok", 3, "p2")
      t.eq(#s.state.log, n)
      s:attachWidgetToCard("tok", "c", 0, 0, "p1")
      t.eq(lastLog(s), "Alice attached a token to a card.")
      s:startSearchZone("draw", "p1", "p1")
      t.eq(lastLog(s), "Alice opened a search on the Draw Deck.")
      s:stopSearch("p1")
      t.eq(lastLog(s), "Alice closed their search.")
      n = #s.state.log
      s:stopSearch("p1")
      t.eq(#s.state.log, n)
    end)
    t.it("connections: logs only changes, never the host", function()
      local s = session()
      s:syncConnectedPlayerIds({ p2 = true })
      t.eq(#s.state.log, 0)
      t.eq(s.state.revision, 1)
      s:syncConnectedPlayerIds({})
      t.eq(lastLog(s), "Bob disconnected.")
      t.eq(s.state.players[2].connected, false)
      t.eq(s.state.players[1].connected, true)
    end)
    t.it("packs, card library and deck loading", function()
      local s = session()
      s:generatePack("s1", "p1")
      t.eq(lastLog(s), "Alice generated a pack from the Core set.")
      t.eq(s.state.revision, 0, "empty set: dealNewCards no-op")
      s:createCardFromLibrary("b", 0.3, 0.4, "p2")
      t.eq(lastLog(s), 'Bob created "Bee" from the card library.')
      local c = s.state.cards[1]
      t.eq({ c.zone, c.faceUp, c.ownerId, c.x }, { "table", true, "p2", 0.3 })
      s:loadDeckIntoZone("draw", deck({ main_deck = { { "a", 2 }, { "nope", 1 } }, side = { { "b", 4 } } }), "p1")
      t.eq(lastLog(s), "Alice loaded a deck into the Draw Deck.")
      t.eq(defIds(inZone(s, "draw", "p1")), { "a", "a" })
    end)
    t.it("loading a deck with subdecks fills every deck-building zone, not just the clicked one", function()
      local g2 = game({ zones = {
        zone({ id = "location", name = "Location Deck", dealsBuiltDeck = true, deckType = "location_deck" }),
        zone({ id = "character", name = "Character Deck", dealsBuiltDeck = true, deckType = "character_deck" }),
      } })
      local s = Session.new({ game = g2, localPlayerId = "p1", now = now,
        initialState = H.state({ players = { p1, p2 } }) })
      s:loadDeckIntoZone("location", deck({ location_deck = { { "a", 2 } }, character_deck = { { "b", 1 } } }), "p1")
      t.eq(defIds(inZone(s, "location", "p1")), { "a", "a" })
      t.eq(defIds(inZone(s, "character", "p1")), { "b" })
      t.eq(lastLog(s), "Alice loaded a deck into the Location Deck and Character Deck.")
    end)
    t.it("deck widget synthetic zones resolve to the real zone and stay generic", function()
      -- From a hand (private) into a sub-zone of a visibleToAll zone: the
      -- deck widget's cards stay private, so the name isn't revealed.
      local s = session({ H.card({ id = "c", definitionId = "a", faceUp = true, zone = "hand", ownerId = "p1" }) },
        { H.widget({ id = "dw", kind = "deckBuilder", ownerId = "p1" }) })
      s:returnToZone("c", "deckWidget:dw:discard", "p1", false, "p1")
      t.eq(lastLog(s), "Alice discarded a card.")
      local moved = s.state.cards[1]
      t.eq({ moved.zone, moved.zoneId, moved.ownerId }, { "zone", "deckWidget:dw:discard", "p1" })
      s:startSearchZone("deckWidget:dw:draw", "p1", "p1")
      t.eq(lastLog(s), "Alice opened a search on the Draw Deck.")
    end)
  end)

  t.describe("scenarios", function()
    local function scenarioGame()
      return game({
        cards = { H.cardDef("a", {}, { cardTitle = "A" }), H.cardDef("b", {}, { cardTitle = "B" }), H.cardDef("c", {}, { cardTitle = "C" }) },
        hasScenarios = true,
        scenarios = {
          models.Scenario.new({
            id = "scen1", name = "Opening",
            zones = {
              zone({ id = "battlefield", name = "Battlefield", shared = true,
                entries = { models.DeckEntry.new("a", 2), models.DeckEntry.new("unknown", 3) } }),
              zone({ id = "boss", name = "Boss Deck", shared = true, dealsBuiltDeck = true, deckType = "boss_deck",
                entries = { models.DeckEntry.new("b", 5) } }),
            },
            placements = {
              models.ScenarioPlacement.new({ definitionId = "c", x = 0.2, y = 0.3, faceUp = false }),
              models.ScenarioPlacement.new({ definitionId = "missing", x = 0.5, y = 0.5 }),
            },
            decks = { models.SubDeck.new("boss_deck", { models.DeckEntry.new("a", 2), models.DeckEntry.new("c", 1) }) },
          }),
        },
      })
    end
    local function scenarioSession()
      return Session.new({ game = scenarioGame(), localPlayerId = "p1", now = now,
        initialState = H.state({ players = { p1, p2 } }) })
    end

    t.it("creates zones findable via zoneDefinition/effectiveZones, deals entries (unknown ids skipped), spawns placements", function()
      local s = scenarioSession()
      s:loadScenario("scen1", "p1")
      t.eq(s:zoneDefinition("battlefield").name, "Battlefield")
      t.eq(#s:effectiveZones(), 2)
      t.eq(defIds(inZone(s, "battlefield", nil)), { "a", "a" })
      local placed = util.find(s.state.cards, function(c) return c.zone == "table" and c.definitionId == "c" end)
      t.ok(placed, "the known placement should exist")
      t.eq({ placed.zone, placed.ownerId, placed.faceUp, placed.x, placed.y }, { "table", nil, false, 0.2, 0.3 })
      t.eq(#util.filter(s.state.cards, function(c) return c.definitionId == "missing" end), 0)
      t.eq(lastLog(s), 'Alice loaded the "Opening" scenario.')
    end)

    t.it("a dealsBuiltDeck zone deals its named subdeck instead of its own entries", function()
      local s = scenarioSession()
      s:loadScenario("scen1", "p1")
      t.eq(defIds(inZone(s, "boss", nil)), { "a", "a", "c" })
    end)

    t.it("double-load and unknown scenario id are no-ops", function()
      local s = scenarioSession()
      s:loadScenario("scen1", "p1")
      local revision, count, logLen = s.state.revision, #s.state.cards, #s.state.log
      s:loadScenario("scen1", "p1")
      t.eq(s.state.revision, revision)
      t.eq(#s.state.cards, count)
      t.eq(#s.state.log, logLen)
      s:loadScenario("doesnotexist", "p1")
      t.eq(s.state.revision, revision)
      t.eq(#s.state.cards, count)
      t.eq(#s.state.log, logLen)
    end)

    t.it("a card can be drawn out of a loaded zone afterwards", function()
      local s = scenarioSession()
      s:loadScenario("scen1", "p1")
      s:drawFromZone("battlefield", nil, "p1", 1)
      local drawn = util.filter(s.state.cards, function(c) return c.zone == "hand" and c.ownerId == "p1" end)
      t.eq(#drawn, 1)
      t.eq(drawn[1].definitionId, "a")
    end)

    t.it("a scenario-defined widget zone deals one unowned widget (not just card zones)", function()
      local g = game({
        hasScenarios = true,
        scenarios = { models.Scenario.new({ id = "scen2", name = "Bag Scenario", zones = {
          zone({ id = "bag", name = "Bag", shared = true, kind = "widget", widgetKind = "tokenBag",
            bagImagePath = "bag.png", bagEntries = { models.DeckEntry.new("plus1.png", 2) } }),
        } }) },
      })
      local s = Session.new({ game = g, localPlayerId = "p1", now = now, initialState = H.state({ players = { p1 } }) })
      s:loadScenario("scen2", "p1")
      t.eq(#s.state.widgets, 1)
      local w = s.state.widgets[1]
      t.isNil(w.ownerId)
      t.eq({ w.kind, w.zoneId, w.imagePath }, { "tokenBag", "bag", "bag.png" })
      t.eq(w.bagRemaining, { "plus1.png", "plus1.png" })
    end)
  end)

  t.describe("token bag", function()
    local function bagGame()
      return game({ zones = {
        zone({ id = "bag", name = "Bag", shared = true, kind = "widget", widgetKind = "tokenBag",
          bagEntries = { models.DeckEntry.new("plus1.png", 2), models.DeckEntry.new("skull.png", 1) } }),
      } })
    end
    local function bagSession()
      return Session.dealFromZones({ game = bagGame(), players = { p1, p2 }, localPlayerId = "p1", now = now })
    end
    local function bagWidget(s) return util.find(s.state.widgets, function(w) return w.kind == "tokenBag" end) end

    t.it("drawBagToken reveals one token (deterministic via rng), no-op when empty", function()
      local s = bagSession()
      local bag = bagWidget(s)
      s:drawBagToken(bag.instanceId, "p1", function() return 1 end)
      local reveal = bagWidget(s)
      t.eq(#reveal.bagRemaining, 2)
      t.eq(#reveal.bagRevealed, 1)
      t.eq(lastLog(s), "Alice drew a token from the Bag.")
      local emptyBag = Session.new({ game = game({ zones = {} }), localPlayerId = "p1", now = now,
        initialState = H.state({ players = { p1 }, widgets = { H.widget({ id = "b", kind = "tokenBag" }) } }) })
      emptyBag:drawBagToken("b", "p1")
      t.eq(emptyBag.state.revision, 0)
    end)

    t.it("returnBagToken honors the zone's bagReturnable toggle", function()
      local s = bagSession()
      local bag = bagWidget(s)
      s:drawBagToken(bag.instanceId, "p1", function() return 1 end)
      local slotId = bagWidget(s).bagRevealed[1].slotId
      s:returnBagToken(bag.instanceId, slotId, "p1")
      t.eq(#bagWidget(s).bagRemaining, 3)
      t.eq(lastLog(s), "Alice returned a token to the bag.")

      local g2 = game({ zones = { zone({ id = "bag", name = "Bag", shared = true, kind = "widget",
        widgetKind = "tokenBag", bagReturnable = false, bagEntries = { models.DeckEntry.new("x.png", 1) } }) } })
      local s2 = Session.dealFromZones({ game = g2, players = { p1 }, localPlayerId = "p1", now = now })
      local bag2 = bagWidget(s2)
      s2:drawBagToken(bag2.instanceId, "p1", function() return 1 end)
      local slot2 = bagWidget(s2).bagRevealed[1].slotId
      s2:returnBagToken(bag2.instanceId, slot2, "p1")
      t.eq(#bagWidget(s2).bagRemaining, 0)
      t.eq(lastLog(s2), "Alice discarded a token from the bag.")
    end)

    t.it("placeBagTokenOnTable creates a large unowned imageToken and clears the reveal", function()
      local s = bagSession()
      local bag = bagWidget(s)
      s:drawBagToken(bag.instanceId, "p1", function() return 1 end)
      local slotId = bagWidget(s).bagRevealed[1].slotId
      s:placeBagTokenOnTable(bag.instanceId, slotId, "placed1", 0.3, 0.4, "p1")
      t.eq(#bagWidget(s).bagRevealed, 0)
      local placed = util.find(s.state.widgets, function(w) return w.instanceId == "placed1" end)
      t.eq({ placed.kind, placed.x, placed.y, placed.sizeOverride, placed.ownerId }, { "imageToken", 0.3, 0.4, 100, nil })
      t.eq(lastLog(s), "Alice placed a token from the bag onto the table.")
    end)

    t.it("resetBag restores full contents and clears revealed", function()
      local s = bagSession()
      local bag = bagWidget(s)
      s:drawBagToken(bag.instanceId, "p1", function() return 1 end)
      s:resetBag(bag.instanceId, "p1")
      local reset = bagWidget(s)
      t.eq(#reset.bagRemaining, 3)
      t.eq(#reset.bagRevealed, 0)
      t.eq(lastLog(s), "Alice reset the token bag.")
    end)

    t.it("returnImageTokenToBag works on any imageToken, not just ones drawn from that bag", function()
      local s = bagSession()
      local bag = bagWidget(s)
      s.state = util.copyWith(s.state, { widgets = util.concat(s.state.widgets,
        { H.widget({ id = "loose", kind = "imageToken", imagePath = "unrelated.png" }) }) })
      s:returnImageTokenToBag(bag.instanceId, "loose", "p1")
      t.isNil(util.find(s.state.widgets, function(w) return w.instanceId == "loose" end))
      t.ok(util.contains(bagWidget(s).bagRemaining, "unrelated.png"))
      t.eq(lastLog(s), "Alice put a token away in the bag.")
    end)
  end)

  t.describe("stacking", function()
    local function session()
      return Session.new({ game = game({}), localPlayerId = "p1", now = now, initialState = H.state({ players = { p1, p2 }, cards = {
        H.card({ id = "mine", ownerId = "p1", x = 0.1, y = 0.1, zIndex = 1 }),
        H.card({ id = "mine2", ownerId = "p1", x = 0.3, y = 0.3, zIndex = 2 }),
        H.card({ id = "free", x = 0.5, y = 0.5, zIndex = 3 }),
        H.card({ id = "theirs", ownerId = "p2", x = 0.7, y = 0.7, zIndex = 4 }),
        H.card({ id = "under", ownerId = "p2", x = 0.9, y = 0.9, zIndex = 5 }),
        H.card({ id = "over", x = 0.9, y = 0.9, stackParentId = "under", zIndex = 6 }),
      } }) })
    end
    t.it("stacks only onto piles with the same owner", function()
      local s = session()
      s:stackCard("mine", "mine2", "p1")
      t.eq(s:findCard("mine").stackParentId, "mine2")
      s:stackCard("mine2", "free", "p1")
      t.isNil(s:findCard("mine2").stackParentId, "your card onto an unowned pile")
      s:stackCard("free", "mine2", "p1")
      t.isNil(s:findCard("free").stackParentId, "an unowned card onto your pile")
      t.ok(s:canStackOnto("over", "free"), "unowned onto unowned")
    end)
    t.it("treats unownable cards as unowned", function()
      local s = session()
      s.state.cards[#s.state.cards + 1] = H.card({ id = "u", ownerId = "p1", unownable = true, zIndex = 7 })
      t.ok(s:canStackOnto("u", "free"))
      t.notOk(s:canStackOnto("u", "mine"))
    end)
    t.it("silently refuses a pile holding another player's card", function()
      local s = session()
      local rev = s.state.revision
      s:stackCard("mine", "theirs", "p1")
      t.isNil(s:findCard("mine").stackParentId)
      t.eq(s:findCard("mine").x, 0.1)
      -- The top card is unowned, but the pile below it is p2's.
      s:stackCard("mine", "over", "p1")
      t.isNil(s:findCard("mine").stackParentId)
      t.eq(s.state.revision, rev)
      t.notOk(s:canStackOnto("mine", "over"))
    end)
    t.it("won't change the owner of a card in a pile", function()
      local s = session()
      s:stackCard("mine", "mine2", "p1")
      s:giveCard("mine", "p2", "p1")
      t.eq(s:findCard("mine").ownerId, "p1")
      s:giveCard("mine2", "p2", "p1")
      t.eq(s:findCard("mine2").ownerId, "p1")
      s:giveCard("mine", nil, "p1")
      t.eq(s:findCard("mine").ownerId, "p1", "nor released")
      s:giveCard("free", "p2", "p1")
      t.eq(s:findCard("free").ownerId, "p2", "a loose card can be given")
    end)
  end)

  t.describe("arrows", function()
    t.it("expire after 5 seconds via update()", function()
      clock = 0
      local s = Session.new({ game = game({}), localPlayerId = "p1", now = now, initialState = H.state({ players = { p1 } }) })
      s:createArrow("ar", 0, 0, 1, 1, "p1")
      clock = 4.9
      s:update()
      t.eq(#s.state.widgets, 1)
      clock = 5
      s:update()
      t.eq(#s.state.widgets, 0)
    end)
  end)

  t.describe("controllers", function()
    local g = game({ zones = { zone({ id = "draw", name = "Draw" }), zone({ id = "pool", name = "Pool", shared = true }) } })
    t.it("host controller enforces ownership and resolves zone owners", function()
      local s = Session.new({ game = g, localPlayerId = "p1", now = now, isLocalPractice = true, initialState = H.state({ players = { p1, p2 }, cards = {
        H.card({ id = "mine", ownerId = "p1" }), H.card({ id = "theirs", ownerId = "p2", zIndex = 1 }),
        H.card({ id = "d1", zone = "zone", zoneId = "draw", ownerId = "p2", zIndex = 2 }),
        H.card({ id = "s1", zone = "zone", zoneId = "pool", zIndex = 3 }),
      } }) })
      local c = controller.Host.new(s)
      c:moveCard("theirs", 0.9, 0.9)
      t.eq(s:findCard("theirs").x, 0)
      c:moveCard("mine", 0.9, 0.9)
      t.eq(s:findCard("mine").x, 0.9)
      c:drawFromZone("pool")
      t.eq(s:findCard("s1").ownerId, "p1")
      c:drawFromZone("draw")
      t.eq(s:findCard("d1").zone, "zone", "p1's own draw zone is empty; p2's untouched")
      s:setActiveSeat("p2")
      c:drawFromZone("draw")
      t.eq(s:findCard("d1").ownerId, "p2")
      t.eq(s:findCard("d1").zone, "hand")
    end)
    t.it("client controller sends Flutter-compatible payloads", function()
      local sent = {}
      local c = controller.Client.new(function(type, payload) sent[#sent + 1] = { type, json.encode(payload) } end)
      c:moveCard("i", 0.5, 0.25)
      c:giveCard("i", nil)
      c:moveGroup("p", { "a", "b" }, 1, 0)
      c:returnToZone("i", "z")
      c:stopSearch()
      c:loadScenario("scen1")
      c:drawBagToken("bag1")
      c:returnBagToken("bag1", "slot1")
      c:placeBagTokenOnTable("bag1", "slot1", "new1", 0.4, 0.5)
      c:resetBag("bag1")
      c:returnImageTokenToBag("bag1", "tok1")
      t.eq(sent[1], { "requestMove", '{"instanceId":"i","x":0.5,"y":0.25}' })
      t.eq(sent[2], { "requestGiveCard", '{"instanceId":"i","newOwnerId":null}' })
      t.eq(sent[3], { "requestMoveGroup", '{"primaryInstanceId":"p","passengerRootInstanceIds":["a","b"],"x":1,"y":0}' })
      t.eq(sent[4], { "requestReturnToZone", '{"instanceId":"i","zoneId":"z","toBottom":false}' })
      t.eq(sent[5], { "requestStopSearch", "{}" })
      t.eq(sent[6], { "requestLoadScenario", '{"scenarioId":"scen1"}' })
      t.eq(sent[7], { "requestDrawBagToken", '{"instanceId":"bag1"}' })
      t.eq(sent[8], { "requestReturnBagToken", '{"instanceId":"bag1","slotId":"slot1"}' })
      t.eq(sent[9], { "requestPlaceBagTokenOnTable",
        '{"instanceId":"bag1","slotId":"slot1","newInstanceId":"new1","x":0.4,"y":0.5}' })
      t.eq(sent[10], { "requestResetBag", '{"instanceId":"bag1"}' })
      t.eq(sent[11], { "requestReturnImageTokenToBag", '{"bagInstanceId":"bag1","tokenInstanceId":"tok1"}' })
    end)
    t.it("host controller delegates bag actions straight to the session", function()
      local s = Session.new({ game = g, localPlayerId = "p1", now = now, initialState = H.state({ players = { p1 },
        widgets = { H.widget({ id = "bag", kind = "tokenBag", bagRemaining = { "a.png" } }) } }) })
      local c = controller.Host.new(s)
      c:drawBagToken("bag")
      t.eq(#s:findWidget("bag").bagRevealed, 1)
      t.eq(lastLog(s), "Alice drew a token from the token bag.")
    end)
    t.it("host controller loads a scenario by delegating straight to the session", function()
      local g2 = game({ hasScenarios = true, scenarios = {
        models.Scenario.new({ id = "scen1", name = "Opening", zones = {
          zone({ id = "battlefield", name = "Battlefield", shared = true, entries = { models.DeckEntry.new("a", 1) } }),
        } }),
      } })
      local s = Session.new({ game = g2, localPlayerId = "p1", now = now, initialState = H.state({ players = { p1 } }) })
      local c = controller.Host.new(s)
      c:loadScenario("scen1")
      t.eq(s:zoneDefinition("battlefield").name, "Battlefield")
      t.eq(lastLog(s), 'Alice loaded the "Opening" scenario.')
    end)
  end)
end
