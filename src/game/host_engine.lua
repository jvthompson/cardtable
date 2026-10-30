-- Port of lib/game/host_game_engine.dart: the host's authoritative loop.
-- Applies client requests (always as the sending connection's player, with
-- ownership checks), sends each client a filtered fullState once per
-- revision, and relays cosmetic drag/arrow previews.
local json = require("lib.json")
local models = require("src.core.models")
local stacks = require("src.core.stack_utils")
local dwz = require("src.core.deck_widget_zones")
local sf = require("src.core.state_filter")

local E = {}
E.__index = E

function E.new(session, server, hostPlayerId)
  return setmetatable({ session = session, server = server, hostPlayerId = hostPlayerId,
    lastBroadcastRevision = -1, previouslyConnected = {} }, E)
end

function E:start()
  self.listener = self.session:addListener(function() self:broadcast() end)
  self.server.onIncoming = function(id, msg) self:handleMessage(id, msg) end
  self.server.reclaimableIdCheck = function(id)
    for _, p in ipairs(self.session.state.players) do
      if p.id == id and not p.connected then return true end
    end
    return false
  end
  self.server.onRoster = function(roster) self:onRoster(roster) end
  -- Clients already in the lobby count as connected from the start.
  for _, p in ipairs(self.server:roster()) do
    if p.role ~= "host" then self.previouslyConnected[p.id] = true end
  end
  self:broadcast()
end

function E:dispose()
  if self.listener then self.session:removeListener(self.listener) end
  self.server.onIncoming, self.server.onRoster, self.server.reclaimableIdCheck = nil, nil, nil
end

function E:onRoster(roster)
  local connected = {}
  for _, p in ipairs(roster) do
    if p.role ~= "host" then connected[p.id] = true end
  end
  for id in pairs(connected) do
    if not self.previouslyConnected[id] then
      self.server:sendTo(id, "gameData", models.GameDefinition.toJson(self.session.game))
    end
  end
  for id in pairs(self.previouslyConnected) do
    if not connected[id] then
      self:clearCardDragPreview(id)
      self:clearArrowDragPreview(id)
    end
  end
  self.previouslyConnected = connected
  self.session:syncConnectedPlayerIds(connected)
end

function E:broadcast()
  local state = self.session.state
  if state.revision == self.lastBroadcastRevision then return end
  self.lastBroadcastRevision = state.revision
  local visible = {}
  for _, z in ipairs(self.session:effectiveZones()) do
    if z.visibleToAll then visible[z.id] = true end
  end
  for _, p in ipairs(state.players) do
    if p.id ~= self.hostPlayerId then
      self.server:sendTo(p.id, "fullState", models.TableState.toJson(sf.filterForRecipient(state, p.id, visible)))
    end
  end
end

---------------------------------------------------------------------------
-- Permission checks
---------------------------------------------------------------------------

function E:card(id) return models.TableState.cardById(self.session.state, id) end
function E:widget(id) return models.TableState.widgetById(self.session.state, id) end

function E:zoneOwnerId(zoneId, requester)
  local parsed = dwz.parse(zoneId)
  if parsed then
    local w = self:widget(parsed.widgetInstanceId)
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
  return requester
end

function E:allowedDeckWidgetZone(zoneId, requester)
  local parsed = dwz.parse(zoneId)
  if not parsed then return true end
  local w = self:widget(parsed.widgetInstanceId)
  return w ~= nil and w.ownerId == requester
end

function E:allowedCard(id, requester)
  local c = self:card(id)
  return c ~= nil and (c.ownerId == nil or c.ownerId == requester)
end

function E:movableWidget(id, requester)
  local w = self:widget(id)
  if not w then return true end
  if w.zoneId ~= nil then return false end
  return w.ownerId == nil or w.ownerId == requester
end

function E:allowedWidget(id, requester)
  local w = self:widget(id)
  return w ~= nil and (w.ownerId == nil or w.ownerId == requester)
end

function E:allowedDelete(id, requester)
  local w = self:widget(id)
  if not w or not self:movableWidget(id, requester) then return false end
  return w.creatorId == nil or w.creatorId == requester
end

function E:allowedDrawOrShuffle(rootId, requester)
  for _, c in ipairs(stacks.stackOf(self.session.state.cards, rootId)) do
    if c.ownerId ~= nil and c.ownerId ~= requester then return false end
  end
  return true
end

---------------------------------------------------------------------------
-- Requests
---------------------------------------------------------------------------

local function num(v) return type(v) == "number" and v or nil end
local function str(v) return type(v) == "string" and v or nil end

function E:handleMessage(clientId, msg)
  local s = self.session
  local p = msg.payload
  local t = msg.type
  local ok, err = pcall(function()
    if t == "requestMove" then
      if self:allowedCard(p.instanceId, clientId) then s:moveCard(p.instanceId, num(p.x), num(p.y), clientId) end
    elseif t == "requestMoveGroup" then
      if self:allowedCard(p.primaryInstanceId, clientId) then
        local passengers = {}
        for _, id in ipairs(p.passengerRootInstanceIds or {}) do
          if self:allowedCard(id, clientId) then passengers[#passengers + 1] = id end
        end
        s:moveGroup(p.primaryInstanceId, passengers, num(p.x), num(p.y), clientId)
      end
    elseif t == "requestMoveStack" then
      if self:allowedCard(p.rootInstanceId, clientId) then s:moveStack(p.rootInstanceId, num(p.x), num(p.y)) end
    elseif t == "requestRotateStack" then
      if self:allowedCard(p.rootInstanceId, clientId) then s:rotateStack(p.rootInstanceId, p.clockwise == true, clientId) end
    elseif t == "requestBringToFront" then
      if self:allowedCard(p.rootInstanceId, clientId) then s:bringToFront(p.rootInstanceId) end
    elseif t == "requestFlip" then
      if self:allowedCard(p.instanceId, clientId) then s:flipCard(p.instanceId, clientId) end
    elseif t == "requestGiveCard" then
      local newOwner = str(p.newOwnerId)
      local valid = newOwner == nil or models.TableState.playerById(s.state, newOwner) ~= nil
      if self:allowedCard(p.instanceId, clientId) and valid then s:giveCard(p.instanceId, newOwner, clientId) end
    elseif t == "requestStack" then
      if self:allowedCard(p.instanceId, clientId) and self:card(p.ontoInstanceId) then s:stackCard(p.instanceId, p.ontoInstanceId, clientId) end
    elseif t == "requestMoveToHand" then
      if self:allowedCard(p.instanceId, clientId) then s:moveToHand(p.instanceId, clientId) end
    elseif t == "requestReorderHand" then
      if self:allowedCard(p.instanceId, clientId) then s:reorderHand(p.instanceId, num(p.targetIndex) or 0, clientId) end
    elseif t == "requestDraw" then
      if self:allowedDrawOrShuffle(p.pileInstanceId, clientId) then s:drawCard(p.pileInstanceId, clientId, num(p.count) or 1) end
    elseif t == "requestShuffle" then
      if self:allowedDrawOrShuffle(p.pileRootInstanceId, clientId) then s:shufflePile(p.pileRootInstanceId, clientId) end
    elseif t == "requestDrawFromZone" then
      s:drawFromZone(p.zoneId, self:zoneOwnerId(p.zoneId, clientId), clientId, num(p.count) or 1)
    elseif t == "requestReturnToZone" then
      if self:allowedCard(p.instanceId, clientId) and self:allowedDeckWidgetZone(p.zoneId, clientId) then
        s:returnToZone(p.instanceId, p.zoneId, self:zoneOwnerId(p.zoneId, clientId), p.toBottom == true, clientId)
      end
    elseif t == "requestShuffleZone" then
      s:shuffleZone(p.zoneId, self:zoneOwnerId(p.zoneId, clientId), clientId)
    elseif t == "requestStartSearchZone" then
      if self:allowedDeckWidgetZone(p.zoneId, clientId) then s:startSearchZone(p.zoneId, self:zoneOwnerId(p.zoneId, clientId), clientId) end
    elseif t == "requestStartSearchPile" then
      if self:allowedDrawOrShuffle(p.pileRootInstanceId, clientId) then s:startSearchPile(p.pileRootInstanceId, clientId) end
    elseif t == "requestStopSearch" then
      s:stopSearch(clientId)
    elseif t == "requestCreateWidget" then
      if models.BoardWidgetKind[p.kind] then s:createWidget(p.instanceId, p.kind, num(p.x), num(p.y), clientId, p.imagePath) end
    elseif t == "requestCreateArrow" then
      s:createArrow(p.instanceId, num(p.x), num(p.y), num(p.x2), num(p.y2), clientId)
    elseif t == "requestMoveWidget" then
      if self:movableWidget(p.instanceId, clientId) then s:moveWidget(p.instanceId, num(p.x), num(p.y)) end
    elseif t == "requestSetWidgetValue" then
      if self:allowedWidget(p.instanceId, clientId) then s:setWidgetValue(p.instanceId, num(p.value) or 0, clientId) end
    elseif t == "requestDeleteWidget" then
      if self:allowedDelete(p.instanceId, clientId) then s:deleteWidget(p.instanceId) end
    elseif t == "requestSetWidgetColors" then
      if self:allowedWidget(p.instanceId, clientId) then s:setWidgetColors(p.instanceId, num(p.backgroundColor), num(p.textColor)) end
    elseif t == "requestDuplicateWidget" then
      if self:movableWidget(p.sourceInstanceId, clientId) then s:duplicateWidget(p.sourceInstanceId, p.newInstanceId, num(p.x), num(p.y)) end
    elseif t == "requestAttachWidgetToCard" then
      if self:movableWidget(p.instanceId, clientId) then s:attachWidgetToCard(p.instanceId, p.cardId, num(p.x), num(p.y), clientId) end
    elseif t == "requestDrawBagToken" then
      if self:allowedWidget(p.instanceId, clientId) then s:drawBagToken(p.instanceId, clientId) end
    elseif t == "requestReturnBagToken" then
      if self:allowedWidget(p.instanceId, clientId) then s:returnBagToken(p.instanceId, p.slotId, clientId) end
    elseif t == "requestPlaceBagTokenOnTable" then
      if self:allowedWidget(p.instanceId, clientId) then
        s:placeBagTokenOnTable(p.instanceId, p.slotId, p.newInstanceId, num(p.x), num(p.y), clientId)
      end
    elseif t == "requestResetBag" then
      if self:allowedWidget(p.instanceId, clientId) then s:resetBag(p.instanceId, clientId) end
    elseif t == "requestReturnImageTokenToBag" then
      if self:movableWidget(p.tokenInstanceId, clientId) and self:allowedWidget(p.bagInstanceId, clientId) then
        s:returnImageTokenToBag(p.bagInstanceId, p.tokenInstanceId, clientId)
      end
    elseif t == "requestGeneratePack" then
      s:generatePack(p.setId, clientId)
    elseif t == "requestCreateCardFromLibrary" then
      s:createCardFromLibrary(p.definitionId, num(p.x), num(p.y), clientId)
    elseif t == "requestLoadDeckIntoZone" then
      s:loadDeckIntoZone(p.zoneId, models.DeckConfig.fromJson(p.deck), clientId)
    elseif t == "requestLoadScenario" then
      if clientId == self.hostPlayerId then s:loadScenario(p.scenarioId, clientId) end
    elseif t == "cardDragPreview" then
      local ids = p.instanceIds or {}
      if #ids > 0 and self:allowedCard(ids[1], clientId) then
        local allowed = { ids[1] }
        for i = 2, #ids do
          if self:allowedCard(ids[i], clientId) then allowed[#allowed + 1] = ids[i] end
        end
        self:publishCardDragPreview(clientId, allowed, num(p.fx), num(p.fy))
      end
    elseif t == "cardDragPreviewEnd" then
      self:clearCardDragPreview(clientId)
    elseif t == "arrowDragPreview" then
      self:publishArrowDragPreview(clientId, num(p.fx), num(p.fy), num(p.fx2), num(p.fy2))
    elseif t == "arrowDragPreviewEnd" then
      self:clearArrowDragPreview(clientId)
    end
  end)
  if not ok then print("host: ignored bad " .. tostring(t) .. " from " .. clientId .. ": " .. tostring(err)) end
end

---------------------------------------------------------------------------
-- Drag previews (DragPreviewSink)
---------------------------------------------------------------------------

function E:exceptFor(playerId) return playerId ~= self.hostPlayerId and playerId or nil end

function E:publishCardDragPreview(playerId, ids, fx, fy)
  if not fx or not fy then return end
  self.session.cardDragPreviews[playerId] = { playerId = playerId, instanceIds = ids, fx = fx, fy = fy }
  self.server:broadcast("cardDragPreview", json.object({ "playerId", playerId, "instanceIds", json.array(ids), "fx", fx, "fy", fy }),
    self:exceptFor(playerId))
end

function E:clearCardDragPreview(playerId)
  if not self.session.cardDragPreviews[playerId] then return end
  self.session.cardDragPreviews[playerId] = nil
  self.server:broadcast("cardDragPreviewEnd", json.object({ "playerId", playerId }), self:exceptFor(playerId))
end

function E:publishArrowDragPreview(playerId, fx, fy, fx2, fy2)
  if not (fx and fy and fx2 and fy2) then return end
  self.session.arrowDragPreviews[playerId] = { playerId = playerId, fx = fx, fy = fy, fx2 = fx2, fy2 = fy2 }
  self.server:broadcast("arrowDragPreview", json.object({ "playerId", playerId, "fx", fx, "fy", fy, "fx2", fx2, "fy2", fy2 }),
    self:exceptFor(playerId))
end

function E:clearArrowDragPreview(playerId)
  if not self.session.arrowDragPreviews[playerId] then return end
  self.session.arrowDragPreviews[playerId] = nil
  self.server:broadcast("arrowDragPreviewEnd", json.object({ "playerId", playerId }), self:exceptFor(playerId))
end

return E
