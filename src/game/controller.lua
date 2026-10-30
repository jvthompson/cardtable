-- Port of lib/game/table_controller.dart. The table UI talks only to a
-- controller; the host/practice one calls the session directly, the client
-- one sends request messages (payload keys match the Flutter protocol).
local json = require("lib.json")
local models = require("src.core.models")
local stacks = require("src.core.stack_utils")
local dwz = require("src.core.deck_widget_zones")

local M = {}

---------------------------------------------------------------------------
-- Host / practice
---------------------------------------------------------------------------

local Host = {}
Host.__index = Host
M.Host = Host

-- previewSink (optional) has publishCardDragPreview(playerId, ids, fx, fy),
-- clearCardDragPreview(playerId), publishArrowDragPreview(playerId, fx, fy,
-- fx2, fy2) and clearArrowDragPreview(playerId) -- the host engine.
function Host.new(session, previewSink)
  return setmetatable({ session = session, previewSink = previewSink }, Host)
end

function Host:acting() return self.session:actingPlayerId() end

function Host:isOwnedOrUnowned(instanceId)
  local c = self.session:findCard(instanceId)
  if not c then return false end
  return c.ownerId == nil or c.ownerId == self:acting()
end

function Host:isOwnedOrUnownedStack(rootId)
  for _, c in ipairs(stacks.stackOf(self.session.state.cards, rootId)) do
    if c.ownerId ~= nil and c.ownerId ~= self:acting() then return false end
  end
  return true
end

function Host:zoneOwnerId(zoneId)
  local parsed = dwz.parse(zoneId)
  if parsed then
    local w = self.session:findWidget(parsed.widgetInstanceId)
    return w and w.ownerId or nil
  end
  local zone
  for _, z in ipairs(self.session:effectiveZones()) do
    if z.id == zoneId then
      zone = z
      break
    end
  end
  if zone and zone.shared then return nil end
  return self:acting()
end

function Host:moveCard(id, x, y)
  if self:isOwnedOrUnowned(id) then self.session:moveCard(id, x, y, self:acting()) end
end

function Host:moveGroup(primaryId, passengerRootIds, x, y)
  if self:isOwnedOrUnowned(primaryId) then self.session:moveGroup(primaryId, passengerRootIds, x, y, self:acting()) end
end

function Host:moveStack(rootId, x, y)
  if self:isOwnedOrUnowned(rootId) then self.session:moveStack(rootId, x, y) end
end

function Host:rotateStack(rootId, clockwise)
  if self:isOwnedOrUnowned(rootId) then self.session:rotateStack(rootId, clockwise, self:acting()) end
end

function Host:bringToFront(rootId)
  if self:isOwnedOrUnowned(rootId) then self.session:bringToFront(rootId) end
end

function Host:flipCard(id)
  if self:isOwnedOrUnowned(id) then self.session:flipCard(id, self:acting()) end
end

function Host:giveCard(id, newOwnerId)
  if self:isOwnedOrUnowned(id) then self.session:giveCard(id, newOwnerId, self:acting()) end
end

function Host:stackCard(id, ontoId)
  if self:isOwnedOrUnowned(id) then self.session:stackCard(id, ontoId, self:acting()) end
end

function Host:moveToHand(id) self.session:moveToHand(id, self:acting()) end
function Host:reorderHand(id, targetIndex) self.session:reorderHand(id, targetIndex, self:acting()) end
function Host:drawCard(pileId, count) self.session:drawCard(pileId, self:acting(), count or 1) end
function Host:shufflePile(rootId) self.session:shufflePile(rootId, self:acting()) end

function Host:drawFromZone(zoneId, count)
  self.session:drawFromZone(zoneId, self:zoneOwnerId(zoneId), self:acting(), count or 1)
end

function Host:returnToZone(id, zoneId, toBottom)
  self.session:returnToZone(id, zoneId, self:zoneOwnerId(zoneId), toBottom or false, self:acting())
end

function Host:shuffleZone(zoneId) self.session:shuffleZone(zoneId, self:zoneOwnerId(zoneId), self:acting()) end
function Host:loadDeckIntoZone(zoneId, deck) self.session:loadDeckIntoZone(zoneId, deck, self:acting()) end
function Host:loadScenario(scenarioId) self.session:loadScenario(scenarioId, self:acting()) end
function Host:startSearchZone(zoneId) self.session:startSearchZone(zoneId, self:zoneOwnerId(zoneId), self:acting()) end

function Host:startSearchPile(rootId)
  if self:isOwnedOrUnownedStack(rootId) then self.session:startSearchPile(rootId, self:acting()) end
end

function Host:stopSearch() self.session:stopSearch(self:acting()) end
function Host:createWidget(id, kind, x, y, imagePath) self.session:createWidget(id, kind, x, y, self:acting(), imagePath) end
function Host:createArrow(id, x, y, x2, y2) self.session:createArrow(id, x, y, x2, y2, self:acting()) end
function Host:moveWidget(id, x, y) self.session:moveWidget(id, x, y) end
function Host:setWidgetValue(id, value) self.session:setWidgetValue(id, value, self:acting()) end
function Host:deleteWidget(id) self.session:deleteWidget(id) end
function Host:setWidgetColors(id, bg, text) self.session:setWidgetColors(id, bg, text) end
function Host:duplicateWidget(srcId, newId, x, y) self.session:duplicateWidget(srcId, newId, x, y) end
function Host:attachWidgetToCard(id, cardId, x, y) self.session:attachWidgetToCard(id, cardId, x, y, self:acting()) end
function Host:drawBagToken(id) self.session:drawBagToken(id, self:acting()) end
function Host:returnBagToken(id, slotId) self.session:returnBagToken(id, slotId, self:acting()) end
function Host:placeBagTokenOnTable(id, slotId, newId, x, y) self.session:placeBagTokenOnTable(id, slotId, newId, x, y, self:acting()) end
function Host:resetBag(id) self.session:resetBag(id, self:acting()) end
function Host:returnImageTokenToBag(bagId, tokenId) self.session:returnImageTokenToBag(bagId, tokenId, self:acting()) end
function Host:generatePack(setId) self.session:generatePack(setId, self:acting()) end
function Host:createCardFromLibrary(defId, x, y) self.session:createCardFromLibrary(defId, x, y, self:acting()) end

function Host:previewCardDrag(primaryId, passengerRootIds, fx, fy)
  if not self.previewSink then return end
  local ids = { primaryId }
  for _, id in ipairs(passengerRootIds or {}) do ids[#ids + 1] = id end
  self.previewSink:publishCardDragPreview(self:acting(), ids, fx, fy)
end

function Host:endCardDragPreview()
  if self.previewSink then self.previewSink:clearCardDragPreview(self:acting()) end
end

function Host:previewArrowDrag(fx, fy, fx2, fy2)
  if self.previewSink then self.previewSink:publishArrowDragPreview(self:acting(), fx, fy, fx2, fy2) end
end

function Host:endArrowDragPreview()
  if self.previewSink then self.previewSink:clearArrowDragPreview(self:acting()) end
end

---------------------------------------------------------------------------
-- Client: every action becomes a request message to the host.
---------------------------------------------------------------------------

local Client = {}
Client.__index = Client
M.Client = Client

-- send(type, payloadObject) delivers a message to the host.
function Client.new(send)
  return setmetatable({ send = send }, Client)
end

local function p(...) return json.object({ ... }) end

function Client:moveCard(id, x, y) self.send("requestMove", p("instanceId", id, "x", x, "y", y)) end

function Client:moveGroup(primaryId, passengerRootIds, x, y)
  self.send("requestMoveGroup", p("primaryInstanceId", primaryId,
    "passengerRootInstanceIds", json.array(passengerRootIds), "x", x, "y", y))
end

function Client:moveStack(rootId, x, y) self.send("requestMoveStack", p("rootInstanceId", rootId, "x", x, "y", y)) end
function Client:rotateStack(rootId, clockwise) self.send("requestRotateStack", p("rootInstanceId", rootId, "clockwise", clockwise)) end
function Client:bringToFront(rootId) self.send("requestBringToFront", p("rootInstanceId", rootId)) end
function Client:flipCard(id) self.send("requestFlip", p("instanceId", id)) end

function Client:giveCard(id, newOwnerId)
  self.send("requestGiveCard", p("instanceId", id, "newOwnerId", newOwnerId == nil and json.null or newOwnerId))
end

function Client:stackCard(id, ontoId) self.send("requestStack", p("instanceId", id, "ontoInstanceId", ontoId)) end
function Client:moveToHand(id) self.send("requestMoveToHand", p("instanceId", id)) end
function Client:reorderHand(id, targetIndex) self.send("requestReorderHand", p("instanceId", id, "targetIndex", targetIndex)) end
function Client:drawCard(pileId, count) self.send("requestDraw", p("pileInstanceId", pileId, "count", count or 1)) end
function Client:shufflePile(rootId) self.send("requestShuffle", p("pileRootInstanceId", rootId)) end
function Client:drawFromZone(zoneId, count) self.send("requestDrawFromZone", p("zoneId", zoneId, "count", count or 1)) end

function Client:returnToZone(id, zoneId, toBottom)
  self.send("requestReturnToZone", p("instanceId", id, "zoneId", zoneId, "toBottom", toBottom or false))
end

function Client:shuffleZone(zoneId) self.send("requestShuffleZone", p("zoneId", zoneId)) end

function Client:loadDeckIntoZone(zoneId, deck)
  self.send("requestLoadDeckIntoZone", p("zoneId", zoneId, "deck", models.DeckConfig.toJson(deck)))
end

function Client:loadScenario(scenarioId) self.send("requestLoadScenario", p("scenarioId", scenarioId)) end

function Client:startSearchZone(zoneId) self.send("requestStartSearchZone", p("zoneId", zoneId)) end
function Client:startSearchPile(rootId) self.send("requestStartSearchPile", p("pileRootInstanceId", rootId)) end
function Client:stopSearch() self.send("requestStopSearch", p()) end
function Client:createWidget(id, kind, x, y, imagePath)
  self.send("requestCreateWidget", p("instanceId", id, "kind", kind, "x", x, "y", y, "imagePath", imagePath))
end

function Client:createArrow(id, x, y, x2, y2)
  self.send("requestCreateArrow", p("instanceId", id, "x", x, "y", y, "x2", x2, "y2", y2))
end

function Client:moveWidget(id, x, y) self.send("requestMoveWidget", p("instanceId", id, "x", x, "y", y)) end
function Client:setWidgetValue(id, value) self.send("requestSetWidgetValue", p("instanceId", id, "value", value)) end
function Client:deleteWidget(id) self.send("requestDeleteWidget", p("instanceId", id)) end

function Client:setWidgetColors(id, bg, text)
  self.send("requestSetWidgetColors", p("instanceId", id, "backgroundColor", bg, "textColor", text))
end

function Client:duplicateWidget(srcId, newId, x, y)
  self.send("requestDuplicateWidget", p("sourceInstanceId", srcId, "newInstanceId", newId, "x", x, "y", y))
end

function Client:attachWidgetToCard(id, cardId, x, y)
  self.send("requestAttachWidgetToCard", p("instanceId", id, "cardId", cardId, "x", x, "y", y))
end

function Client:drawBagToken(id) self.send("requestDrawBagToken", p("instanceId", id)) end
function Client:returnBagToken(id, slotId) self.send("requestReturnBagToken", p("instanceId", id, "slotId", slotId)) end

function Client:placeBagTokenOnTable(id, slotId, newId, x, y)
  self.send("requestPlaceBagTokenOnTable", p("instanceId", id, "slotId", slotId, "newInstanceId", newId, "x", x, "y", y))
end

function Client:resetBag(id) self.send("requestResetBag", p("instanceId", id)) end

function Client:returnImageTokenToBag(bagId, tokenId)
  self.send("requestReturnImageTokenToBag", p("bagInstanceId", bagId, "tokenInstanceId", tokenId))
end

function Client:generatePack(setId) self.send("requestGeneratePack", p("setId", setId)) end

function Client:createCardFromLibrary(defId, x, y)
  self.send("requestCreateCardFromLibrary", p("definitionId", defId, "x", x, "y", y))
end

function Client:previewCardDrag(primaryId, passengerRootIds, fx, fy)
  local ids = { primaryId }
  for _, id in ipairs(passengerRootIds or {}) do ids[#ids + 1] = id end
  self.send("cardDragPreview", p("instanceIds", json.array(ids), "fx", fx, "fy", fy))
end

function Client:endCardDragPreview() self.send("cardDragPreviewEnd", p()) end
function Client:previewArrowDrag(fx, fy, fx2, fy2) self.send("arrowDragPreview", p("fx", fx, "fy", fy, "fx2", fx2, "fy2", fy2)) end
function Client:endArrowDragPreview() self.send("arrowDragPreviewEnd", p()) end

return M
