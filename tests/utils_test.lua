-- Ports of seat_utils_test, geometry_utils_test, deck_widget_zones_test,
-- state_filter_test, pack_generator_test, card_sort_menu_test and
-- save_game_remap_test.
local H = require("tests.helpers")
local seats = require("src.core.seat_utils")
local geo = require("src.core.geometry")
local dwz = require("src.core.deck_widget_zones")
local sf = require("src.core.state_filter")
local packs = require("src.core.pack_generator")
local filters = require("src.core.card_filters")
local remap = require("src.core.save_remap")
local models = require("src.core.models")
local util = require("src.core.util")

return function(t)
  local p1, p2, p3, p4 = H.player("p1", "P1", "host"), H.player("p2"), H.player("p3"), H.player("p4")

  t.describe("computeHandRowLayout", function()
    t.it("4 players: near viewers see the same arrangement", function()
      for _, v in ipairs({ p1, p2 }) do
        local l = seats.computeHandRowLayout({ p1, p2, p3, p4 }, v.id)
        t.eq(t.ids(l.bottomRow, "id"), { "p1", "p2" })
        t.eq(t.ids(l.topRow, "id"), { "p3", "p4" })
      end
    end)
    t.it("4 players: far viewers see the rotated arrangement", function()
      for _, v in ipairs({ p3, p4 }) do
        local l = seats.computeHandRowLayout({ p1, p2, p3, p4 }, v.id)
        t.eq(t.ids(l.bottomRow, "id"), { "p4", "p3" })
        t.eq(t.ids(l.topRow, "id"), { "p2", "p1" })
      end
    end)
    t.it("3 players", function()
      local l = seats.computeHandRowLayout({ p1, p2, p3 }, "p1")
      t.eq(t.ids(l.bottomRow, "id"), { "p1" })
      t.eq(t.ids(l.topRow, "id"), { "p2", "p3" })
      for _, v in ipairs({ p2, p3 }) do
        l = seats.computeHandRowLayout({ p1, p2, p3 }, v.id)
        t.eq(t.ids(l.bottomRow, "id"), { "p3", "p2" })
        t.eq(t.ids(l.topRow, "id"), { "p1" })
      end
    end)
    t.it("2 players", function()
      local l = seats.computeHandRowLayout({ p1, p2 }, "p2")
      t.eq(t.ids(l.bottomRow, "id"), { "p2" })
      t.eq(t.ids(l.topRow, "id"), { "p1" })
    end)
  end)

  t.describe("geometry", function()
    t.it("worldCenteringOffset", function()
      local dx, dy = geo.worldCenteringOffset(1600, 900, 2000, 500)
      t.eq(dx, 200)
      t.eq(dy, -200)
    end)
    t.it("clampCardCenterY", function()
      t.eq(geo.clampCardCenterY(200, 400, 100, 10), 200)
      t.eq(geo.clampCardCenterY(-20, 400, 100, 10), -20)
      t.eq(geo.clampCardCenterY(450, 400, 100, 10), 450)
      t.eq(geo.clampCardCenterY(-500, 400, 100, 10), -140)
      t.eq(geo.clampCardCenterY(999, 10, 100, 10), 5)
    end)
    t.it("canonical <-> pixel", function()
      local px, py = geo.canonicalToLocalPixel(0.25, 0.75, 800, 400, true)
      t.eq(px, 600)
      t.eq(py, 100)
      local fx, fy = geo.localPixelToCanonical(200, 300, 800, 400, true)
      t.eq(fx, 0.75)
      t.eq(fy, 0.25)
      t.near((geo.localPixelToCanonical(900, 0, 800, 400, false)), 1.125)
      t.eq((geo.localPixelToCanonical(-1000, 0, 800, 400, false)), -0.5)
      t.eq((geo.localPixelToCanonical(2000, 0, 800, 400, false)), 1.5)
      px, py = geo.canonicalToLocalPixel(0.3, 0.6, 800, 400, true)
      fx, fy = geo.localPixelToCanonical(px, py, 800, 400, true)
      t.near(fx, 0.3)
      t.near(fy, 0.6)
    end)
  end)

  t.describe("deck widget zone ids", function()
    t.it("round-trips, including colons in the real id", function()
      local p = dwz.parse(dwz.build("w1", "weird:zone:id"))
      t.eq(p.widgetInstanceId, "w1")
      t.eq(p.realZoneId, "weird:zone:id")
      t.notOk(dwz.isDeckWidgetZoneId("main_deck"))
    end)
    t.it("malformed strings return nil", function()
      for _, s in ipairs({ "", "deckWidget:", "deckWidget:onlyOnePart", "deckWidget::main_deck", "deckWidget:w1:" }) do
        t.isNil(dwz.parse(s), s)
      end
    end)
  end)

  t.describe("filterForRecipient", function()
    local function twoHands()
      return H.state({ revision = 3, cards = {
        H.card({ id = "mine", definitionId = "hearts_A", faceUp = true, zone = "hand", ownerId = "p1", zIndex = 0 }),
        H.card({ id = "theirs", definitionId = "spades_K", faceUp = true, zone = "hand", ownerId = "p2", zIndex = 1 }),
        H.card({ id = "onTable", definitionId = "clubs_5", x = 10, y = 10, zIndex = 2 }),
      } })
    end
    t.it("hides opponent hand cards only", function()
      local f = sf.filterForRecipient(twoHands(), "p1", {})
      local theirs = H.find(f.cards, "theirs")
      t.eq(theirs.faceUp, false)
      t.eq(theirs.definitionId, models.hiddenDefinitionId)
      t.eq(H.find(f.cards, "mine").definitionId, "hearts_A")
      t.eq(H.find(f.cards, "onTable").definitionId, "clubs_5")
      t.eq(f.revision, 3)
      local f2 = sf.filterForRecipient(twoHands(), "p2", {})
      t.eq(H.find(f2.cards, "mine").definitionId, models.hiddenDefinitionId)
      t.eq(H.find(f2.cards, "theirs").definitionId, "spades_K")
    end)
    t.it("zones: private hidden, shared and visible zones pass through", function()
      local s = H.state({ cards = {
        H.card({ id = "a", definitionId = "x", zone = "zone", zoneId = "draw_deck", ownerId = "p2" }),
        H.card({ id = "b", definitionId = "y", zone = "zone", zoneId = "deck" }),
        H.card({ id = "c", definitionId = "z", faceUp = true, zone = "zone", zoneId = "discard_pile", ownerId = "p2" }),
        H.card({ id = "d", definitionId = "w", faceUp = true, zone = "zone", zoneId = "deckWidget:dw1:main_deck", ownerId = "p2" }),
      } })
      local f = sf.filterForRecipient(s, "p1", { discard_pile = true })
      t.eq(H.find(f.cards, "a").definitionId, models.hiddenDefinitionId)
      t.eq(H.find(f.cards, "b").definitionId, "y")
      t.eq(H.find(f.cards, "c").definitionId, "z")
      t.eq(H.find(f.cards, "c").ownerId, "p2")
      t.eq(H.find(f.cards, "d").definitionId, models.hiddenDefinitionId)
      local own = sf.filterForRecipient(s, "p2", {})
      t.eq(H.find(own.cards, "d").definitionId, "w")
    end)
  end)

  t.describe("selectPackCards", function()
    local function pool(n)
      local out = {}
      for i = 0, n - 1 do out[#out + 1] = H.cardDef("c" .. i) end
      return out
    end
    t.it("no settings: 10 distinct", function()
      local r = packs.selectPackCards(pool(15), {}, util.seededRng(1))
      t.eq(#r, 10)
      t.eq(util.setSize(util.toSet(t.ids(r, "id"))), 10)
      t.eq(#packs.selectPackCards(pool(2), {}, util.seededRng(1)), 2)
    end)
    t.it("tag settings, shortfall, no double counting", function()
      local p = { H.cardDef("r1", { "Rare" }), H.cardDef("r2", { "Rare" }), H.cardDef("r3", { "Rare" }), H.cardDef("c1", { "Common" }) }
      local r = packs.selectPackCards(p, { { tag = "Rare", count = 2 } }, util.seededRng(1))
      t.eq(#r, 2)
      for _, c in ipairs(r) do t.ok(util.contains(c.types, "Rare")) end
      t.eq(#packs.selectPackCards({ H.cardDef("r1", { "Rare" }) }, { { tag = "Rare", count = 5 } }), 1)
      local both = packs.selectPackCards({ H.cardDef("both", { "Rare", "Foil" }) },
        { { tag = "Rare", count = 1 }, { tag = "Foil", count = 1 } })
      t.eq(t.ids(both, "id"), { "both" })
      t.eq(#packs.selectPackCards({}, { { tag = "Rare", count = 3 } }), 0)
    end)
    t.it("seeded rng is deterministic", function()
      local a = packs.selectPackCards(pool(20), {}, util.seededRng(42))
      local b = packs.selectPackCards(pool(20), {}, util.seededRng(42))
      t.eq(t.ids(a, "id"), t.ids(b, "id"))
    end)
    -- A scripted rng: each call pops the next value from `values` (clamped
    -- into range), falling back to 1 once exhausted.
    local function sequenceRng(values)
      local i = 0
      return function(n)
        i = i + 1
        local v = values[i] or 1
        return v > n and n or v
      end
    end
    t.it("fractional-only setting: all-floor-zero falls back to the default fill", function()
      local p = pool(10)
      p[#p + 1] = H.cardDef("legendary", { "Legendary" })
      t.eq(#packs.selectPackCards(p, { { tag = "Legendary", count = 0.4 } }, util.seededRng(1)), 10)
    end)
    t.it("fractional remainder is an additional-card chance on top of the guaranteed counts", function()
      local setCards = { H.cardDef("common1", { "Common" }), H.cardDef("legendary1", { "Legendary" }) }
      local settings = { { tag = "Common", count = 1 }, { tag = "Legendary", count = 0.5 } }
      local hit = packs.selectPackCards(setCards, settings, sequenceRng({ 500000 }))
      t.eq(t.ids(hit, "id"), { "common1", "legendary1" })
      local miss = packs.selectPackCards(setCards, settings, sequenceRng({ 500001 }))
      t.eq(t.ids(miss, "id"), { "common1" })
    end)
    t.it("count >= 1 with a fractional remainder: guaranteed floor, chance of one more", function()
      local setCards = { H.cardDef("r1", { "Rare" }), H.cardDef("r2", { "Rare" }), H.cardDef("r3", { "Rare" }) }
      local settings = { { tag = "Rare", count = 1.5 } }
      local hit = packs.selectPackCards(setCards, settings, sequenceRng({ 1, 1, 500000 }))
      t.eq(#hit, 2)
      local miss = packs.selectPackCards(setCards, settings, sequenceRng({ 1, 1, 999999 }))
      t.eq(#miss, 1)
      for _, c in ipairs(hit) do t.ok(util.contains(c.types, "Rare")) end
    end)
    t.it("matches qualified \"Group|Tag\" entries by tag name", function()
      local p = { H.cardDef("r1", { "Rarity|Rare" }), H.cardDef("c1", { "Rarity|Common" }) }
      local r = packs.selectPackCards(p, { { tag = "Rare", count = 1 } }, util.seededRng(1))
      t.eq(t.ids(r, "id"), { "r1" })
    end)
  end)

  t.describe("card sort/filter", function()
    local sets = { models.GameSet.new({ id = "set_a", name = "A" }), models.GameSet.new({ id = "set_b", name = "B" }) }
    local race = models.TagGroup.new({ id = "race", name = "Race", tags = { "Dunadan", "Elf", "Hobbit" } })
    local d = models.CardDefinition.new({ id = "d", cardTitle = "Dunadan Card", setId = "set_b", types = { "Dunadan" } })
    local e = models.CardDefinition.new({ id = "e", cardTitle = "Elf Card", setId = "set_a", types = { "Elf" } })
    local n = models.CardDefinition.new({ id = "n", cardTitle = "No Race Card", setId = "set_a", types = { "Resource" } })
    local u = models.CardDefinition.new({ id = "u", cardTitle = "No Set Card" })
    local cards = { u, d, n, e }
    t.it("sorts", function()
      t.ok(filters.sortCardDefinitions(cards, nil, sets, { race }) == cards)
      t.eq(t.ids(filters.sortCardDefinitions(cards, "name", sets, { race }), "id"), { "d", "e", "n", "u" })
      t.eq(t.ids(filters.sortCardDefinitions(cards, "set", sets, { race }), "id"), { "e", "n", "d", "u" })
      t.eq(t.ids(filters.sortCardDefinitions(cards, "race", sets, { race }), "id"), { "d", "e", "n", "u" })
    end)
    t.it("filters", function()
      local sel = { race = { Elf = true } }
      t.ok(filters.cardMatchesFilters(e, { race }, sel, {}, {}, ""))
      t.notOk(filters.cardMatchesFilters(n, { race }, sel, {}, {}, ""))
      t.notOk(filters.cardMatchesFilters(e, { race }, {}, { race = { Elf = true } }, {}, ""))
      t.notOk(filters.cardMatchesFilters(d, { race }, {}, {}, { set_a = true }, ""))
      t.ok(filters.cardMatchesFilters(u, { race }, {}, {}, { set_a = true }, ""))
      t.ok(filters.cardMatchesFilters(d, { race }, {}, {}, {}, "  dunADAN "))
      t.notOk(filters.cardMatchesFilters(d, { race }, {}, {}, {}, "zzz"))
    end)

    t.it("extraField search (\":field text\")", function()
      local withField = models.CardDefinition.new({ id = "x", cardTitle = "X Card",
        extraFields = { episode = "Blood Harvest" } })
      t.ok(filters.cardMatchesFilters(withField, {}, {}, {}, {}, ":episode Blood"))
      t.ok(filters.cardMatchesFilters(withField, {}, {}, {}, {}, ":Episode blood harvest"))
      t.notOk(filters.cardMatchesFilters(withField, {}, {}, {}, {}, ":episode zzz"))
      t.notOk(filters.cardMatchesFilters(withField, {}, {}, {}, {}, ":missingfield"))
      t.ok(filters.cardMatchesFilters(withField, {}, {}, {}, {}, ":episode"))
      t.notOk(filters.cardMatchesFilters(d, {}, {}, {}, {}, ":episode"))
    end)

    t.it("qualified tags from a different group with the same name don't cross-match", function()
      local faction = models.TagGroup.new({ id = "faction", name = "Faction", tags = { "Elf", "Human" } })
      -- "e2" carries Faction's "Elf", not Race's -- same tag text, different group.
      local e2 = models.CardDefinition.new({ id = "e2", cardTitle = "Faction Elf Card", types = { "Faction|Elf" } })
      local eQualified = models.CardDefinition.new({ id = "eq", cardTitle = "Race Elf Card", types = { "Race|Elf" } })
      local sel = { race = { Elf = true } }
      t.ok(filters.cardMatchesFilters(eQualified, { race, faction }, sel, {}, {}, ""))
      t.notOk(filters.cardMatchesFilters(e2, { race, faction }, sel, {}, {}, ""))
      -- A legacy bare "Elf" (no group) still matches either group, as before.
      t.ok(filters.cardMatchesFilters(e, { race, faction }, sel, {}, {}, ""))
      t.eq(t.ids(filters.sortCardDefinitions({ e2, eQualified }, "race", sets, { race, faction }), "id"),
        { "eq", "e2" })
    end)
  end)

  t.describe("save remap", function()
    local sA = H.player("saved_alice", "Alice", "host")
    local sB = H.player("saved_bob", "Bob")
    local cA = H.player("cur_alice", "Alice")
    local cB = H.player("cur_bob", "Bob", "host")
    t.it("matchPlayersByName", function()
      local r = remap.matchPlayersByName({ sA, sB }, { cB, cA })
      t.eq(r.matched, { saved_alice = "cur_alice", saved_bob = "cur_bob" })
      t.eq(#r.unmatchedSaved, 0)
      local dup = remap.matchPlayersByName({ sA, H.player("saved_alice2", "Alice") }, { cA })
      t.eq(dup.matched, {})
      t.eq(#dup.unmatchedSaved, 2)
      t.eq(#dup.unmatchedCurrent, 1)
    end)
    t.it("buildLoadedTableState", function()
      local saved = H.state({ players = { sA, sB }, revision = 42, cards = {
        H.card({ id = "c1", definitionId = "card_a", zone = "hand", ownerId = "saved_alice", zIndex = 1 }),
        H.card({ id = "c2", definitionId = "card_b", ownerId = "saved_bob", stackParentId = "c1", zIndex = 2 }),
        H.card({ id = "c3", definitionId = "gone_card", zIndex = 3 }),
      }, widgets = {
        H.widget({ id = "w1", ownerId = "saved_alice", creatorId = "saved_bob", attachedCardId = "c3" }),
      }, searches = { models.ActiveSearch.new({ searcherId = "x", targetType = "zone", targetId = "z" }) },
        log = { models.LogEntry.new(1500, "Alice drew a card") }, currentPlayerId = "saved_bob" })
      local state, dropped = remap.buildLoadedTableState(saved, { cB, cA },
        { saved_alice = "cur_alice", saved_bob = "cur_bob" }, { card_a = true, card_b = true })
      t.eq(t.ids(state.players, "id"), { "cur_alice", "cur_bob" })
      t.eq(dropped, 1)
      t.eq(H.find(state.cards, "c1").ownerId, "cur_alice")
      t.eq(H.find(state.cards, "c2").stackParentId, "c1")
      t.eq(state.widgets[1].ownerId, "cur_alice")
      t.eq(state.widgets[1].creatorId, "cur_bob")
      t.isNil(state.widgets[1].attachedCardId)
      t.eq(#state.searches, 0)
      t.eq(state.revision, 42)
      t.eq(#state.log, 1)
      t.eq(state.log[1].elapsedMs, 1500)
      t.eq(state.currentPlayerId, "cur_bob")
    end)
    t.it("buildLoadedTableState clears currentPlayerId when that player wasn't matched", function()
      local saved = H.state({ players = { sA }, currentPlayerId = "saved_bob" })
      local state = remap.buildLoadedTableState(saved, { cA }, { saved_alice = "cur_alice" }, {})
      t.isNil(state.currentPlayerId)
    end)
    t.it("clears a dangling stackParentId", function()
      local saved = H.state({ players = { sA }, cards = {
        H.card({ id = "child", definitionId = "card_a", stackParentId = "missing_parent", zIndex = 1 }),
        H.card({ id = "missing_parent", definitionId = "gone_card" }),
      } })
      local state = remap.buildLoadedTableState(saved, { cA }, { saved_alice = "cur_alice" }, { card_a = true })
      t.eq(#state.cards, 1)
      t.isNil(state.cards[1].stackParentId)
    end)
  end)

  t.describe("ui.clampLines", function()
    t.it("keeps short text and ellipsizes past the line limit", function()
      local ui = require("src.ui.kit.ui")
      -- Headless: a monospace stand-in (6px per character, word wrap).
      local f = {}
      function f:getWidth(str) return 6 * (require("utf8").len(str) or #str) end
      function f:getWrap(str, w)
        local lines, line = {}, ""
        for word in str:gmatch("%S+") do
          local try = line == "" and word or (line .. " " .. word)
          if line ~= "" and self:getWidth(try) > w then
            lines[#lines + 1], line = line, word
          else
            line = try
          end
        end
        if line ~= "" then lines[#lines + 1] = line end
        return 0, lines
      end
      t.eq(ui.clampLines("Short", f, 90, 3), "Short")
      local long = string.rep("Longword ", 20)
      local out = ui.clampLines(long, f, 90, 3)
      local _, lines = f:getWrap(out, 90)
      t.eq(#lines, 3)
      t.ok(out:sub(-3) == "…", "ends with an ellipsis")
    end)
  end)
end
