-- The game table (port of lib/ui/table_screen.dart): input, drag & drop,
-- hotkeys, context menus, dialogs and in-game overlays. Layout and drawing
-- live in table_view.lua; this module owns state and behavior.
--
-- opts: session, controller, game, isMirrored, localAvatarPath,
--       avatarKeys {playerId -> image cache key}, leaveButtonLabel,
--       leaveConfirmationMessage, onLeaveGame(), onSaveGame() (or nil),
--       onKickPlayer(playerId) (or nil)
-- Server games (src/ui/screens/server/) also pass:
--       deckStore (src/data/deck_store.lua) for Load Deck / Save Deck,
--       collectionMode (hides the Pack Generator; Card Library stays
--       available so a game can still pull cards from it mid-session),
--       spectator (watch only: no drags, menus or card hotkeys),
--       sc (src/net/server_client.lua) for the in-game chat panel (C key);
--       LAN host/join and practice games don't pass it, so chat stays off
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local colorpicker = require("src.ui.kit.colorpicker")
local filterBar = require("src.ui.kit.card_filter_bar")
local models = require("src.core.models")
local util = require("src.core.util")
local uuid = require("src.core.uuid")
local stacks = require("src.core.stack_utils")
local seats = require("src.core.seat_utils")
local geometry = require("src.core.geometry")
local dwz = require("src.core.deck_widget_zones")
local fs = require("src.data.fs")
local saves = require("src.data.save_files")
local imageCache = require("src.data.image_cache")
local sound = require("src.game.sound")
local color = require("src.core.color")
local tableSettings = require("src.data.table_settings")
local CR = require("src.ui.table.card_render")
local V = require("src.ui.table.table_view")
local selection = require("src.ui.table.selection")
local json = require("lib.json")

local T = {}
T.__index = T

local CW, CH = CR.cardWidth, CR.cardHeight
local STACK_HIT_RADIUS = CW * 0.6
local DRAG_THRESHOLD = 4
local PREVIEW_THROTTLE = 0.05
local PAN_SPEED = 600
local MIN_ZOOM, MAX_ZOOM = 0.5, 2.5
local COLOR_TOKEN_WIDGET = { kind = "token", backgroundColor = models.defaultBoardWidgetBackgroundColor }

function T.new(opts)
  local self = setmetatable({}, T)
  for k, v in pairs(opts) do self[k] = v end
  self.light = theme.light
  self.forceLightTheme = true
  self.zoom, self.camX, self.camY = 1, 0, 0
  self.rotAnim, self.wiggle = {}, {}
  self.items, self.prevItems, self.dropZones, self.bagDropZones = {}, {}, {}, {}
  self.handCardCenters = {}
  self.bordersHidden = false
  self.colorTintEnabled = true
  self.tabDown, self.spaceDown, self.altDown = false, false, false
  self.gameMenuOpen, self.logOpen, self.logAnim, self.libraryOpen = false, false, 0, false
  self.tokenPickerOpen = false
  self.rulebookOpen = false
  self.chatOpen, self.chatAnim, self.chatText, self.seenChat = false, 0, "", 0
  self.rulebook = require("src.ui.screens.rulebook_viewer").new(self.game)
  self.lastPreviewAt = 0
  self.playmats, self.playmatIndex = {}, 0
  self.perPlayerPlaymats = false
  self:loadPlaymats()
  self.tokenImages = {}
  self:loadTokenImages()
  self.library = filterBar.newState(self.game)
  self.libraryScenario = false
  -- Box selection: selected card instance ids (whole piles) and token ids.
  -- selRoots/selCount are rebuilt each frame by refreshSelection().
  self.selection = { cards = {}, tokens = {} }
  self.selRoots, self.selCount = {}, 0
  return self
end

---------------------------------------------------------------------------
-- Derived state (recomputed each frame from the session)
---------------------------------------------------------------------------

function T:derive()
  local session = self.session
  local state = session.state
  self.state = state
  local acting = session:actingPlayerId()
  local D = { ownedZones = {}, sharedZones = {}, handCount = {}, zoneCards = {}, widgetFor = {},
    cardsByZoneId = {}, cardsById = {}, pileSearched = {} }
  for _, z in ipairs(session:effectiveZones()) do
    if z.shared then D.sharedZones[#D.sharedZones + 1] = z else D.ownedZones[#D.ownedZones + 1] = z end
  end
  local tableCards, hand = {}, {}
  for _, c in ipairs(state.cards) do
    D.cardsById[c.instanceId] = c
    if c.zone == "hand" then
      D.handCount[c.ownerId or ""] = (D.handCount[c.ownerId or ""] or 0) + 1
      if c.ownerId == acting then hand[#hand + 1] = c end
    elseif c.zone == "zone" then
      local key = c.ownerId or "__shared"
      D.zoneCards[key] = D.zoneCards[key] or {}
      D.zoneCards[key][c.zoneId] = D.zoneCards[key][c.zoneId] or {}
      table.insert(D.zoneCards[key][c.zoneId], c)
      D.cardsByZoneId[c.zoneId] = D.cardsByZoneId[c.zoneId] or {}
      table.insert(D.cardsByZoneId[c.zoneId], c)
    else
      tableCards[#tableCards + 1] = c
    end
  end
  D.localHand = require("src.core.table_actions").sortedByZ(hand)
  for _, w in ipairs(state.widgets) do
    if w.zoneId then
      local key = w.ownerId or "__shared"
      D.widgetFor[key] = D.widgetFor[key] or {}
      D.widgetFor[key][w.zoneId] = w
    end
  end
  local groups, order = stacks.groupByStack(tableCards)
  D.pileGroups = groups
  D.tops = {}
  local roots = {}
  for _, root in ipairs(order) do
    roots[#roots + 1] = root
    D.tops[#D.tops + 1] = stacks.topOf(groups[root])
  end
  local topZ = {}
  for _, root in ipairs(roots) do topZ[root] = stacks.topOf(groups[root]).zIndex end
  table.sort(roots, function(a, b)
    if topZ[a] ~= topZ[b] then return topZ[a] < topZ[b] end
    return a < b
  end)
  D.sortedRoots = roots
  D.pickupCandidates = util.filter(D.tops, function(c) return c.ownerId == nil or c.ownerId == acting end)
  for _, s in ipairs(state.searches) do
    if s.targetType == "pile" then D.pileSearched[s.targetId] = true end
  end
  D.rows = seats.computeHandRowLayout(state.players, session.localPlayerId)
  self.derived = D
end

function T:isZoneSearched(zoneId, ownerId)
  for _, s in ipairs(self.state.searches) do
    if s.targetType == "zone" and s.targetId == zoneId and s.targetOwnerId == ownerId then return true end
  end
  return false
end

function T:cardFacesAwayFromMe(ownerId)
  if ownerId == nil or self.game.sameOrientationForAll then return false end
  local players = self.state.players
  local n = #players
  local ownerSeat, mySeat
  for i, p in ipairs(players) do
    if p.id == ownerId then ownerSeat = i - 1 end
    if p.id == self.session.localPlayerId then mySeat = i - 1 end
  end
  if not ownerSeat or not mySeat then return ownerId ~= self.session.localPlayerId end
  return seats.isFarMirrorSeat(ownerSeat, n) ~= seats.isFarMirrorSeat(mySeat, n)
end

-- An unowned card always goes to a shared discard pile (never a specific
-- player's personal one); an owned card prefers that player's own discard
-- zone, falling back to a shared one if they don't have a personal pile.
function T:localDiscardZoneId(cardOwnerId)
  local sharedId
  for _, z in ipairs(self.session:effectiveZones()) do
    if z.isDiscardPile then
      if z.shared then
        sharedId = sharedId or z.id
      elseif cardOwnerId ~= nil then
        return z.id
      end
    end
  end
  return sharedId
end

-- Nil-safe zone lookup over the session's effective zones (game.zones plus
-- any zones loaded from a scenario).
function T:zoneById(zoneId)
  for _, z in ipairs(self.session:effectiveZones()) do
    if z.id == zoneId then return z end
  end
  return nil
end

function T:isSharedZone(zoneId)
  local z = self:zoneById(zoneId)
  return z ~= nil and z.shared
end

---------------------------------------------------------------------------
-- Selection (box select; geometry helpers in selection.lua)
---------------------------------------------------------------------------

function T:selectionColor() return { color.toRgba(tableSettings.selectionColor()) } end
function T:feltColor() return { color.toRgba(tableSettings.feltColor(self.game and self.game.tableColor)) } end
function T:playmatBorderColor()
  return { color.toRgba(tableSettings.playmatBorderColor(self.game and self.game.playmatBorderColor)) }
end

function T:selectionTint()
  local c = self:selectionColor()
  return { c[1], c[2], c[3], 0.35 }
end

function T:isRootSelected(rootId) return self.selRoots[rootId] == true end
function T:isTokenSelected(id) return self.selection.tokens[id] == true end

function T:clearSelection()
  self.selection = { cards = {}, tokens = {} }
  self.selRoots, self.selCount = {}, 0
end

-- A token that can be selected: yours and loose on the table.
function T:isSelectableToken(w)
  return w ~= nil and (w.kind == "token" or w.kind == "imageToken") and w.zoneId == nil and w.attachedCardId == nil
    and w.ownerId == self.session:actingPlayerId()
end

-- Drops whatever left the table or changed hands, then works out which
-- table piles are selected (a pile counts when any of its cards is selected
-- and its top card is yours).
function T:refreshSelection()
  local sel, D = self.selection, self.derived
  local acting = self.session:actingPlayerId()
  for id in pairs(sel.cards) do
    local c = D.cardsById[id]
    if not c or c.zone ~= "table" or (c.ownerId ~= nil and c.ownerId ~= acting) then sel.cards[id] = nil end
  end
  for id in pairs(sel.tokens) do
    if not self:isSelectableToken(models.TableState.widgetById(self.state, id)) then sel.tokens[id] = nil end
  end
  local roots, n = {}, 0
  for rootId, cards in pairs(D.pileGroups) do
    local topOwner = stacks.topOf(cards).ownerId
    if topOwner == nil or topOwner == acting then
      for _, c in ipairs(cards) do
        if sel.cards[c.instanceId] then
          roots[rootId], n = true, n + 1
          break
        end
      end
    end
  end
  for _ in pairs(sel.tokens) do n = n + 1 end
  self.selRoots, self.selCount = roots, n
end

-- Selected pile roots, bottom-most first.
function T:selectedRootList()
  local out = {}
  for _, rootId in ipairs(self.derived.sortedRoots) do
    if self.selRoots[rootId] then out[#out + 1] = rootId end
  end
  return out
end

-- Every card of the selected piles (opponents' cards left out), by zIndex.
function T:selectedCards()
  local acting = self.session:actingPlayerId()
  local out = {}
  for _, rootId in ipairs(self:selectedRootList()) do
    for _, c in ipairs(self.derived.pileGroups[rootId]) do
      if c.ownerId == nil or c.ownerId == acting then out[#out + 1] = c end
    end
  end
  return require("src.core.table_actions").sortedByZ(out)
end

function T:selectedTokenIds()
  local out = {}
  for _, w in ipairs(self.state.widgets) do
    if self.selection.tokens[w.instanceId] then out[#out + 1] = w.instanceId end
  end
  return out
end

-- Ctrl+click: a whole pile (or a token) in or out of the selection.
function T:toggleSelected(item)
  local sel = self.selection
  if item.kind == "token" then
    local id = item.widget.instanceId
    sel.tokens[id] = (not sel.tokens[id]) or nil
  else
    local on = not self.selRoots[item.rootId]
    for _, c in ipairs(self.derived.pileGroups[item.rootId] or {}) do sel.cards[c.instanceId] = on or nil end
  end
  self:refreshSelection()
end

-- Mouse released after dragging out a box from empty table.
function T:finishBoxSelect(b)
  if not b.additive then self:clearSelection() end
  local x1, y1 = V.worldToScreen(self, b.sx, b.sy)
  local x2, y2 = V.worldToScreen(self, b.cx or b.sx, b.cy or b.sy)
  if math.abs(x2 - x1) <= DRAG_THRESHOLD and math.abs(y2 - y1) <= DRAG_THRESHOLD then return end
  local rect = selection.rectFromPoints(x1, y1, x2, y2)
  local acting = self.session:actingPlayerId()
  local sel = self.selection
  for _, it in ipairs(self.prevItems) do
    if (it.kind == "tableCard" or it.kind == "pile") and (it.card.ownerId == nil or it.card.ownerId == acting)
      and selection.boxHits(rect, it) then
      for _, c in ipairs(self.derived.pileGroups[it.rootId] or {}) do sel.cards[c.instanceId] = true end
    elseif it.kind == "token" and self:isSelectableToken(it.widget) and selection.boxHits(rect, it) then
      sel.tokens[it.widget.instanceId] = true
    end
  end
  self:refreshSelection()
end

-- Half extents (world px) of a table card as it is currently shown.
function T:cardHalfExtents(card)
  return selection.halfExtents(CW, CH, V.cardTurns(self, card, false))
end

-- Moves table piles and loose tokens by a world-pixel delta, keeping their
-- layout. Anything that would end up (partly) off the table is pulled back
-- fully onto it instead, even if it then overlaps other cards.
function T:moveItemsBy(rootIds, tokenIds, dwx, dwy)
  local C, D = self.controller, self.derived
  local inBounds, primary, pfx, pfy = {}, nil, nil, nil
  for _, rootId in ipairs(rootIds) do
    local root, group = D.cardsById[rootId], D.pileGroups[rootId]
    if root and group then
      local wx, wy = V.canonicalToWorld(self, root.x, root.y)
      local nx, ny = wx + dwx, wy + dwy
      local cx, cy = selection.clampWorldCenter(nx, ny, self:cardHalfExtents(stacks.topOf(group)))
      if cx == nx and cy == ny then
        inBounds[#inBounds + 1] = rootId
        if not primary then
          primary = rootId
          pfx, pfy = V.worldToCanonical(self, nx, ny)
        end
      else
        C:moveStack(rootId, V.worldToCanonical(self, cx, cy))
      end
    end
  end
  -- The primary is a pile root listed among the passengers too, so its
  -- whole pile travels with it.
  if primary then C:moveGroup(primary, inBounds, pfx, pfy) end
  for _, id in ipairs(tokenIds) do
    local w = models.TableState.widgetById(self.state, id)
    if w then
      local ww, wh = V.widgetInstanceSize(self, w)
      local wx, wy = V.canonicalToWorld(self, w.x, w.y)
      C:moveWidget(id, V.worldToCanonical(self, selection.clampWorldCenter(wx + dwx, wy + dwy, ww / 2, wh / 2)))
    end
  end
end

-- Sends cards to a zone keeping their order (bottom-most first; to the
-- bottom of the zone the top-most goes first).
function T:sendCardsToZone(cards, zoneId, toBottom)
  local C = self.controller
  if toBottom then
    for i = #cards, 1, -1 do C:returnToZone(cards[i].instanceId, zoneId, true) end
  else
    for _, c in ipairs(cards) do C:returnToZone(c.instanceId, zoneId, false) end
  end
end

-- "Create Pile Here": every selected card stacked into one pile at the
-- clicked point, in their current order; selected tokens attach to it.
function T:createPileAt(mx, my)
  local cards = self:selectedCards()
  if #cards < 2 then return end
  local C = self.controller
  local bottom = cards[1]
  local fx, fy = V.screenToCanonicalClamped(self, mx, my, self:cardHalfExtents(bottom))
  C:moveCard(bottom.instanceId, fx, fy)
  for i = 2, #cards do C:stackCard(cards[i].instanceId, bottom.instanceId) end
  for _, id in ipairs(self:selectedTokenIds()) do C:attachWidgetToCard(id, cards[#cards].instanceId, fx, fy) end
end

-- Selected roots when the hovered card belongs to the selection (hotkeys
-- then act on all of it), else nil.
function T:hoveredSelectionRoots()
  local c = self:actableHoveredTableCard()
  if not c or not self.selRoots[stacks.rootIdOf(self.state.cards, c)] then return nil end
  return self:selectedRootList()
end

local function cardCountText(n) return n == 1 and "1 card" or (n .. " cards") end

-- Confirms before cards leave your ownership.
function T:confirmGive(cards, newOwnerId)
  local C = self.controller
  local what
  if #cards == 1 then
    local c = cards[1]
    local def = c.faceUp and V.def(self, c)
    what = def and ('"' .. def.cardTitle .. '"') or "this card"
  else
    what = cardCountText(#cards)
  end
  local function apply()
    for _, c in ipairs(cards) do C:giveCard(c.instanceId, newOwnerId) end
  end
  if newOwnerId then
    local p = V.playerById(self, newOwnerId)
    overlays.confirm("Give Cards", "Give " .. what .. " to " .. (p and p.name or "that player") .. "?", "Give", apply)
  else
    overlays.confirm("Remove Ownership", "Remove your ownership of " .. what .. "? Any player will be able to move "
      .. (#cards == 1 and "it" or "them") .. ".", "Remove", apply)
  end
end

---------------------------------------------------------------------------
-- Playmats (<gameFolder>/_playmats, cycled with F12)
---------------------------------------------------------------------------

function T:loadPlaymats()
  local folder = self.game.folderPath
  if not folder then return end
  local dir = fs.join(folder, "_playmats")
  local list = {}
  for _, e in ipairs(fs.list(dir) or {}) do
    local ext = fs.extension(e.name)
    if not e.isDir and (ext == ".png" or ext == ".jpg" or ext == ".jpeg" or ext == ".webp") then
      list[#list + 1] = fs.join(dir, e.name)
    end
  end
  util.shuffle(list)
  self.playmats = list
end

---------------------------------------------------------------------------
-- Token images (<gameFolder>/tokens, picked from the "Tokens" board menu)
---------------------------------------------------------------------------

function T:loadTokenImages()
  local folder = self.game.folderPath
  if not folder then return end
  local dir = fs.join(folder, "tokens")
  local list = {}
  for _, e in ipairs(fs.list(dir) or {}) do
    local ext = fs.extension(e.name)
    if not e.isDir and (ext == ".png" or ext == ".jpg" or ext == ".jpeg" or ext == ".webp") then
      list[#list + 1] = { name = fs.stripExtension(e.name), file = e.name, path = fs.join(dir, e.name) }
    end
  end
  table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
  self.tokenImages = list
end

function T:cyclePlaymat()
  if #self.playmats == 0 then return end
  self.playmatIndex = self.playmatIndex + 1
  if self.playmatIndex > #self.playmats then self.playmatIndex = 0 end
end

function T:togglePerPlayerPlaymats()
  self.perPlayerPlaymats = not self.perPlayerPlaymats
end

---------------------------------------------------------------------------
-- Hovered-card actions (hotkeys)
---------------------------------------------------------------------------

function T:hoveredCard()
  return self.hoveredId and self.derived.cardsById[self.hoveredId] or nil
end

-- The hovered table card, if it's mine or unowned (anyone's to act on),
-- else nil.
function T:actableHoveredTableCard()
  local c = self:hoveredCard()
  if not c or c.zone ~= "table" then return nil end
  local acting = self.session:actingPlayerId()
  if c.ownerId ~= nil and c.ownerId ~= acting then return nil end
  return c
end

function T:rotateHovered(clockwise)
  local roots = self:hoveredSelectionRoots()
  if roots then
    for _, rootId in ipairs(roots) do self.controller:rotateStack(rootId, clockwise) end
    sound.play(clockwise and "tap" or "untap")
    return
  end
  local c = self:actableHoveredTableCard()
  if not c then return end
  self.controller:rotateStack(stacks.rootIdOf(self.state.cards, c), clockwise)
  sound.play(clockwise and "tap" or "untap")
end

function T:bringHoveredToFront()
  local roots = self:hoveredSelectionRoots()
  if roots then
    for _, rootId in ipairs(roots) do self.controller:bringToFront(rootId) end
    return
  end
  local c = self:actableHoveredTableCard()
  if not c then return end
  self.controller:bringToFront(stacks.rootIdOf(self.state.cards, c))
end

function T:flipHovered()
  local roots = self:hoveredSelectionRoots()
  if roots then
    for _, rootId in ipairs(roots) do self.controller:flipCard(stacks.topOf(self.derived.pileGroups[rootId]).instanceId) end
    return
  end
  local c = self:hoveredCard()
  if not c then return end
  local acting = self.session:actingPlayerId()
  if c.ownerId ~= nil and c.ownerId ~= acting then return end
  if c.zone == "zone" and not self:isSharedZone(c.zoneId) then return end
  self.controller:flipCard(c.instanceId)
end

function T:discardHovered()
  local c = self:actableHoveredTableCard()
  if not c then return end
  local zoneId = self:localDiscardZoneId(c.ownerId)
  if not zoneId then return end
  if self:hoveredSelectionRoots() then
    for _, sc in ipairs(self:selectedCards()) do
      if sc.instanceId == c.instanceId then
        self:startDiscardFlight(sc, zoneId)
      else
        self.controller:returnToZone(sc.instanceId, zoneId, false)
      end
    end
    self.hoveredId = nil
    return
  end
  self:startDiscardFlight(c, zoneId)
  self.hoveredId = nil
end

function T:startDiscardFlight(card, zoneId)
  local target
  for _, z in ipairs(self.dropZones) do
    if z.zoneId == zoneId then target = z end
  end
  if target then
    local fx, fy = V.toScreen(self, card.x, card.y)
    self.flight = { instanceId = card.instanceId, fromX = fx, fromY = fy, toX = target.x + target.w / 2,
      toY = target.y + target.h / 2, faceUp = card.faceUp, def = V.def(self, card), t0 = love.timer.getTime() }
  end
  self.controller:returnToZone(card.instanceId, zoneId, false)
end

function T:drawNFromHovered(n)
  local c = self:hoveredCard()
  if not c then return end
  local acting = self.session:actingPlayerId()
  if c.zone == "table" then
    if c.ownerId ~= acting then return end
    sound.play("draw")
    if n == 1 then
      self.controller:moveToHand(c.instanceId)
    else
      self.controller:drawCard(stacks.rootIdOf(self.state.cards, c), n)
    end
  elseif c.zone == "zone" then
    if c.ownerId ~= nil and c.ownerId ~= acting then return end
    sound.play("draw")
    self.controller:drawFromZone(c.zoneId, n)
  end
end

function T:shuffleZone(zoneId, wiggleKey)
  self.controller:shuffleZone(zoneId)
  sound.play("shuffle")
  if wiggleKey then self.wiggle[wiggleKey] = love.timer.getTime() end
end

function T:shufflePile(rootId)
  self.controller:shufflePile(rootId)
  sound.play("shuffle")
  self.wiggle["pile:" .. rootId] = love.timer.getTime()
end

---------------------------------------------------------------------------
-- Keyboard
---------------------------------------------------------------------------

local DRAW_KEYS = {}
for i = 1, 9 do
  DRAW_KEYS[tostring(i)] = i
  DRAW_KEYS["kp" .. i] = i
end

function T:releaseHeldKeys()
  self.spaceDown, self.tabDown = false, false
  self.boxSelect = nil
  if self.arrowDrag then self.controller:endArrowDragPreview() end
  self.arrowDrag = nil
end

function T:toggleGameMenu()
  self.gameMenuOpen = not self.gameMenuOpen
  if self.gameMenuOpen then
    self.logOpen = false
    self:releaseHeldKeys()
  end
end

function T:toggleLog()
  self.logOpen = not self.logOpen
  if self.logOpen then
    self:releaseHeldKeys()
    self.logScrollToEnd = true
  end
end

function T:toggleRulebook()
  self.rulebookOpen = not self.rulebookOpen
  self.rulebook:toggle()
end

local function ctrlDown() return love.keyboard.isDown("lctrl", "rctrl") end

function T:keypressed(key, _, isrepeat)
  if key == "escape" then
    if isrepeat then return end
    -- A selection (or a box being dragged) is cleared before Esc opens the menu.
    if not self.gameMenuOpen and (self.boxSelect or self.selCount > 0) then
      self.boxSelect = nil
      self:clearSelection()
      return
    end
    self:toggleGameMenu()
    return
  end
  if self.gameMenuOpen then return end
  if self.rulebookOpen then
    if key == "r" and ctrlDown() and not isrepeat then self:toggleRulebook() end
    return
  end
  if isrepeat then return end
  if self.spectator then
    if key == "home" or key == "h" then self.camX, self.camY, self.zoom = 0, 0, 1
    elseif key == "f1" then self.bordersHidden = not self.bordersHidden
    elseif key == "f2" then self.colorTintEnabled = not self.colorTintEnabled
    elseif key == "f6" then self:togglePerPlayerPlaymats()
    elseif key == "f12" then self:cyclePlaymat()
    elseif key == "l" then self:toggleLog()
    elseif key == "r" and ctrlDown() then self:toggleRulebook()
    elseif key == "c" and self.sc then self:toggleChat() end
    return
  end
  if key == "q" then self:rotateHovered(false)
  elseif key == "e" then self:rotateHovered(true)
  elseif key == "x" then self:discardHovered()
  elseif key == "f" then self:flipHovered()
  elseif key == "z" then self:bringHoveredToFront()
  elseif key == "home" or key == "h" then
    self.camX, self.camY, self.zoom = 0, 0, 1
  elseif key == "f1" then self.bordersHidden = not self.bordersHidden
  elseif key == "f2" then self.colorTintEnabled = not self.colorTintEnabled
  elseif key == "f6" then self:togglePerPlayerPlaymats()
  elseif key == "f12" then self:cyclePlaymat()
  elseif key == "l" then self:toggleLog()
  elseif key == "r" and ctrlDown() then self:toggleRulebook()
  elseif key == "c" and self.sc then self:toggleChat()
  elseif DRAW_KEYS[key] then self:drawNFromHovered(DRAW_KEYS[key])
  end
end

function T:toggleChat()
  self.chatOpen = not self.chatOpen
end

-- Keys are only "ours" while no dialog, menu or text field has them.
function T:keysAvailable()
  return not overlays.anyOpen() and not ui.focus and not self.gameMenuOpen
    and not self.rulebookOpen
end

local CHAT_ANIM_RATE = 14
local LOG_ANIM_RATE = 14

function T:update(dt)
  self.session:update()
  local chatTarget = self.chatOpen and 1 or 0
  self.chatAnim = self.chatAnim + (chatTarget - self.chatAnim) * (1 - math.exp(-CHAT_ANIM_RATE * dt))
  local logTarget = self.logOpen and 1 or 0
  self.logAnim = self.logAnim + (logTarget - self.logAnim) * (1 - math.exp(-LOG_ANIM_RATE * dt))
  local available = self:keysAvailable()
  local tab = available and love.keyboard.isDown("tab") and not (self.drag and self.drag.started)
  if self.tabDown and not tab then
    if self.arrowDrag then self.controller:endArrowDragPreview() end
    self.arrowDrag = nil
  end
  self.tabDown = tab
  self.spaceDown = available and love.keyboard.isDown("space")
  self.altDown = love.keyboard.isDown("lalt", "ralt")
  if available and self.tableRect then
    local dx, dy = 0, 0
    if love.keyboard.isDown("a") then dx = dx + 1 end
    if love.keyboard.isDown("d") then dx = dx - 1 end
    if love.keyboard.isDown("w") then dy = dy + 1 end
    if love.keyboard.isDown("s") then dy = dy - 1 end
    if dx ~= 0 or dy ~= 0 then
      local mx, my = V.maxPan(self)
      self.camX = math.max(-mx, math.min(mx, self.camX + dx * PAN_SPEED * dt))
      self.camY = math.max(-my, math.min(my, self.camY + dy * PAN_SPEED * dt))
    end
  end
end

---------------------------------------------------------------------------
-- Geometry helpers for drops
---------------------------------------------------------------------------

local function inRect(r, x, y)
  return r and x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h
end

function T:isOverTable(x, y) return inRect(self.tableRect, x, y) end
function T:isOverLocalHand(x, y) return inRect(self.handRect, x, y) end

function T:dockedZoneIdAt(x, y)
  for _, z in ipairs(self.dropZones) do
    if inRect(z, x, y) then return z.zoneId end
  end
  return nil
end

-- Separate from dockedZoneIdAt: only Token Bag squares register here, so a
-- dragged card is never mistaken for a token being put away in a bag.
function T:bagZoneIdAt(x, y)
  for _, z in ipairs(self.bagDropZones) do
    if inRect(z, x, y) then return z.zoneId end
  end
  return nil
end

function T:handDropIndex(otherIds, x)
  local centers = {}
  for _, c in ipairs(self.handCardCenters) do centers[c.id] = c.cx end
  for i, id in ipairs(otherIds) do
    local cx = centers[id]
    if cx and x < cx then return i - 1 end
  end
  return #otherIds
end

-- Nearest table top within 42 world px, other than `excluding` (an
-- instance id, or a set of them).
function T:findStackTarget(excluding, wx, wy)
  local best, bestDist
  for _, c in ipairs(self.derived.tops) do
    local excluded = type(excluding) == "table" and excluding[c.instanceId] or c.instanceId == excluding
    if not excluded then
      local cx, cy = V.canonicalToWorld(self, c.x, c.y)
      local d = math.sqrt((cx - wx) ^ 2 + (cy - wy) ^ 2)
      if d < STACK_HIT_RADIUS and (not bestDist or d < bestDist) then best, bestDist = c, d end
    end
  end
  return best
end

-- Cards visually stacked on top of `dragged` (transitive overlap with a
-- higher zIndex), sorted by zIndex. Overlap is measured in world pixels.
function T:pickupGroup(dragged)
  local candidates = self.derived.pickupCandidates
  local pos = {}
  for _, c in ipairs(candidates) do pos[c.instanceId] = { V.canonicalToWorld(self, c.x, c.y) } end
  pos[dragged.instanceId] = pos[dragged.instanceId] or { V.canonicalToWorld(self, dragged.x, dragged.y) }
  local function overlaps(a, b)
    local pa, pb = pos[a.instanceId], pos[b.instanceId]
    return math.abs(pa[1] - pb[1]) < CW and math.abs(pa[2] - pb[2]) < CH
  end
  local result, visited, frontier = { dragged }, { [dragged.instanceId] = true }, { dragged }
  while #frontier > 0 do
    local current = table.remove(frontier)
    for _, other in ipairs(candidates) do
      if not visited[other.instanceId] and other.zIndex > current.zIndex and overlaps(current, other) then
        visited[other.instanceId] = true
        result[#result + 1] = other
        frontier[#frontier + 1] = other
      end
    end
  end
  table.sort(result, function(a, b) return a.zIndex < b.zIndex end)
  return result
end

---------------------------------------------------------------------------
-- Drops (ports of _handleDragEnd and friends)
---------------------------------------------------------------------------

-- center: the dropped card's screen center.
function T:handleCardDrop(instanceId, cx, cy)
  self.controller:endCardDragPreview()
  local origin = self.derived.cardsById[instanceId]
  local originZone = origin and origin.zone
  local alt = love.keyboard.isDown("lalt", "ralt")
  local dragged
  for _, c in ipairs(self.derived.pickupCandidates) do
    if c.instanceId == instanceId then dragged = c end
  end
  if dragged then
    local group = alt and self:pickupGroup(dragged) or { dragged }
    if #group > 1 then
      if not self:isOverTable(cx, cy) then return end
      local roots, seen = {}, {}
      for _, c in ipairs(group) do
        local rootId = stacks.rootIdOf(self.state.cards, c)
        if not seen[rootId] then
          seen[rootId] = true
          roots[#roots + 1] = rootId
        end
      end
      local ox, oy = V.canonicalToWorld(self, dragged.x, dragged.y)
      local wx, wy = V.screenToWorld(self, cx, cy)
      self:moveItemsBy(roots, {}, wx - ox, wy - oy)
      return
    end
  end
  if self:isOverLocalHand(cx, cy) then
    local others, inHand = {}, false
    for _, c in ipairs(self.derived.localHand) do
      if c.instanceId == instanceId then inHand = true else others[#others + 1] = c.instanceId end
    end
    local index = self:handDropIndex(others, cx)
    -- A card from elsewhere joins the hand at the end, then moves to the
    -- slot it was dropped on (two requests keep the wire protocol as-is).
    if not inHand then self.controller:moveToHand(instanceId) end
    self.controller:reorderHand(instanceId, index)
    return
  end
  local zoneId = self:dockedZoneIdAt(cx, cy)
  if zoneId then
    self.controller:returnToZone(instanceId, zoneId, alt)
    return
  end
  if not self:isOverTable(cx, cy) then return end
  local wx, wy = V.screenToWorld(self, cx, cy)
  local target = self:findStackTarget(instanceId, wx, wy)
  if originZone == "hand" then sound.play("playCard") end
  if target and alt then
    -- A pile with a different owner refuses it; the card stays put.
    if self.session:canStackOnto(instanceId, target.instanceId) then
      self.controller:stackCard(instanceId, target.instanceId)
    end
  else
    local hw, hh = CW / 2, CH / 2
    if origin then hw, hh = self:cardHalfExtents(origin) end
    local fx, fy = V.screenToCanonicalClamped(self, cx, cy, hw, hh)
    self.controller:moveCard(instanceId, fx, fy)
  end
end

-- Drop of a dragged selection; (cx, cy) is where the anchor item landed.
function T:handleSelectionDrop(d, cx, cy)
  if d.primaryId then self.controller:endCardDragPreview() end
  local C = self.controller
  local cards = self:selectedCards()
  local alt = love.keyboard.isDown("lalt", "ralt")
  if self:isOverLocalHand(cx, cy) then
    local others = {}
    for _, c in ipairs(self.derived.localHand) do others[#others + 1] = c.instanceId end
    local index = self:handDropIndex(others, cx)
    for i, c in ipairs(cards) do
      C:moveToHand(c.instanceId)
      C:reorderHand(c.instanceId, index + i - 1)
    end
    if #cards > 0 then sound.play("draw") end
    return
  end
  local zoneId = self:dockedZoneIdAt(cx, cy)
  if zoneId then
    self:sendCardsToZone(cards, zoneId, alt)
    return
  end
  if not self:isOverTable(cx, cy) then return end
  local wx, wy = V.screenToWorld(self, cx, cy)
  local tokenIds = self:selectedTokenIds()
  if alt then
    local target = self:findStackTarget(d.groupIds, wx, wy)
    if target then
      -- Piles never mix owners: if any card would be refused, nothing moves.
      for _, c in ipairs(cards) do
        if not self.session:canStackOnto(c.instanceId, target.instanceId) then return end
      end
      for _, c in ipairs(cards) do C:stackCard(c.instanceId, target.instanceId) end
      for _, id in ipairs(tokenIds) do C:attachWidgetToCard(id, target.instanceId, target.x, target.y) end
      return
    end
  end
  local ax, ay = self:selectionAnchorWorld(d)
  if ax then self:moveItemsBy(self:selectedRootList(), tokenIds, wx - ax, wy - ay) end
end

-- World position of the item a selection drag was started from.
function T:selectionAnchorWorld(d)
  if d.anchorTokenId then
    local w = models.TableState.widgetById(self.state, d.anchorTokenId)
    if w then return V.canonicalToWorld(self, w.x, w.y) end
    return nil
  end
  local top = d.group[1]
  if not top then return nil end
  local c = self.derived.cardsById[top.instanceId] or top
  return V.canonicalToWorld(self, c.x, c.y)
end

function T:handlePileDrop(rootId, cards, cx, cy)
  self.controller:endCardDragPreview()
  if self:isOverLocalHand(cx, cy) then
    local ordered = util.shallowCopy(cards)
    table.sort(ordered, function(a, b) return a.zIndex < b.zIndex end)
    local others = {}
    for _, c in ipairs(self.derived.localHand) do others[#others + 1] = c.instanceId end
    local index = self:handDropIndex(others, cx)
    for i, c in ipairs(ordered) do
      self.controller:moveToHand(c.instanceId)
      self.controller:reorderHand(c.instanceId, index + i - 1)
    end
    return
  end
  if not self:isOverTable(cx, cy) then return end
  local fx, fy = V.screenToCanonicalClamped(self, cx, cy, self:cardHalfExtents(stacks.topOf(cards)))
  self.controller:moveStack(rootId, fx, fy)
end

function T:handleWidgetDrop(widgetId, kind, cx, cy)
  if not self:isOverTable(cx, cy) then return end
  local ww, wh = V.widgetSize(self, kind)
  local fx, fy = V.screenToCanonicalClamped(self, cx, cy, ww / 2, wh / 2)
  self.controller:moveWidget(widgetId, fx, fy)
end

-- The bag widget docked to zoneId, for the owner this drop would count as
-- (the acting player for an owned zone, anyone for a shared one) -- or nil.
function T:bagWidgetForDrop(zoneId)
  local zone = self:zoneById(zoneId)
  if not zone or zone.kind ~= "widget" or zone.widgetKind ~= "tokenBag" then return nil end
  local key = zone.shared and "__shared" or self.session:actingPlayerId()
  return self.derived.widgetFor[key] and self.derived.widgetFor[key][zoneId]
end

function T:handleTokenDrop(widgetId, kind, cx, cy)
  if kind == "imageToken" then
    local zoneId = self:bagZoneIdAt(cx, cy)
    local bag = zoneId and self:bagWidgetForDrop(zoneId)
    if bag then
      self.controller:returnImageTokenToBag(bag.instanceId, widgetId)
      return
    end
  end
  local ctrl = love.keyboard.isDown("lctrl", "rctrl")
  local wx, wy = V.screenToWorld(self, cx, cy)
  local target = self:findStackTarget(widgetId, wx, wy)
  local ww, wh = V.widgetSize(self, kind)
  local fx, fy = V.screenToCanonicalClamped(self, cx, cy, ww / 2, wh / 2)
  if ctrl then
    if not self:isOverTable(cx, cy) then return end
    local newId = uuid.v4()
    self.controller:duplicateWidget(widgetId, newId, fx, fy)
    if target then self.controller:attachWidgetToCard(newId, target.instanceId, fx, fy) end
    return
  end
  if target then
    self.controller:attachWidgetToCard(widgetId, target.instanceId, fx, fy)
  else
    self:handleWidgetDrop(widgetId, kind, cx, cy)
  end
end

function T:handleLibraryDrop(definitionId, cx, cy)
  if not self:isOverTable(cx, cy) then return end
  local def = self.session.definitionsById[definitionId]
  local hw, hh = selection.halfExtents(CW, CH, def and CR.orientationTurns(def.orientation) or 0)
  local fx, fy = V.screenToCanonicalClamped(self, cx, cy, hw, hh)
  self.controller:createCardFromLibrary(definitionId, fx, fy)
end

function T:handleImageTokenDrop(imageFile, cx, cy)
  if not self:isOverTable(cx, cy) then return end
  local ww, wh = V.widgetSize(self, "imageToken")
  local fx, fy = V.screenToCanonicalClamped(self, cx, cy, ww / 2, wh / 2)
  self.controller:createWidget(uuid.v4(), "imageToken", fx, fy, imageFile)
end

-- A short press (not a drag) returns the token to the bag instead; dropped
-- off-table it's left alone -- a tiny accidental drag must never destroy a
-- non-returnable token.
function T:handleRevealedBagTokenDrop(bagInstanceId, slotId, imagePath, cx, cy)
  if not self:isOverTable(cx, cy) then return end
  local hw, hh = V.nativeImageSize(self, imagePath)
  local fx, fy = V.screenToCanonicalClamped(self, cx, cy, hw / 2, hh / 2)
  self.controller:placeBagTokenOnTable(bagInstanceId, slotId, uuid.v4(), fx, fy)
end

function T:handleNewTokenDrop(cx, cy)
  if not self:isOverTable(cx, cy) then return end
  local ww, wh = V.widgetSize(self, "token")
  local fx, fy = V.screenToCanonicalClamped(self, cx, cy, ww / 2, wh / 2)
  self.controller:createWidget(uuid.v4(), "token", fx, fy)
end

---------------------------------------------------------------------------
-- Drag lifecycle
---------------------------------------------------------------------------

-- A press on a draggable source records a pending drag; it starts once the
-- mouse moves past the threshold. src: { kind, card, ..., cx, cy, scale }
function T:pressSource(src, mx, my)
  if self.spectator then return end
  self.pending = { src = src, pressX = mx, pressY = my }
end

function T:sendCardPreview(force)
  local d = self.drag
  if not d or not d.primaryId then return end
  local now = love.timer.getTime()
  if not force and now - self.lastPreviewAt < PREVIEW_THROTTLE then return end
  self.lastPreviewAt = now
  local mx, my = ui.mouse()
  local fx, fy = V.screenToCanonical(self, mx, my)
  local passengers = {}
  for i = 2, #d.group do passengers[#passengers + 1] = d.group[i].instanceId end
  self.controller:previewCardDrag(d.primaryId, passengers, fx, fy)
end

function T:startDrag()
  local p = self.pending
  self.pending = nil
  local src = p.src
  local d = { started = true, src = src, kind = src.kind, grabX = src.cx - p.pressX, grabY = src.cy - p.pressY,
    scale = src.scale or 1 }
  d.grabX0, d.grabY0, d.scale0 = d.grabX, d.grabY, d.scale
  if src.kind == "selection" then
    -- group: the top card of each selected pile, the anchor's first;
    -- groupIds: every card of those piles (ghosted while dragged).
    d.anchorRootId, d.anchorTokenId = src.anchorRootId, src.anchorTokenId
    d.group, d.groupIds, d.tokenIds = {}, {}, {}
    for _, rootId in ipairs(self:selectedRootList()) do
      local cards = self.derived.pileGroups[rootId]
      local top = stacks.topOf(cards)
      if rootId == src.anchorRootId then table.insert(d.group, 1, top) else d.group[#d.group + 1] = top end
      for _, c in ipairs(cards) do d.groupIds[c.instanceId] = true end
    end
    d.drawOrder = require("src.core.table_actions").sortedByZ(d.group)
    for _, id in ipairs(self:selectedTokenIds()) do d.tokenIds[id] = true end
    d.primaryId = d.group[1] and d.group[1].instanceId
    self.drag = d
    if d.primaryId then self:sendCardPreview(true) end
    return
  end
  if src.kind == "card" or src.kind == "pile" then
    local card = src.card
    d.primaryId = card.instanceId
    d.group = { card }
    if src.allowGroup and self.altDown then d.group = self:pickupGroup(card) end
    if #d.group > 1 then
      d.groupIds = {}
      for _, c in ipairs(d.group) do d.groupIds[c.instanceId] = true end
    end
    d.angle = src.angle or 0
    self.drag = d
    self:sendCardPreview(true)
    return
  end
  if src.kind == "widget" or src.kind == "token" then d.widgetId = src.widget.instanceId end
  if src.kind == "revealedBagToken" then d.widgetId, d.slotId = src.widget.instanceId, src.slotId end
  self.drag = d
end

local GHOST_SCALE_RATE = 18 -- drag ghost resize easing speed (1/s)

-- A single dragged card eases to the size it would have where it is held:
-- hand size over the hand, table zoom over the table, base size elsewhere.
-- The grab offset scales with it so the pointer keeps its spot on the card.
function T:updateDragScale()
  local d = self.drag
  if not (d.kind == "card" or d.kind == "pile") or #d.group > 1 then return end
  local mx, my = ui.mouse()
  local cx, cy = mx + d.grabX, my + d.grabY
  local target = 1
  if self:isOverLocalHand(cx, cy) then
    target = V.handScale()
  elseif self:isOverTable(cx, cy) then
    target = self.zoom
  end
  local k = 1 - math.exp(-GHOST_SCALE_RATE * love.timer.getDelta())
  d.scale = d.scale + (target - d.scale) * k
  local f = d.scale / d.scale0
  d.grabX, d.grabY = d.grabX0 * f, d.grabY0 * f
end

function T:endDrag()
  local d = self.drag
  self.drag = nil
  if not d then return end
  local mx, my = ui.mouse()
  local cx, cy = mx + d.grabX, my + d.grabY
  local src = d.src
  if d.kind == "card" then
    self:handleCardDrop(d.primaryId, cx, cy)
  elseif d.kind == "pile" then
    if love.keyboard.isDown("lalt", "ralt") then
      self:handlePileDrop(src.rootId, src.cards, cx, cy)
    else
      self:handleCardDrop(d.primaryId, cx, cy)
    end
  elseif d.kind == "widget" then
    self:handleWidgetDrop(src.widget.instanceId, src.widget.kind, cx, cy)
  elseif d.kind == "token" then
    self:handleTokenDrop(src.widget.instanceId, src.widget.kind, cx, cy)
  elseif d.kind == "library" then
    self:handleLibraryDrop(src.definitionId, cx, cy)
  elseif d.kind == "imageToken" then
    self:handleImageTokenDrop(src.imageFile, cx, cy)
  elseif d.kind == "newToken" then
    self:handleNewTokenDrop(cx, cy)
  elseif d.kind == "revealedBagToken" then
    self:handleRevealedBagTokenDrop(src.widget.instanceId, src.slotId, src.imagePath, cx, cy)
  elseif d.kind == "selection" then
    self:handleSelectionDrop(d, cx, cy)
  end
end

-- Draws whatever is being dragged under the pointer.
function T:drawDragFeedback()
  local d = self.drag
  if not d or not d.started then return end
  self:updateDragScale()
  local mx, my = ui.mouse()
  local cx, cy = mx + d.grabX, my + d.grabY
  local s = d.scale
  if d.kind == "card" or d.kind == "pile" then
    if #d.group > 1 then
      local primary = d.group[1]
      for _, c in ipairs(d.group) do
        if c.instanceId == d.primaryId then primary = c end
      end
      local px, py = V.toScreen(self, primary.x, primary.y)
      for _, c in ipairs(d.group) do
        local x, y = V.toScreen(self, c.x, c.y)
        CR.draw({ def = V.def(self, c), faceUp = c.faceUp, cx = cx + x - px, cy = cy + y - py, scale = s, cardBacks = self.game.cardBacks, scenarioCardBackId = self.game.scenarioCardBackId })
      end
      -- Attached widgets ride along.
      for _, w in ipairs(self.state.widgets) do
        if w.attachedCardId and d.groupIds[w.attachedCardId] then
          local wx, wy = V.toScreen(self, w.x, w.y)
          self:drawWidgetFace(w, cx + wx - px, cy + wy - py, s)
        end
      end
    else
      local c = d.group[1]
      CR.draw({ def = V.def(self, c), faceUp = c.faceUp or d.src.forceFaceUp, cx = cx, cy = cy, scale = s, angle = d.angle,
        border = d.src.border, cardBacks = self.game.cardBacks, scenarioCardBackId = self.game.scenarioCardBackId })
    end
  elseif d.kind == "selection" then
    -- Everything keeps its offset from the anchor, at table size.
    local awx, awy = self:selectionAnchorWorld(d)
    if not awx then return end
    local ax, ay = V.worldToScreen(self, awx, awy)
    local z, tint = self.zoom, self:selectionTint()
    for _, c in ipairs(d.drawOrder) do
      local x, y = V.toScreen(self, c.x, c.y)
      local angle = V.cardTurns(self, c, self:cardFacesAwayFromMe(c.ownerId)) * 2 * math.pi
      CR.draw({ def = V.def(self, c), faceUp = c.faceUp, cx = cx + x - ax, cy = cy + y - ay, scale = z, angle = angle,
        tint = tint, cardBacks = self.game.cardBacks, scenarioCardBackId = self.game.scenarioCardBackId })
    end
    for _, w in ipairs(self.state.widgets) do
      if d.tokenIds[w.instanceId] or (w.attachedCardId and d.groupIds[w.attachedCardId]) then
        local wx, wy = V.toScreen(self, w.x, w.y)
        self:drawWidgetFace(w, cx + wx - ax, cy + wy - ay, z)
      end
    end
  elseif d.kind == "widget" or d.kind == "token" then
    self:drawWidgetFace(d.src.widget, cx, cy, s)
  elseif d.kind == "library" then
    CR.draw({ def = d.src.def, faceUp = true, cx = cx, cy = cy, cardBacks = self.game.cardBacks, scenarioCardBackId = self.game.scenarioCardBackId })
  elseif d.kind == "imageToken" then
    self:drawWidgetFace({ kind = "imageToken", imagePath = d.src.imageFile }, cx, cy, s)
  elseif d.kind == "newToken" then
    self:drawWidgetFace(COLOR_TOKEN_WIDGET, cx, cy, s)
  elseif d.kind == "revealedBagToken" then
    self:drawWidgetFace({ kind = "imageToken", imagePath = d.src.imagePath, sizeOverride = "native" }, cx, cy, s)
  end
end

function T:drawWidgetFace(w, cx, cy, s)
  local ww, wh = V.widgetInstanceSize(self, w)
  if w.kind == "simpleCounter" then
    V.counterFace(self, w, cx - ww * s / 2, cy - wh * s / 2, ww * s, 1)
  elseif w.kind == "token" or w.kind == "imageToken" then
    V.tokenFace(self, w, cx, cy, ww * s, 1)
  elseif w.kind == "packGenerator" then
    V.packFace(self, w, cx - ww * s / 2, cy - wh * s / 2, ww * s, 1)
  elseif w.kind == "deckBuilder" then
    love.graphics.setColor(0, 0, 0, 0.54)
    love.graphics.rectangle("fill", cx - ww * s / 2, cy - wh * s / 2, ww * s, wh * s, 8 * s, 8 * s)
  end
end

---------------------------------------------------------------------------
-- Context menus
---------------------------------------------------------------------------

function T:cardMenuItems(card, onSearch)
  local acting = self.session:actingPlayerId()
  -- An unowned card (including every unownable one, which never has an
  -- owner) is fair game for any player, same as everywhere else cards are
  -- moved/flipped/rotated (see flipHovered, Host:isOwnedOrUnowned).
  local canAct = card.ownerId == nil or card.ownerId == acting
  if not canAct and not onSearch then return nil end
  local items = {}
  local isTable = card.zone == "table"
  local C = self.controller
  if canAct then
    local function placementMenu(zone)
      local sub = { { label = "Top", onSelect = function() C:returnToZone(card.instanceId, zone.id, false) end } }
      if zone.shuffleable then
        sub[#sub + 1] = { label = "Shuffle Into", onSelect = function()
          C:returnToZone(card.instanceId, zone.id, false)
          C:shuffleZone(zone.id)
        end }
      end
      sub[#sub + 1] = { label = "Bottom", onSelect = function() C:returnToZone(card.instanceId, zone.id, true) end }
      return sub
    end
    local send = {}
    if card.zone ~= "hand" then send[#send + 1] = { label = "Hand", onSelect = function() C:moveToHand(card.instanceId) end } end
    local discardId = self:localDiscardZoneId(card.ownerId)
    local discard = discardId and self:zoneById(discardId)
    if discard then send[#send + 1] = { label = "Discard", submenu = placementMenu(discard) } end
    for _, zone in ipairs(self.session:effectiveZones()) do
      if zone.kind == "card" and not zone.isDiscardPile then
        send[#send + 1] = { label = zone.name, submenu = placementMenu(zone) }
      end
    end
    items[#items + 1] = { label = "Send to...", submenu = send }
  end
  if onSearch then items[#items + 1] = { label = "Search...", onSelect = onSearch } end
  if canAct and isTable then
    local rootId = stacks.rootIdOf(self.state.cards, card)
    items[#items + 1] = { label = "Flip", onSelect = function() C:flipCard(card.instanceId) end }
    items[#items + 1] = { label = "Rotate", submenu = self:rotateMenu({ rootId }) }
    -- Cards in a pile can't change owner (piles never mix owners).
    if not self.session:isInPile(card.instanceId) then
      for _, p in ipairs(self.state.players) do
        if p.id ~= acting and p.connected then
          items[#items + 1] = { label = "Give to " .. p.name, onSelect = function() self:confirmGive({ card }, p.id) end }
        end
      end
      items[#items + 1] = { label = "Remove Ownership", onSelect = function() self:confirmGive({ card }, nil) end }
    end
  end
  return items
end

function T:rotateMenu(rootIds)
  local function rotate(clockwise)
    return function()
      for _, rootId in ipairs(rootIds) do self.controller:rotateStack(rootId, clockwise) end
      sound.play(clockwise and "tap" or "untap")
    end
  end
  return { { label = "Clockwise", onSelect = rotate(true) }, { label = "Counterclockwise", onSelect = rotate(false) } }
end

-- Right-click on a selected pile or card while 2+ items are selected:
-- everything acts on all selected cards. (mx, my): where the menu opened.
function T:selectionMenuItems(mx, my)
  local C = self.controller
  local cards, roots = self:selectedCards(), self:selectedRootList()
  local tokenCount = #self:selectedTokenIds()
  local header = cardCountText(#cards)
  if tokenCount > 0 then header = header .. ", " .. tokenCount .. " token" .. (tokenCount == 1 and "" or "s") end
  local items = { { label = header .. " selected", disabled = true }, { divider = true } }
  if #cards == 0 then return items end
  local function placementMenu(zone)
    local sub = { { label = "Top", onSelect = function() self:sendCardsToZone(cards, zone.id, false) end } }
    if zone.shuffleable then
      sub[#sub + 1] = { label = "Shuffle Into", onSelect = function()
        self:sendCardsToZone(cards, zone.id, false)
        C:shuffleZone(zone.id)
      end }
    end
    sub[#sub + 1] = { label = "Bottom", onSelect = function() self:sendCardsToZone(cards, zone.id, true) end }
    return sub
  end
  local send = { { label = "Hand", onSelect = function()
    for _, c in ipairs(cards) do C:moveToHand(c.instanceId) end
    sound.play("draw")
  end } }
  local discardId = self:localDiscardZoneId(cards[1].ownerId)
  local discard = discardId and self:zoneById(discardId)
  if discard then send[#send + 1] = { label = "Discard", submenu = placementMenu(discard) } end
  for _, zone in ipairs(self.session:effectiveZones()) do
    if zone.kind == "card" and not zone.isDiscardPile then
      send[#send + 1] = { label = zone.name, submenu = placementMenu(zone) }
    end
  end
  items[#items + 1] = { label = "Send to...", submenu = send }
  if #cards >= 2 then
    items[#items + 1] = { label = "Create Pile Here", onSelect = function() self:createPileAt(mx, my) end }
  end
  items[#items + 1] = { label = "Flip", onSelect = function()
    for _, rootId in ipairs(roots) do C:flipCard(stacks.topOf(self.derived.pileGroups[rootId]).instanceId) end
  end }
  items[#items + 1] = { label = "Rotate", submenu = self:rotateMenu(roots) }
  local acting = self.session:actingPlayerId()
  -- Ownership changes are only offered when no selected card is in a pile.
  for _, rootId in ipairs(roots) do
    if #self.derived.pileGroups[rootId] > 1 then return items end
  end
  for _, p in ipairs(self.state.players) do
    if p.id ~= acting and p.connected then
      items[#items + 1] = { label = "Give to " .. p.name, onSelect = function() self:confirmGive(cards, p.id) end }
    end
  end
  items[#items + 1] = { label = "Remove Ownership", onSelect = function() self:confirmGive(cards, nil) end }
  return items
end

function T:openBoardMenu(mx, my)
  if self.spectator then return end
  local fx, fy = V.screenToCanonical(self, mx, my)
  local C = self.controller
  local function create(kind) return function() C:createWidget(uuid.v4(), kind, fx, fy) end end
  local widgetItems = {
    { label = "Simple Counter", onSelect = create("simpleCounter") },
  }
  -- Collection-mode games only use cards players own.
  if not self.collectionMode then
    widgetItems[#widgetItems + 1] = { label = "Pack Generator", onSelect = create("packGenerator") }
  end
  if #models.GameDefinition.deckBuildingZones(self.game) > 0 then
    widgetItems[#widgetItems + 1] = { label = "Deck Widget", onSelect = create("deckBuilder") }
  end
  local menu = { { label = "Tokens", onSelect = function() self.tokenPickerOpen = true end },
    { label = "Widgets", submenu = widgetItems },
    -- Available even in collection mode: some games still need to pull
    -- cards from the library mid-session, not just build a deck from owned ones.
    { label = "Card Library", onSelect = function() self.libraryOpen = true end } }
  overlays.menu(mx, my, menu)
end

function T:openCounterMenu(mx, my, w, includeDelete)
  local C = self.controller
  local items = {
    { label = "Increment", onSelect = function() C:setWidgetValue(w.instanceId, w.value + 1) end },
    { label = "Decrement", onSelect = function() C:setWidgetValue(w.instanceId, w.value - 1) end },
    { label = "Set Value", onSelect = function() self:promptSetValue(w) end },
    { label = "Set Colors", onSelect = function() self:promptSetColors(w) end },
  }
  if includeDelete then items[#items + 1] = { label = "Delete", onSelect = function() C:deleteWidget(w.instanceId) end } end
  overlays.menu(mx, my, items)
end

-- Right-click on an item; returns true when handled.
function T:openItemMenu(item, mx, my)
  if self.spectator then return true end
  local C = self.controller
  local k = item.kind
  if (k == "tableCard" or k == "pile") and self.selRoots[item.rootId] and self.selCount >= 2 then
    overlays.menu(mx, my, self:selectionMenuItems(mx, my))
    return true
  end
  if k == "tableCard" or k == "handCard" then
    local items = self:cardMenuItems(item.card)
    if items then overlays.menu(mx, my, items) return true end
  elseif k == "pile" then
    local search = (not item.ownedByOpponent) and function() C:startSearchPile(item.rootId) end or nil
    local items = self:cardMenuItems(item.card, search)
    if items then overlays.menu(mx, my, items) return true end
  elseif k == "zone" then
    if item.shared or item.deckWidget then
      overlays.menu(mx, my, { { label = "Search...", onSelect = function() C:startSearchZone(item.zoneId) end } })
    else
      local menu = { { label = "Search...", onSelect = function() C:startSearchZone(item.zoneId) end } }
      if item.zone.dealsBuiltDeck and #item.cards == 0 then
        menu[#menu + 1] = { label = "Load Deck...", onSelect = function() self:promptLoadDeck(item.zone) end }
      end
      overlays.menu(mx, my, menu)
    end
    return true
  elseif k == "counter" and item.interactable then
    self:openCounterMenu(mx, my, item.widget, true)
    return true
  elseif k == "dockedCounter" and item.interactable then
    self:openCounterMenu(mx, my, item.widget, false)
    return true
  elseif k == "token" and item.interactable then
    local menu = {}
    if item.widget.kind ~= "imageToken" then
      menu[#menu + 1] = { label = "Set Color", onSelect = function() self:promptSetTokenColor(item.widget) end }
    end
    menu[#menu + 1] = { label = "Delete", onSelect = function() C:deleteWidget(item.widget.instanceId) end }
    overlays.menu(mx, my, menu)
    return true
  elseif k == "packGenerator" and item.interactable then
    local menu = {}
    if not self.collectionMode then
      for _, set in ipairs(self.game.sets) do
        menu[#menu + 1] = { label = set.name, onSelect = function() C:generatePack(set.id) end }
      end
    end
    menu[#menu + 1] = { label = "Delete", onSelect = function() C:deleteWidget(item.widget.instanceId) end }
    overlays.menu(mx, my, menu)
    return true
  elseif (k == "deckBody" or k == "deckHeader") and item.widget.ownerId == self.session:actingPlayerId() and not self.tabDown then
    overlays.menu(mx, my, { { label = "Delete", onSelect = function() C:deleteWidget(item.widget.instanceId) end } })
    return true
  elseif k == "tokenBagIdle" and item.interactable then
    overlays.menu(mx, my, { { label = "Reset Bag", onSelect = function() C:resetBag(item.widget.instanceId) end } })
    return true
  elseif k == "revealedBagToken" and item.interactable then
    overlays.menu(mx, my, { { label = "Return to Bag",
      onSelect = function() C:returnBagToken(item.widget.instanceId, item.slotId) end } })
    return true
  end
  return false
end

---------------------------------------------------------------------------
-- Dialogs
---------------------------------------------------------------------------

function T:promptSetValue(w)
  local st = { text = tostring(w.value) }
  local function apply(d)
    local n = tonumber(util.trim(st.text))
    if not n or n % 1 ~= 0 then
      st.error = "Enter a whole number"
      return true
    end
    self.controller:setWidgetValue(w.instanceId, util.clamp(n, models.boardWidgetCounterMin, models.boardWidgetCounterMax))
    d:close()
    return true
  end
  overlays.dialog({
    title = "Set Value", width = 360,
    content = function(d, x, y, cw)
      local text, changed, submitted = ui.textField("setvalue", x, y + 8, cw, st.text, {
        label = "Value (0-" .. models.boardWidgetCounterMax .. ")", autofocus = true, selectAllOnFocus = true,
        error = st.error, labelBackground = theme.c.surfaceContainerHigh })
      st.text = text
      if changed then st.error = nil end
      if submitted then apply(d) end
      return 8 + ui.textFieldHeight({ error = st.error })
    end,
    actions = { { label = "Cancel", variant = "text" }, { label = "Set", variant = "filled", onClick = apply } },
  })
end

function T:promptSetColors(w)
  local st = { bg = w.backgroundColor, text = w.textColor }
  overlays.dialog({
    title = "Set Colors", width = 400,
    content = function(_, x, y, cw)
      local yy = y
      ui.text("Background", x, yy)
      yy = yy + 28
      local h
      st.bg, h = colorpicker.field("setcolors:bg", x, yy, cw, st.bg, { labelBackground = theme.c.surfaceContainerHigh })
      yy = yy + h + 16
      ui.text("Text", x, yy)
      yy = yy + 28
      st.text, h = colorpicker.field("setcolors:text", x, yy, cw, st.text, { labelBackground = theme.c.surfaceContainerHigh })
      return yy + h - y
    end,
    actions = { { label = "Cancel", variant = "text" },
      { label = "Set", variant = "filled", onClick = function() self.controller:setWidgetColors(w.instanceId, st.bg, st.text) end } },
  })
end

function T:promptSetTokenColor(w)
  local st = { color = w.backgroundColor }
  overlays.dialog({
    title = "Set Color", width = 400,
    content = function(_, x, y, cw)
      local h
      st.color, h = colorpicker.field("setcolor:token", x, y, cw, st.color, { labelBackground = theme.c.surfaceContainerHigh })
      return h
    end,
    actions = { { label = "Cancel", variant = "text" },
      { label = "Set", variant = "filled", onClick = function() self.controller:setWidgetColors(w.instanceId, st.color, w.textColor) end } },
  })
end

function T:promptLoadDeck(zone)
  require("src.ui.screens.deck_library_dialog").open(self.game, { zone }, function(deck)
    self.controller:loadDeckIntoZone(zone.id, deck)
  end, { store = self.deckStore })
end

function T:promptLoadScenario()
  local loaded = {}
  for _, id in ipairs(self.state.loadedScenarioIds) do loaded[id] = true end
  local rowH = 44
  overlays.dialog({
    title = "Load Scenario", width = 420,
    content = function(d, x, y, cw)
      local yy = y
      for _, scenario in ipairs(self.game.scenarios) do
        local isLoaded = loaded[scenario.id] == true
        local label = scenario.name .. (isLoaded and " (loaded)" or "")
        if ui.button(label, x, yy, cw, 40, { variant = "outlined", disabled = isLoaded, id = "scenario:" .. scenario.id }) then
          self.controller:loadScenario(scenario.id)
          d:close()
        end
        yy = yy + rowH
      end
      return yy - y - (rowH - 40)
    end,
    actions = { { label = "Cancel", variant = "text" } },
  })
end

function T:saveDeckWidget(w)
  local subdecks = {}
  for _, zone in ipairs(models.GameDefinition.deckBuildingZones(self.game)) do
    local syntheticId = dwz.build(w.instanceId, zone.id)
    local tally, order = {}, {}
    for _, c in ipairs(self.state.cards) do
      if c.zone == "zone" and c.zoneId == syntheticId then
        if not tally[c.definitionId] then order[#order + 1] = c.definitionId end
        tally[c.definitionId] = (tally[c.definitionId] or 0) + 1
      end
    end
    subdecks[#subdecks + 1] = models.SubDeck.new(zone.deckType, util.map(order, function(id) return models.DeckEntry.new(id, tally[id]) end))
  end
  local deck = models.DeckConfig.new(self.game.id, subdecks)
  require("src.ui.screens.deck_library_dialog").promptSaveDeck(self.game, deck, nil, { store = self.deckStore })
end

function T:saveLog()
  local folder = self.game.folderPath
  if not folder then return end
  local name = saves.logFileName()
  local path, err = saves.writeLog(folder, name, saves.formatLog(self.state.log))
  overlays.toast(path and ('Saved "' .. name .. '"') or ("Could not save the log: " .. tostring(err)))
end

---------------------------------------------------------------------------
-- Input (runs at the start of draw, against last frame's items)
---------------------------------------------------------------------------

local DRAGGABLE = { tableCard = true, pile = true, handCard = true, zone = true, counter = true, token = true,
  packGenerator = true, deckHeader = true, revealedBagToken = true }
local TABLE_KINDS = { table = true, tableCard = true, pile = true, counter = true, token = true, packGenerator = true,
  deckBody = true, deckHeader = true, deckSave = true, shuffle = true }

function T:topItemAt(mx, my)
  for i = #self.prevItems, 1, -1 do
    local it = self.prevItems[i]
    if V.hitTest(it, mx, my) then return it end
  end
  return nil
end

-- Builds a drag source from an item under the press.
function T:sourceFor(item)
  local k = item.kind
  if k == "tableCard" or k == "pile" then
    if not item.interactable then return nil end
    local c = item.card
    local cx, cy = V.toScreen(self, c.x, c.y)
    local faceAway = self:cardFacesAwayFromMe(c.ownerId)
    return { kind = k == "pile" and "pile" or "card", card = c, rootId = item.rootId, cards = item.cards,
      cx = cx, cy = cy, scale = self.zoom, allowGroup = not item.ownedByOpponent,
      angle = V.cardTurns(self, c, faceAway) * 2 * math.pi, border = V.ownerBorderColor(self, c.ownerId) }
  elseif k == "handCard" then
    local cx, cy = item.cardCx, item.cardCy
    if item.mirror then cx, cy = 2 * item.mirror.cx - cx, 2 * item.mirror.cy - cy end
    return { kind = "card", card = item.card, cx = cx, cy = cy, scale = item.scale or 1, border = V.ownerBorderColor(self, item.card.ownerId) }
  elseif k == "zone" then
    if not item.top or not item.interactable then return nil end
    return { kind = "card", card = item.top, cx = item.x + item.w / 2, cy = item.y + item.h / 2, scale = 1 }
  elseif (k == "counter" or k == "packGenerator") and item.interactable then
    return { kind = "widget", widget = item.widget, cx = item.x + item.w / 2, cy = item.y + item.h / 2, scale = self.zoom }
  elseif k == "token" and item.interactable then
    return { kind = "token", widget = item.widget, cx = item.cx, cy = item.cy, scale = self.zoom }
  elseif k == "deckHeader" then
    local wx, wy = V.toScreen(self, item.widget.x, item.widget.y)
    return { kind = "widget", widget = item.widget, cx = wx, cy = wy, scale = self.zoom }
  elseif k == "revealedBagToken" and item.interactable then
    return { kind = "revealedBagToken", widget = item.widget, slotId = item.slotId, imagePath = item.imagePath,
      cx = item.cx, cy = item.cy, scale = self.zoom }
  end
  return nil
end

-- A press on a table card, pile or token, given the selection:
-- Ctrl+click toggles it (Ctrl+drag still drags, e.g. to duplicate a token),
-- a selected item drags the whole selection, and an unselected one clears
-- the selection before acting as usual.
function T:applySelectionToPress(item, src)
  local k = item.kind
  if k ~= "tableCard" and k ~= "pile" and k ~= "token" then return src end
  local isToken = k == "token"
  local selectable
  if isToken then
    selectable = self:isSelectableToken(item.widget)
  else
    local ownerId = item.card.ownerId
    selectable = ownerId == nil or ownerId == self.session:actingPlayerId()
  end
  if selectable and love.keyboard.isDown("lctrl", "rctrl") then
    src.onClick = function() self:toggleSelected(item) end
    return src
  end
  local selected
  if isToken then selected = self:isTokenSelected(item.widget.instanceId) else selected = self.selRoots[item.rootId] end
  if selected and self.selCount >= 2 then
    return { kind = "selection", anchorRootId = (not isToken) and item.rootId or nil,
      anchorTokenId = isToken and item.widget.instanceId or nil, cx = src.cx, cy = src.cy, scale = self.zoom,
      onClick = src.onClick }
  end
  if not selected and self.selCount > 0 then self:clearSelection() end
  return src
end

function T:processInput()
  local mx, my = ui.mouse()
  local free = ui.baseHasMouse()
  local item = free and self:topItemAt(mx, my) or nil

  -- Hover (cards drive Space preview and the hotkeys).
  if not (self.drag and self.drag.started) then
    self.hoverItem = item
    if self.overlayHoverId then
      self.hoveredId, self.hoveredForceFaceUp = self.overlayHoverId, true
    else
      self.hoveredId = item and item.hoverId or nil
      self.hoveredForceFaceUp = false
    end
  end
  self.overlayHoverId = nil
  if item and item.tooltip and not self.drag then ui.tooltip("table:" .. item.kind .. ":" .. (item.zoneId or item.tooltip), item.tooltip) end
  if item and (DRAGGABLE[item.kind] or item.kind == "shuffle" or item.kind == "avatar" or item.kind == "deckSave"
    or item.kind == "tokenBagIdle") then
    if not (item.kind == "zone" and not item.top) and item.interactable ~= false then ui.setCursor("hand") end
  end

  -- Wheel zoom over the table.
  local _, wy = ui.wheel()
  if free and wy ~= 0 and self:isOverTable(mx, my) and not self.libraryOpen and not self.tokenPickerOpen then
    local old = self.zoom
    local new = util.clamp(old * math.exp(wy * 0.1), MIN_ZOOM, MAX_ZOOM)
    if new ~= old then
      local tr = self.tableRect
      local ax, ay = mx - (tr.x + tr.w / 2), my - (tr.y + tr.h / 2)
      self.zoom = new
      self.camX = self.camX + ax * (1 / new - 1 / old)
      self.camY = self.camY + ay * (1 / new - 1 / old)
    end
    ui.consumeWheel()
  end

  -- Middle-button drag pans the table (alongside WASD).
  if self.midPan then
    if ui.mouseDown(3) then
      local p = self.midPan
      local maxX, maxY = V.maxPan(self)
      self.camX = util.clamp(p.camX + (mx - p.x) / self.zoom, -maxX, maxX)
      self.camY = util.clamp(p.camY + (my - p.y) / self.zoom, -maxY, maxY)
      ui.setCursor("sizeall")
    else
      self.midPan = nil
    end
  elseif free and ui.mousePressed(3) and self:isOverTable(mx, my) and not self.libraryOpen and not self.tokenPickerOpen then
    local cx, cy = V.clampedCamera(self)
    self.midPan = { x = mx, y = my, camX = cx, camY = cy }
  end

  -- Arrow drawing (Tab + drag on the table).
  if self.arrowDrag then
    local wx, wy2 = V.screenToWorld(self, mx, my)
    self.arrowDrag.cx, self.arrowDrag.cy = wx, wy2
    local now = love.timer.getTime()
    if now - self.lastPreviewAt >= PREVIEW_THROTTLE then
      self.lastPreviewAt = now
      self:sendArrowPreview()
    end
    if ui.mouseReleased(1) then
      self.controller:endArrowDragPreview()
      local a = self.arrowDrag
      self.arrowDrag = nil
      if math.sqrt((a.cx - a.sx) ^ 2 + (a.cy - a.sy) ^ 2) >= 4 then
        local fx, fy = geometry.localPixelToCanonical(a.sx, a.sy, geometry.worldWidth, geometry.worldHeight, self.isMirrored)
        local fx2, fy2 = geometry.localPixelToCanonical(a.cx, a.cy, geometry.worldWidth, geometry.worldHeight, self.isMirrored)
        self.controller:createArrow(uuid.v4(), fx, fy, fx2, fy2)
      end
    end
    return
  end

  -- Box selection being dragged out.
  if self.boxSelect then
    local b = self.boxSelect
    b.cx, b.cy = V.screenToWorld(self, mx, my)
    if ui.mouseReleased(1) or not ui.mouseDown(1) then
      self.boxSelect = nil
      self:finishBoxSelect(b)
    end
    return
  end

  -- Active drag.
  if self.drag then
    if self.drag.primaryId then self:sendCardPreview(false) end
    if ui.mouseReleased(1) then self:endDrag() end
    return
  end
  if self.pending then
    local p = self.pending
    if ui.mouseDown(1) and not ui.mouseReleased(1) then
      if math.abs(mx - p.pressX) > DRAG_THRESHOLD or math.abs(my - p.pressY) > DRAG_THRESHOLD then self:startDrag() end
      return
    end
    -- Released without dragging: a click. Fall through so a new press in
    -- this same frame (e.g. a fast double-click) still gets handled.
    self.pending = nil
    if p.src.onClick then p.src.onClick() end
    if not ui.mousePressed(1) then return end
  end

  if not free or not item then return end

  if ui.mousePressed(1) then
    if self.tabDown and TABLE_KINDS[item.kind] and self:isOverTable(mx, my) then
      local wx, wy2 = V.screenToWorld(self, mx, my)
      self.arrowDrag = { sx = wx, sy = wy2, cx = wx, cy = wy2 }
      self.lastPreviewAt = 0
      self:sendArrowPreview()
      return
    end
    local k = item.kind
    if k == "table" and not self.spectator then
      -- Empty felt: drag out a selection box (Shift adds to the selection).
      local wx, wy2 = V.screenToWorld(self, mx, my)
      self.boxSelect = { sx = wx, sy = wy2, additive = love.keyboard.isDown("lshift", "rshift") }
      return
    elseif k == "shuffle" or k == "deckSave" or k == "avatar" or k == "tokenBagIdle" then
      self.clickItem = item
    elseif (k == "counter" or k == "dockedCounter") and ui.clickCount(1) >= 2 and item.interactable then
      local rightSide
      if k == "dockedCounter" and item.mirror then
        rightSide = (2 * item.mirror.cx - mx) >= item.x + item.w / 2
      else
        rightSide = mx >= item.x + item.w / 2
      end
      self.controller:setWidgetValue(item.widget.instanceId, item.widget.value + (rightSide and 1 or -1))
    elseif DRAGGABLE[k] then
      local src = self:sourceFor(item)
      if src then
        if k == "pile" then
          local rootId = item.rootId
          src.onClick = function() self.controller:drawCard(rootId, 1) end
        elseif k == "revealedBagToken" then
          src.onClick = function() self.controller:returnBagToken(item.widget.instanceId, item.slotId) end
        end
        self:pressSource(self:applySelectionToPress(item, src), mx, my)
      end
    end
  end
  if ui.mouseReleased(1) and self.clickItem then
    local ci = self.clickItem
    self.clickItem = nil
    if ci == item or (ci.kind == item.kind and V.hitTest(ci, mx, my)) then
      if ci.kind == "shuffle" then ci.click()
      elseif ci.kind == "deckSave" then self:saveDeckWidget(ci.widget)
      elseif ci.kind == "avatar" then self.session:setActiveSeat(ci.player.id)
      elseif ci.kind == "tokenBagIdle" then self.controller:drawBagToken(ci.widget.instanceId)
      end
    end
  end
  if ui.mousePressed(2) then self.rightPressItem = item end
  if ui.mouseReleased(2) and self.rightPressItem then
    local rp = self.rightPressItem
    self.rightPressItem = nil
    if not self:openItemMenu(rp, mx, my) and self:isOverTable(mx, my) and TABLE_KINDS[rp.kind] then
      self:openBoardMenu(mx, my)
    end
  end
end

function T:sendArrowPreview()
  local a = self.arrowDrag
  if not a then return end
  local fx, fy = geometry.localPixelToCanonical(a.sx, a.sy, geometry.worldWidth, geometry.worldHeight, self.isMirrored)
  local fx2, fy2 = geometry.localPixelToCanonical(a.cx, a.cy, geometry.worldWidth, geometry.worldHeight, self.isMirrored)
  self.controller:previewArrowDrag(fx, fy, fx2, fy2)
end

---------------------------------------------------------------------------
-- In-game overlays
---------------------------------------------------------------------------

local PANEL = theme.fixed.overlayPanel
local WHITE = theme.fixed.white
local panel = require("src.ui.kit.panel")

function T:drawGameMenu()
  local close = function() self:toggleGameMenu() end
  local kickable = {}
  if self.onKickPlayer then
    for _, p in ipairs(self.state.players) do
      if p.role ~= "host" and p.connected then kickable[#kickable + 1] = p end
    end
  end
  local showLoadScenario = self.canLoadScenario and self.game.hasScenarios and #self.game.scenarios > 0
  local h = 64 + 16 + 40 + (self.onSaveGame and 52 or 0) + 52 + 52 + (showLoadScenario and 52 or 0) + 16
  if self.onKickPlayer then h = h + 20 + 24 + math.max(1, #kickable) * 48 end
  local x, y, w = panel.draw("gamemenu", 360, h, "Game Menu", close)
  local yy = y + 16
  local white = WHITE
  if ui.button(self.leaveButtonLabel, x + 16, yy, w - 32, 40, { variant = "outlined", icon = "logout", color = white, id = "gm:leave" }) then
    overlays.confirm(self.leaveButtonLabel, self.leaveConfirmationMessage, self.leaveButtonLabel, function() self.onLeaveGame() end)
  end
  yy = yy + 40
  if self.onSaveGame then
    yy = yy + 12
    if ui.button("Save Game...", x + 16, yy, w - 32, 40, { variant = "outlined", icon = "save", color = white, id = "gm:save" }) then
      self.onSaveGame()
    end
    yy = yy + 40
  end
  yy = yy + 12
  if ui.button("Settings", x + 16, yy, w - 32, 40, { variant = "outlined", icon = "settings", color = white, id = "gm:settings" }) then
    require("src.ui.screens.settings_dialog").open({ inGame = true, game = self.game })
  end
  yy = yy + 40 + 12
  if ui.button("Controls", x + 16, yy, w - 32, 40, { variant = "outlined", icon = "keyboard", color = white, id = "gm:controls" }) then
    require("src.ui.screens.controls_dialog").open()
  end
  yy = yy + 40
  if showLoadScenario then
    yy = yy + 12
    if ui.button("Load Scenario...", x + 16, yy, w - 32, 40, { variant = "outlined", icon = "layers", color = white, id = "gm:scenario" }) then
      self:promptLoadScenario()
    end
    yy = yy + 40
  end
  if self.onKickPlayer then
    yy = yy + 20
    ui.text("Kick a Player", x + 16, yy, { weight = "bold", color = { 1, 1, 1, 0.7 } })
    yy = yy + 24
    if #kickable == 0 then
      ui.text("No other players connected right now.", x + 16, yy + 8, { color = { 1, 1, 1, 0.54 } })
    end
    for _, p in ipairs(kickable) do
      ui.text(p.name, x + 16, yy, { h = 48, valign = "middle", color = WHITE })
      if ui.iconButton("person_remove", x + w - 56, yy + 4, { color = theme.fixed.redAccent, tooltip = "Kick " .. p.name, id = "gm:kick:" .. p.id }) then
        overlays.confirm("Kick Player", "Remove " .. p.name .. " from the game? They can rejoin later if you don't end the session.",
          "Kick", function() self.onKickPlayer(p.id) end)
      end
      yy = yy + 48
    end
  end
end

local LOG_W = 340

-- Docked to the left edge, sliding in/out with self.logAnim (see
-- toggleLog/update).
function T:drawLog()
  local entries = self.state.log
  local hasSave = self.game.folderPath ~= nil
  local _, sh = ui.screenSize()
  local top = overlays.contentTop
  local x, y, w, h = LOG_W * (self.logAnim - 1), top, LOG_W, sh - top
  ui.cover(x, y, w, h)
  ui.rect("fill", x, y, w, h, 0, PANEL)
  ui.text("Game Log", x + 16, y + 16, { weight = "bold", color = WHITE })
  local listTop = y + 48
  local listH = h - 48 - (hasSave and 73 or 0)
  if #entries == 0 then
    ui.text("No actions yet.", x, listTop, { w = w, h = listH, align = "center", valign = "middle", color = { 1, 1, 1, 0.54 } })
  else
    local f = theme.font(14)
    local textW = w - 32
    local prefixW = f:getWidth("[00:00:00] ")
    -- Measure all entries (cheap; logs are small).
    local heights, total = {}, 16
    for i, e in ipairs(entries) do
      local _, lines = f:getWrap(e.message, textW - prefixW)
      heights[i] = math.max(1, #lines) * f:getHeight() + 4
      total = total + heights[i]
    end
    if self.logScrollToEnd then
      ui.scrollTo("log:list", math.max(0, total - listH))
      self.logScrollToEnd = false
    end
    local off = ui.beginScroll("log:list", x, listTop, w, listH)
    local yy = listTop + 8 - off
    for i, e in ipairs(entries) do
      if yy + heights[i] > listTop and yy < listTop + listH then
        ui.text("[" .. models.formatElapsedTime(e.elapsedMs) .. "] ", x + 16, yy + 2, { font = f, color = { 1, 1, 1, 0.38 } })
        ui.text(e.message, x + 16 + prefixW, yy + 2, { font = f, w = textW - prefixW, color = WHITE })
      end
      yy = yy + heights[i]
    end
    ui.endScroll("log:list", total)
  end
  if hasSave then
    ui.divider(x, listTop + listH, w, { 1, 1, 1, 0.24 })
    local bw = ui.buttonWidth("Save Log", { icon = "save_alt" })
    if ui.button("Save Log", x + 16, listTop + listH + 16, bw, 40, { variant = "outlined", icon = "save_alt", color = WHITE, id = "log:save" }) then
      self:saveLog()
    end
  end
end

local CHAT_W = 340

local function chatTimeLabel(at) return os.date("%H:%M", at) end

-- Docked to the right edge, sliding in/out with self.chatAnim (see
-- toggleChat/update). Only drawn while self.sc is set (server games).
function T:drawChat()
  local sc = self.sc
  local sw, sh = ui.screenSize()
  local top = overlays.contentTop
  local x, y, w, h = sw - CHAT_W * self.chatAnim, top, CHAT_W, sh - top
  ui.cover(x, y, w, h)
  ui.rect("fill", x, y, w, h, 0, PANEL)
  ui.text("Chat", x + 16, y + 16, { weight = "bold", color = WHITE })
  local inputH = 48
  local ly, lh = y + 48, h - 48 - inputH - 24
  local off = ui.beginScroll("table:chat", x + 8, ly, w - 16, lh)
  local cy = ly - off
  local textW = w - 32
  for _, line in ipairs(sc.roomChat) do
    local head = chatTimeLabel(line.at) .. "  " .. line.name
    ui.text(head, x + 16, cy, { size = 12, weight = "bold", color = { 1, 1, 1, 0.54 }, w = textW, ellipsis = true })
    cy = cy + 18
    ui.text(line.text, x + 16, cy, { w = textW, color = WHITE })
    cy = cy + ui.textHeight(line.text, textW) + 10
  end
  local contentH = cy + off - ly
  ui.endScroll("table:chat", contentH)
  if #sc.roomChat ~= self.seenChat then
    self.seenChat = #sc.roomChat
    ui.scrollToEnd("table:chat")
  end
  if #sc.roomChat == 0 then
    ui.text("Say hello!", x, ly, { w = w, h = lh, align = "center", valign = "middle", color = { 1, 1, 1, 0.54 } })
  end
  -- textField always draws with theme.c's colors; swap to the dark palette
  -- (same trick as drawLibrary) so typed text is readable on this dark panel.
  local savedTheme = theme.c
  theme.c = theme.dark
  local text, _, submitted = ui.textField("table:chatinput", x + 12, y + h - inputH - 12, w - 24 - 44, self.chatText,
    { label = "Message", labelBackground = PANEL, maxLength = 500 })
  theme.c = savedTheme
  self.chatText = text
  local send = ui.iconButton("send", x + w - 12 - 40, y + h - inputH - 12 + 4, { id = "table:chatsend", color = WHITE,
    tooltip = "Send", disabled = text:match("^%s*$") ~= nil })
  if (submitted or send) and not text:match("^%s*$") then
    sc:send("chatSend", json.object({ "text", text, "roomId", sc.roomId }))
    self.chatText = ""
    ui.focusField("table:chatinput")
  end
end

-- A grid of card tiles (search results / card library) inside a panel, laid
-- out like the Deck Editor's card pool: cards a third larger (GRID_SCALE)
-- with up to GRID_NAME_LINES lines of name.
local GRID_SCALE, GRID_NAME_LINES = 4 / 3, 3
local GW, GH = CW * GRID_SCALE, CH * GRID_SCALE
function T:drawCardGrid(id, x, y, w, h, list, tileFn)
  local nameH = GRID_NAME_LINES * theme.font(11):getHeight()
  local maxExtent, tileH, gap = GW + 24, GH + 6 + nameH + 4, 12
  local inner = w - 24
  local cols = math.max(1, math.ceil((inner + gap) / (maxExtent + gap)))
  local tileW = (inner - (cols - 1) * gap) / cols
  local off = ui.beginScroll(id, x, y, w, h)
  for i, entry in ipairs(list) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local tx, ty = x + 12 + col * (tileW + gap), y + 12 + row * (tileH + gap) - off
    if ty + tileH > y and ty < y + h then tileFn(entry, tx, ty, tileW, tileH) end
  end
  ui.endScroll(id, 24 + math.ceil(#list / cols) * (tileH + gap) - gap)
end

local function gridName(title, tx, ty, tw)
  ui.text(title, tx, ty + GH + 6, { size = 11, w = tw, align = "center", maxLines = GRID_NAME_LINES, color = WHITE })
end

function T:drawSearch()
  local acting = self.session:actingPlayerId()
  local search
  for _, s in ipairs(self.state.searches) do
    if s.searcherId == acting then search = s end
  end
  if not search then return end
  local cards, title
  if search.targetType == "zone" then
    cards = {}
    for _, c in ipairs(self.state.cards) do
      if c.zone == "zone" and c.zoneId == search.targetId and c.ownerId == search.targetOwnerId then cards[#cards + 1] = c end
    end
    title = "Zone"
    local parsed = dwz.parse(search.targetId)
    local z = self:zoneById(parsed and parsed.realZoneId or search.targetId)
    if z then title = z.name end
  else
    cards = stacks.stackOf(self.state.cards, search.targetId)
    title = "Pile"
  end
  table.sort(cards, function(a, b) return a.zIndex > b.zIndex end)
  local sw, sh = ui.screenSize()
  local pw, ph = math.min(1280, sw - 40), math.min(720, sh - overlays.contentTop - 40)
  local x, y, w, h = panel.draw("search", pw, ph, title, function() self.controller:stopSearch() end,
    #cards .. " card" .. (#cards == 1 and "" or "s"))
  if #cards == 0 then
    ui.text("Nothing here to search.", x, y, { w = w, h = h, align = "center", valign = "middle", color = { 1, 1, 1, 0.54 } })
    return
  end
  self:drawCardGrid("search:grid", x, y, w, h, cards, function(c, tx, ty, tw)
    local def = V.def(self, c)
    local cx, cy = tx + tw / 2, ty + GH / 2
    local r = ui.region("search:" .. c.instanceId, cx - GW / 2, ty, GW, GH, { cursor = "hand" })
    CR.draw({ def = def, faceUp = def ~= nil, cx = cx, cy = cy, scale = GRID_SCALE, cardBacks = self.game.cardBacks,
      scenarioCardBackId = self.game.scenarioCardBackId,
      angle = def and CR.orientationTurns(def.orientation) * 2 * math.pi or 0,
      alpha = V.isDragging(self, c.instanceId) and 0.3 or 1 })
    gridName(def and def.cardTitle or "", tx, ty, tw)
    if r.hovered then self.overlayHoverId = c.instanceId end
    if r.pressed then
      local mx, my = ui.mouse()
      self:pressSource({ kind = "card", card = c, cx = cx, cy = cy, scale = GRID_SCALE, forceFaceUp = true }, mx, my)
    end
  end)
end

function T:drawLibrary()
  local L = self.library
  local game = self.game
  local visible = filterBar.visible(L, game)
  if game.hasScenarios then
    visible = util.filter(visible, function(def) return (def.isScenarioCard == true) == self.libraryScenario end)
  end
  local sw, sh = ui.screenSize()
  local pw, ph = math.min(1280, sw - 40), math.min(720, sh - overlays.contentTop - 40)
  local saved = theme.c
  theme.c = theme.dark
  local x, y, w, h = panel.draw("library", pw, ph, "Card Library", function() self.libraryOpen = false end,
    #visible .. " of " .. #game.cards .. " card" .. (#game.cards == 1 and "" or "s"))
  local yy = y
  if game.hasScenarios then
    self.libraryScenario = ui.segmented("lib:mode", x + 16, yy, w - 32,
      { { value = false, label = "Player Cards" }, { value = true, label = "Scenario Cards" } }, self.libraryScenario, { h = 40 })
    yy = yy + 52
  end
  yy = filterBar.drawFilters("lib", L, game, x + 16, yy, w - 32) + 12
  yy = filterBar.drawSearch("lib", L, game, x + 16, yy, w - 32, { labelBackground = PANEL, clearColor = WHITE }) + 4
  local gridH = y + h - yy
  if #visible == 0 then
    ui.text("No cards match the current filters.", x, yy, { w = w, h = gridH, align = "center", valign = "middle", color = { 1, 1, 1, 0.54 } })
  else
    self:drawCardGrid("library:grid", x, yy, w, gridH, visible, function(def, tx, ty, tw)
      local cx, cy = tx + tw / 2, ty + GH / 2
      local r = ui.region("lib:" .. def.id, cx - GW / 2, ty, GW, GH, { cursor = "hand" })
      CR.draw({ def = def, faceUp = true, cx = cx, cy = cy, scale = GRID_SCALE, cardBacks = self.game.cardBacks,
        scenarioCardBackId = self.game.scenarioCardBackId,
        angle = CR.orientationTurns(def.orientation) * 2 * math.pi })
      gridName(def.cardTitle, tx, ty, tw)
      if r.hovered then self.libraryHoverDef = def end
      if r.pressed then
        local mx, my = ui.mouse()
        self:pressSource({ kind = "library", definitionId = def.id, def = def, cx = cx, cy = cy, scale = 1 }, mx, my)
      end
    end)
  end
  theme.c = saved
end

local TOKEN_TILE = 96
function T:drawTokenPicker()
  local sw, sh = ui.screenSize()
  local pw, ph = math.min(900, sw - 40), math.min(600, sh - overlays.contentTop - 40)
  -- The plain color token is always first and always present, even with no
  -- custom images in the game's "tokens" folder.
  local entries = { { kind = "token", name = "Color Token" } }
  for _, e in ipairs(self.tokenImages) do entries[#entries + 1] = e end
  local x, y, w, h = panel.draw("tokenPicker", pw, ph, "Tokens", function() self.tokenPickerOpen = false end,
    #entries .. " token" .. (#entries == 1 and "" or "s"))
  local gap = 12
  local cols = math.max(1, math.floor((w - 24 + gap) / (TOKEN_TILE + gap)))
  local tileW = (w - 24 - (cols - 1) * gap) / cols
  local nameH = theme.font(11):getHeight() + 4
  local tileH = TOKEN_TILE + nameH
  local off = ui.beginScroll("tokenPicker:grid", x, y, w, h)
  for i, entry in ipairs(entries) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local tx, ty = x + 12 + col * (tileW + gap), y + 12 + row * (tileH + gap) - off
    if ty + tileH > y and ty < y + h then
      local cx, cy = tx + tileW / 2, ty + TOKEN_TILE / 2
      local isColor = entry.kind == "token"
      local id = isColor and "tokenPicker:color" or ("tokenPicker:" .. entry.file)
      local r = ui.region(id, tx, ty, tileW, TOKEN_TILE, { cursor = "hand" })
      if isColor then
        V.tokenFace(self, COLOR_TOKEN_WIDGET, cx, cy, TOKEN_TILE, 1)
      else
        local img = imageCache.get(entry.path)
        if img then
          local iw, ih = img:getDimensions()
          local s = math.min(tileW / iw, TOKEN_TILE / ih)
          love.graphics.setColor(1, 1, 1, 1)
          love.graphics.draw(img, cx - iw * s / 2, cy - ih * s / 2, 0, s, s)
        end
      end
      ui.text(entry.name, tx, ty + TOKEN_TILE + 2, { w = tileW, align = "center", size = 11, maxLines = 1, color = WHITE })
      if r.pressed then
        local mx, my = ui.mouse()
        if isColor then
          self:pressSource({ kind = "newToken", cx = cx, cy = cy, scale = 1 }, mx, my)
        else
          self:pressSource({ kind = "imageToken", imageFile = entry.file, cx = cx, cy = cy, scale = 1 }, mx, my)
        end
      end
    end
  end
  ui.endScroll("tokenPicker:grid", 24 + math.ceil(#entries / cols) * (tileH + gap) - gap)
end

-- Space preview: big copy of exactly what's visible, centered in the half
-- of the screen away from the mouse.
function T:drawPreview()
  if not self.spaceDown then return end
  local def, faceUp, orientation
  local c = self:hoveredCard()
  if c then
    def = V.def(self, c)
    faceUp = (c.faceUp or self.hoveredForceFaceUp) and def ~= nil
    if c.zone == "table" then
      orientation = CR.shownOrientation(def, not faceUp, self.game.cardBacks, self.game.scenarioCardBackId)
    elseif c.zone == "zone" then
      -- Zones can be displayed turned (ZoneDefinition.orientation); the
      -- pile box is drawn at that angle regardless of face-up state, so
      -- the preview should match what's actually on screen.
      local zone = self:zoneById(c.zoneId)
      orientation = zone and zone.orientation or "portrait"
    else
      orientation = "portrait"
    end
  elseif self.libraryHoverDef then
    def = self.libraryHoverDef
    faceUp = true
    orientation = def.orientation
  else
    return
  end
  local sw, sh = ui.screenSize()
  CR.drawPreview({ { def = def, faceUp = faceUp, orientation = orientation } }, self.game.cardBacks, sw, sh, (ui.mouse()),
    self.game.scenarioCardBackId)
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

function T:draw(x, y, w, h)
  self:derive()
  self:refreshSelection()
  if self.tableRect then self:processInput() end
  self.libraryHoverDef = nil
  local chatSqueeze = (self.sc and CHAT_W * self.chatAnim) or 0
  local logSqueeze = LOG_W * self.logAnim
  V.draw(self, x + logSqueeze, y, w - logSqueeze - chatSqueeze, h)
  self.prevItems = self.items
  -- Overlays, in Flutter's stacking order.
  if self:mySearchOpen() then ui.overlay(function() self:drawSearch() end) end
  if self.libraryOpen then ui.overlay(function() self:drawLibrary() end) end
  if self.tokenPickerOpen then ui.overlay(function() self:drawTokenPicker() end) end
  if self.logAnim > 0.001 then ui.overlay(function() self:drawLog() end) end
  if self.rulebookOpen then ui.overlay(function() self.rulebook:draw(function() self:toggleRulebook() end) end) end
  if self.gameMenuOpen then ui.overlay(function() self:drawGameMenu() end) end
  if self.sc and self.chatAnim > 0.001 then ui.overlay(function() self:drawChat() end) end
  ui.overlay(function() self:drawDragFeedback() end)
  -- Card preview (Space) must render above everything, including chat.
  ui.overlay(function() self:drawPreview() end)
end

function T:mySearchOpen()
  local acting = self.session:actingPlayerId()
  for _, s in ipairs(self.state.searches) do
    if s.searcherId == acting then return true end
  end
  return false
end

return T
