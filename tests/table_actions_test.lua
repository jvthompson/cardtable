-- Port of test/table_actions_test.dart (condensed: one or more assertions
-- per Dart test group, covering every documented behavior).
local H = require("tests.helpers")
local A = require("src.core.table_actions")

return function(t)
  local card, find = H.card, H.find

  local function pile()
    return H.state({ cards = {
      card({ id = "root", definitionId = "d1", zIndex = 0 }),
      card({ id = "a", definitionId = "d2", zIndex = 1, stackParentId = "root" }),
      card({ id = "b", definitionId = "d3", zIndex = 2, stackParentId = "root" }),
    } })
  end

  local function zone(zoneId, ownerId)
    return H.state({ cards = {
      card({ id = "z1", definitionId = "d1", zIndex = 0, zone = "zone", zoneId = zoneId, ownerId = ownerId }),
      card({ id = "z2", definitionId = "d2", zIndex = 1, zone = "zone", zoneId = zoneId, ownerId = ownerId }),
      card({ id = "z3", definitionId = "d3", zIndex = 2, zone = "zone", zoneId = zoneId, ownerId = ownerId }),
    } })
  end

  t.describe("moveCard", function()
    t.it("updates position, detaches, moves to table, clears zoneId", function()
      local s = H.state({ cards = {
        card({ id = "c", zone = "zone", zoneId = "deck", stackParentId = "p", zIndex = 3 }),
        card({ id = "p", zIndex = 5 }),
      } })
      local n = A.moveCard(s, "c", 0.4, 0.6)
      local c = find(n.cards, "c")
      t.eq({ c.x, c.y, c.zone, c.zIndex }, { 0.4, 0.6, "table", 6 })
      t.isNil(c.stackParentId)
      t.isNil(c.zoneId)
      t.eq(n.revision, 1)
      t.eq(s.revision, 0, "original state untouched")
      t.eq(find(s.cards, "c").zone, "zone")
    end)
    t.it("drags along attached widgets", function()
      local s = H.state({ cards = { card({ id = "c", x = 0.1, y = 0.1 }) },
        widgets = { H.widget({ id = "w", x = 0.15, y = 0.12, attachedCardId = "c", attachOffsetX = 0.05, attachOffsetY = 0.02 }) } })
      local n = A.moveCard(s, "c", 0.5, 0.5)
      t.near(n.widgets[1].x, 0.55)
      t.near(n.widgets[1].y, 0.52)
    end)
    t.it("clears ownerId only for unownable cards", function()
      local s = H.state({ cards = { card({ id = "u", ownerId = "p1", unownable = true }), card({ id = "o", ownerId = "p1" }) } })
      t.isNil(find(A.moveCard(s, "u", 0, 0).cards, "u").ownerId)
      t.eq(find(A.moveCard(s, "o", 0, 0).cards, "o").ownerId, "p1")
    end)
  end)

  t.describe("moveStack", function()
    t.it("moves every member, bumps only the top", function()
      local n = A.moveStack(pile(), "root", 0.3, 0.3)
      for _, c in ipairs(n.cards) do t.eq({ c.x, c.y }, { 0.3, 0.3 }) end
      t.eq(find(n.cards, "b").zIndex, 3)
      t.eq(find(n.cards, "a").zIndex, 1)
      t.eq(find(n.cards, "a").stackParentId, "root")
    end)
    t.it("no-op for unknown root", function()
      local s = pile()
      t.ok(A.moveStack(s, "nope", 0, 0) == s)
    end)
  end)

  t.describe("moveGroup", function()
    t.it("translates passengers by the primary's delta and orders z", function()
      local s = H.state({ cards = {
        card({ id = "p", x = 0.1, y = 0.1, zIndex = 0 }),
        card({ id = "q", x = 0.2, y = 0.3, zIndex = 1 }),
        card({ id = "r", x = 0.5, y = 0.5, zIndex = 2 }),
        card({ id = "r2", x = 0.5, y = 0.5, zIndex = 3, stackParentId = "r" }),
      } })
      local n = A.moveGroup(s, "p", { "q", "r" }, 0.2, 0.2)
      local q = find(n.cards, "q")
      t.near(q.x, 0.3)
      t.near(q.y, 0.4)
      t.near(find(n.cards, "r2").x, 0.6)
      t.eq(find(n.cards, "p").zIndex, 4)
      t.eq(q.zIndex, 5)
      t.eq(find(n.cards, "r2").zIndex, 6)
      t.eq(find(n.cards, "r").zIndex, 2)
    end)
    t.it("unownable primary loses owner, passengers keep theirs; unknown primary no-op", function()
      local s = H.state({ cards = {
        card({ id = "p", ownerId = "p1", unownable = true }),
        card({ id = "q", ownerId = "p1", unownable = true, zIndex = 1 }),
      } })
      local n = A.moveGroup(s, "p", { "q" }, 0.1, 0.1)
      t.isNil(find(n.cards, "p").ownerId)
      t.eq(find(n.cards, "q").ownerId, "p1")
      t.ok(A.moveGroup(s, "zzz", {}, 0, 0) == s)
    end)
  end)

  t.describe("rotateStack", function()
    t.it("rotates every table card in the stack, top bumped", function()
      local n = A.rotateStack(pile(), "root", true)
      for _, c in ipairs(n.cards) do t.eq(c.rotationTurns, 1) end
      t.eq(find(n.cards, "b").zIndex, 3)
      n = A.rotateStack(n, "root", false)
      n = A.rotateStack(n, "root", false)
      t.eq(find(n.cards, "a").rotationTurns, -1)
    end)
    t.it("does not rotate non-table cards", function()
      local s = H.state({ cards = { card({ id = "h", zone = "hand", ownerId = "p1" }) } })
      t.eq(find(A.rotateStack(s, "h", true).cards, "h").rotationTurns, 0)
    end)
  end)

  t.describe("flip/give/bringToFront", function()
    t.it("flipCard toggles and bumps z", function()
      local n = A.flipCard(pile(), "a")
      t.eq(find(n.cards, "a").faceUp, true)
      t.eq(find(n.cards, "a").zIndex, 3)
    end)
    t.it("giveCard", function()
      local s = H.state({ cards = { card({ id = "c", ownerId = "p1" }), card({ id = "u", unownable = true }) } })
      t.eq(find(A.giveCard(s, "c", "p2").cards, "c").ownerId, "p2")
      t.isNil(find(A.giveCard(s, "c", nil).cards, "c").ownerId)
      t.isNil(find(A.giveCard(s, "u", "p2").cards, "u").ownerId)
    end)
    t.it("bringToFront bumps only the top", function()
      local n = A.bringToFront(pile(), "root")
      t.eq(find(n.cards, "b").zIndex, 3)
      t.eq(find(n.cards, "root").zIndex, 0)
    end)
  end)

  t.describe("stackCard", function()
    t.it("snaps to target and links parent", function()
      local s = H.state({ cards = {
        card({ id = "t", x = 0.7, y = 0.2, zIndex = 1 }),
        card({ id = "c", x = 0.1, zone = "zone", zoneId = "deck", ownerId = "p1", unownable = true }),
      } })
      local c = find(A.stackCard(s, "c", "t").cards, "c")
      t.eq({ c.x, c.y, c.zone, c.stackParentId, c.zIndex }, { 0.7, 0.2, "table", "t", 2 })
      t.isNil(c.zoneId)
      t.isNil(c.ownerId)
    end)
    t.it("no-op onto itself or missing target", function()
      local s = pile()
      t.ok(A.stackCard(s, "a", "a") == s)
      t.ok(A.stackCard(s, "a", "zzz") == s)
    end)
  end)

  t.describe("moveToHand / reorderHand", function()
    t.it("moveToHand", function()
      local s = H.state({ cards = { card({ id = "c", zone = "zone", zoneId = "deck", stackParentId = "x", rotationTurns = 2 }) } })
      local c = find(A.moveToHand(s, "c", "p1").cards, "c")
      t.eq({ c.zone, c.ownerId, c.faceUp, c.rotationTurns }, { "hand", "p1", true, 0 })
      t.isNil(c.zoneId)
      t.isNil(c.stackParentId)
    end)
    local function hand()
      return H.state({ cards = {
        card({ id = "h1", zone = "hand", ownerId = "p1", zIndex = 0 }),
        card({ id = "h2", zone = "hand", ownerId = "p1", zIndex = 1 }),
        card({ id = "h3", zone = "hand", ownerId = "p1", zIndex = 2 }),
        card({ id = "o", zone = "hand", ownerId = "p2", zIndex = 3 }),
      } })
    end
    local function order(s, owner) return t.ids(A.handCards(s, owner)) end
    t.it("reorders", function()
      t.eq(order(A.reorderHand(hand(), "h3", "p1", 0), "p1"), { "h3", "h1", "h2" })
      t.eq(order(A.reorderHand(hand(), "h1", "p1", 1), "p1"), { "h2", "h1", "h3" })
      t.eq(order(A.reorderHand(hand(), "h1", "p1", 99), "p1"), { "h2", "h3", "h1" })
      t.eq(find(A.reorderHand(hand(), "h1", "p1", 1).cards, "o").zIndex, 3)
      local s = hand()
      t.ok(A.reorderHand(s, "o", "p1", 0) == s)
    end)
  end)

  t.describe("drawCard", function()
    t.it("draws the top, never the anchor until last", function()
      local s = A.drawCard(pile(), "root", "p1")
      t.eq(find(s.cards, "b").zone, "hand")
      s = A.drawCard(s, "root", "p1")
      t.eq(find(s.cards, "a").zone, "hand")
      s = A.drawCard(s, "root", "p1")
      t.eq(find(s.cards, "root").zone, "hand")
      t.eq(find(s.cards, "root").ownerId, "p1")
    end)
    t.it("count draws top-first in one revision, clamps, count 0 no-op", function()
      local n, drawn = A.drawCard(pile(), "root", "p1", 3)
      t.eq(drawn, { "b", "a", "root" })
      t.eq(n.revision, 1)
      t.eq(find(n.cards, "b").zIndex, 3)
      t.eq(find(n.cards, "root").zIndex, 5)
      local _, d2 = A.drawCard(pile(), "root", "p1", 10)
      t.eq(#d2, 3)
      local s = pile()
      t.ok(A.drawCard(s, "root", "p1", 0) == s)
      t.ok(A.drawCard(s, "nope", "p1") == s)
    end)
    t.it("resets rotation", function()
      local s = H.state({ cards = { card({ id = "solo", rotationTurns = 1 }) } })
      t.eq(A.drawCard(s, "solo", "p1").cards[1].rotationTurns, 0)
    end)
  end)

  t.describe("drawFromZone", function()
    t.it("draws the top of an owned or shared zone", function()
      local n = A.drawFromZone(zone("deck", "p1"), "deck", "p1", "p1")
      local z3 = find(n.cards, "z3")
      t.eq({ z3.zone, z3.ownerId, z3.faceUp }, { "hand", "p1", true })
      t.isNil(z3.zoneId)
      n = A.drawFromZone(zone("deck", nil), "deck", nil, "p2")
      t.eq(find(n.cards, "z3").ownerId, "p2")
    end)
    t.it("count, clamp, no-ops", function()
      local n, drawn = A.drawFromZone(zone("deck", nil), "deck", nil, "p1", 2)
      t.eq(drawn, { "z3", "z2" })
      t.eq(n.revision, 1)
      local s = zone("deck", nil)
      t.ok(A.drawFromZone(s, "deck", "p1", "p1") == s, "owner mismatch")
      t.ok(A.drawFromZone(s, "deck", nil, "p1", 0) == s)
    end)
  end)

  t.describe("returnToZone", function()
    local function withLoose(base, loose)
      local cards = {}
      for _, c in ipairs(base.cards) do cards[#cards + 1] = c end
      cards[#cards + 1] = loose
      return H.state({ cards = cards })
    end
    t.it("places on top by default, owned by zone, snapped to anchor", function()
      local s = withLoose(H.state({ cards = {
        card({ id = "z1", x = 0.3, y = 0.4, zone = "zone", zoneId = "deck", ownerId = "p1" }),
      } }), card({ id = "c", x = 0.9, y = 0.9, zone = "hand", ownerId = "p1", zIndex = 5, faceUp = true, rotationTurns = 1 }))
      local c = find(A.returnToZone(s, "c", "deck", "p1", false).cards, "c")
      t.eq({ c.x, c.y, c.zone, c.zoneId, c.ownerId, c.faceUp, c.zIndex, c.rotationTurns }, { 0.3, 0.4, "zone", "deck", "p1", false, 6, 0 })
    end)
    t.it("shared zone stays unowned; faceUp honored", function()
      local s = withLoose(zone("deck", nil), card({ id = "h", zone = "hand", ownerId = "p1", zIndex = 5 }))
      local c = find(A.returnToZone(s, "h", "deck", nil, true).cards, "h")
      t.isNil(c.ownerId)
      t.eq(c.faceUp, true)
    end)
    t.it("toBottom goes below every zone card", function()
      local s = withLoose(zone("deck", nil), card({ id = "h", zIndex = 5 }))
      t.eq(find(A.returnToZone(s, "h", "deck", nil, false, true).cards, "h").zIndex, -1)
    end)
    t.it("empty zone keeps own position; already-in-zone is a no-op", function()
      local s = H.state({ cards = { card({ id = "c", x = 0.2, y = 0.8 }) } })
      local c = A.returnToZone(s, "c", "deck", "p1", false).cards[1]
      t.eq({ c.x, c.y }, { 0.2, 0.8 })
      local z = zone("deck", nil)
      t.ok(A.returnToZone(z, "z1", "deck", nil, false) == z)
    end)
  end)

  t.describe("shuffle", function()
    t.it("shuffleZone flips face-down and reassigns z", function()
      local s = zone("deck", nil)
      local cards = {}
      for i, c in ipairs(s.cards) do cards[i] = H.card({ id = c.instanceId, zone = "zone", zoneId = "deck", zIndex = c.zIndex, faceUp = true }) end
      local n = A.shuffleZone(H.state({ cards = cards }), "deck", nil, 7)
      local zs = {}
      for _, c in ipairs(n.cards) do
        t.eq(c.faceUp, false)
        zs[#zs + 1] = c.zIndex
      end
      table.sort(zs)
      t.eq(zs, { 3, 4, 5 })
      local one = H.state({ cards = { card({ id = "z", zone = "zone", zoneId = "deck" }) } })
      t.ok(A.shuffleZone(one, "deck", nil) == one)
    end)
    t.it("shufflePile", function()
      local n = A.shufflePile(pile(), "root", 3)
      t.eq(#n.cards, 3)
      for _, c in ipairs(n.cards) do t.ok(c.zIndex >= 3) end
      local one = H.state({ cards = { card({ id = "x" }) } })
      t.ok(A.shufflePile(one, "x") == one)
    end)
  end)

  t.describe("searches", function()
    t.it("start replaces, stop removes, stop no-op", function()
      local s = A.startSearch(H.state({}), "p1", "zone", "deck", "p1")
      s = A.startSearch(s, "p2", "pile", "root")
      s = A.startSearch(s, "p1", "zone", "discard")
      t.eq(#s.searches, 2)
      t.eq(s.searches[2].targetId, "discard")
      t.eq(s.revision, 3)
      s = A.stopSearch(s, "p1")
      t.eq(#s.searches, 1)
      local same = A.stopSearch(s, "p1")
      t.ok(same == s)
    end)
  end)

  t.describe("widgets", function()
    t.it("create / arrow / move / attach / value / colors / duplicate", function()
      local s = A.createWidget(H.state({ cards = { card({ id = "c", x = 0.5, y = 0.5 }) } }), "w1", "simpleCounter", 0.1, 0.2)
      s = A.createWidget(s, "w2", "deckBuilder", 0.1, 0.2, "p1")
      t.eq(t.ids(s.widgets), { "w1", "w2" })
      t.eq(s.widgets[2].zIndex, 1)
      t.eq(s.widgets[2].ownerId, "p1")
      t.isNil(s.widgets[1].ownerId)
      s = A.createArrow(s, "ar", 0, 0, 1, 1, "p1")
      t.eq({ s.widgets[3].kind, s.widgets[3].x2, s.widgets[3].creatorId, s.widgets[3].zIndex }, { "arrow", 1, "p1", 2 })
      s = A.attachWidgetToCard(s, "w1", "c", 0.52, 0.47)
      local w1 = find(s.widgets, "w1")
      t.eq({ w1.x, w1.y, w1.attachedCardId }, { 0.52, 0.47, "c" })
      t.near(w1.attachOffsetX, 0.02)
      t.near(w1.attachOffsetY, -0.03)
      local same = A.attachWidgetToCard(s, "w1", "missing", 0, 0)
      t.ok(same == s)
      s = A.moveWidget(s, "w1", 0.9, 0.9)
      w1 = find(s.widgets, "w1")
      t.isNil(w1.attachedCardId)
      t.eq(w1.attachOffsetX, 0)
      local rev = s.revision
      t.eq(A.moveWidget(s, "nope", 0, 0).revision, rev + 1)
      t.eq(find(A.setWidgetValue(s, "w1", -5).widgets, "w1").value, 0)
      t.eq(find(A.setWidgetValue(s, "w1", 123456).widgets, "w1").value, 99999)
      t.eq(find(A.setWidgetValue(s, "w1", 42).widgets, "w1").value, 42)
      s = A.setWidgetColors(s, "w1", 0xFFD32F2F, 0xFF000000)
      t.eq(find(s.widgets, "w1").backgroundColor, 0xFFD32F2F)
      s = A.setWidgetValue(s, "w1", 7)
      s = A.duplicateWidget(s, "w1", "w9", 0.3, 0.3)
      local w9 = find(s.widgets, "w9")
      t.eq({ w9.kind, w9.value, w9.backgroundColor, w9.textColor, w9.x }, { "simpleCounter", 7, 0xFFD32F2F, 0xFF000000, 0.3 })
      local same2 = A.duplicateWidget(s, "nope", "x", 0, 0)
      t.ok(same2 == s)
    end)
    t.it("deleteWidget spills a deckBuilder's cards only", function()
      local s = H.state({ cards = {
        card({ id = "in1", zone = "zone", zoneId = "deckWidget:dw:main_deck", ownerId = "p1", stackParentId = "x" }),
        card({ id = "in2", zone = "zone", zoneId = "deckWidget:dw:side", ownerId = "p1", unownable = true, zIndex = 1 }),
        card({ id = "other", zone = "zone", zoneId = "deckWidget:dw2:main_deck", ownerId = "p1", zIndex = 2 }),
      }, widgets = { H.widget({ id = "dw", kind = "deckBuilder", x = 0.4, y = 0.6, ownerId = "p1" }),
        H.widget({ id = "dw2", kind = "deckBuilder", ownerId = "p1" }) } })
      local n = A.deleteWidget(s, "dw")
      local in1, in2 = find(n.cards, "in1"), find(n.cards, "in2")
      t.eq({ in1.zone, in1.x, in1.y, in1.zIndex, in1.ownerId }, { "table", 0.4, 0.6, 3, "p1" })
      t.isNil(in1.zoneId)
      t.isNil(in1.stackParentId)
      t.eq(in2.zIndex, 4)
      t.isNil(in2.ownerId)
      t.eq(find(n.cards, "other").zone, "zone")
      t.eq(t.ids(n.widgets), { "dw2" })
      t.eq(A.deleteWidget(s, "nope").revision, 1)
    end)
  end)

  t.describe("token bag", function()
    local function bagState(remaining, revealed)
      return H.state({ widgets = { H.widget({ id = "bag", kind = "tokenBag", imagePath = "bag.png",
        bagRemaining = remaining or {}, bagRevealed = revealed or {} }) } })
    end

    t.it("addWidgets: sequential zIndex, single bump, no-op on empty", function()
      local s = H.state({ widgets = { H.widget({ id = "w0", zIndex = 5 }) } })
      local n = A.addWidgets(s, { H.widget({ id = "w1" }), H.widget({ id = "w2" }) })
      t.eq(t.ids(n.widgets), { "w0", "w1", "w2" })
      t.eq({ find(n.widgets, "w1").zIndex, find(n.widgets, "w2").zIndex }, { 6, 7 })
      t.eq(n.revision, 1)
      t.ok(A.addWidgets(s, {}) == s)
    end)

    t.it("revealBagToken removes exactly one match, appends to bagRevealed", function()
      local s = bagState({ "a.png", "a.png", "b.png" })
      local n = A.revealBagToken(s, "bag", "a.png", "slot1")
      local bag = find(n.widgets, "bag")
      t.eq(bag.bagRemaining, { "a.png", "b.png" })
      t.eq(bag.bagRevealed, { { slotId = "slot1", imagePath = "a.png" } })
      t.eq(n.revision, 1)
      t.eq(s.revision, 0, "original state untouched")
    end)

    t.it("resolveBagToken: returnToBag restores it, false drops it, missing slot is a no-op", function()
      local s = bagState({}, { { slotId = "s1", imagePath = "a.png" } })
      local returned = A.resolveBagToken(s, "bag", "s1", true)
      t.eq(find(returned.widgets, "bag").bagRemaining, { "a.png" })
      t.eq(find(returned.widgets, "bag").bagRevealed, {})
      local destroyed = A.resolveBagToken(s, "bag", "s1", false)
      t.eq(find(destroyed.widgets, "bag").bagRemaining, {})
      t.eq(find(destroyed.widgets, "bag").bagRevealed, {})
      local missing = A.resolveBagToken(s, "bag", "nope", true)
      t.eq(find(missing.widgets, "bag").bagRevealed, { { slotId = "s1", imagePath = "a.png" } })
    end)

    t.it("placeBagTokenOnTable removes the revealed slot, appends a sized imageToken", function()
      local s = bagState({}, { { slotId = "s1", imagePath = "skull.png" } })
      local n = A.placeBagTokenOnTable(s, "bag", "s1", "new1", 0.4, 0.6, nil, 100)
      t.eq(find(n.widgets, "bag").bagRevealed, {})
      local placed = find(n.widgets, "new1")
      t.eq({ placed.kind, placed.imagePath, placed.x, placed.y, placed.sizeOverride, placed.ownerId },
        { "imageToken", "skull.png", 0.4, 0.6, 100, nil })
      t.ok(A.placeBagTokenOnTable(s, "bag", "nope", "x", 0, 0) == s)
    end)

    t.it("resetBag replaces bagRemaining wholesale, clears bagRevealed, leaves other widgets alone", function()
      local s = H.state({ widgets = {
        H.widget({ id = "bag", kind = "tokenBag", bagRemaining = { "a.png" }, bagRevealed = { { slotId = "s1", imagePath = "b.png" } } }),
        H.widget({ id = "placed", kind = "imageToken", imagePath = "b.png" }),
      } })
      local n = A.resetBag(s, "bag", { "a.png", "a.png", "b.png" })
      local bag = find(n.widgets, "bag")
      t.eq(bag.bagRemaining, { "a.png", "a.png", "b.png" })
      t.eq(bag.bagRevealed, {})
      t.eq(find(n.widgets, "placed"), find(s.widgets, "placed"), "a placed token is untouched by reset")
    end)

    t.it("returnImageTokenToBag: returnable adds its image back, non-returnable just deletes it", function()
      local s = H.state({ widgets = {
        H.widget({ id = "bag", kind = "tokenBag", bagRemaining = { "a.png" } }),
        H.widget({ id = "tok", kind = "imageToken", imagePath = "zzz.png" }),
      } })
      local returned = A.returnImageTokenToBag(s, "bag", "tok", true)
      t.isNil(find(returned.widgets, "tok"))
      t.eq(find(returned.widgets, "bag").bagRemaining, { "a.png", "zzz.png" })
      local destroyed = A.returnImageTokenToBag(s, "bag", "tok", false)
      t.isNil(find(destroyed.widgets, "tok"))
      t.eq(find(destroyed.widgets, "bag").bagRemaining, { "a.png" })
      t.ok(A.returnImageTokenToBag(s, "bag", "nope", true) == s)
    end)
  end)

  t.describe("dealNewCards", function()
    t.it("appends with ascending z; empty list no-op", function()
      local s = pile()
      local n = A.dealNewCards(s, { card({ id = "n1", zIndex = 99 }), card({ id = "n2", zIndex = 99 }) })
      t.eq(find(n.cards, "n1").zIndex, 3)
      t.eq(find(n.cards, "n2").zIndex, 4)
      t.eq(n.revision, 1)
      t.ok(A.dealNewCards(s, {}) == s)
    end)
  end)
end
