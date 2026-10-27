-- Table layout and drawing (port of the build/_build* parts of
-- lib/ui/table_screen.dart). Draws the felt, shared-zone sidebars, player
-- rows (hands, zones, avatars) and the pannable/zoomable table, and records
-- hit-test items + drop targets on the screen object `T` for the next
-- frame's input handling (see table_screen.lua).
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local color = require("src.core.color")
local models = require("src.core.models")
local stacks = require("src.core.stack_utils")
local dwz = require("src.core.deck_widget_zones")
local geometry = require("src.core.geometry")
local imageCache = require("src.data.image_cache")
local resolver = require("src.data.image_resolver")
local CR = require("src.ui.table.card_render")
local handSettings = require("src.data.hand_settings")
local selection = require("src.ui.table.selection")

local V = {}

local CW, CH = CR.cardWidth, CR.cardHeight
local EXTRA = CR.pileExtra
local SLOT_W, SLOT_H = CW + EXTRA + 16, CH + EXTRA + 16 -- 110 x 140 (with 8px padding)
local BAND_H = CH + EXTRA + 16                           -- hand band height (140)
V.SLOT_W, V.SLOT_H, V.BAND_H = SLOT_W, SLOT_H, BAND_H

V.counterSize = 80
V.tokenSize = 15

local DECK_HEADER, DECK_FOOTER, DECK_SPACING, DECK_PAD = 24, 36, 8, 8

function V.deckWidgetSize(subZoneCount)
  local n = math.max(1, subZoneCount)
  local zw, zh = CW + EXTRA, CH + EXTRA
  return n * zw + (n - 1) * DECK_SPACING + DECK_PAD * 2,
    DECK_HEADER + DECK_SPACING + zh + DECK_SPACING + DECK_FOOTER + DECK_PAD * 2
end

function V.widgetSize(T, kind)
  if kind == "simpleCounter" or kind == "packGenerator" then return V.counterSize, V.counterSize end
  if kind == "token" then return V.tokenSize, V.tokenSize end
  if kind == "deckBuilder" then return V.deckWidgetSize(#models.GameDefinition.deckBuildingZones(T.game)) end
  return 0, 0
end

local function rgba(argb, a) return { color.toRgba(argb, a) } end

---------------------------------------------------------------------------
-- Colors
---------------------------------------------------------------------------

function V.playerById(T, id)
  for _, p in ipairs(T.state.players) do
    if p.id == id then return p end
  end
  return nil
end

function V.ownerBorderColor(T, ownerId)
  if ownerId == nil or T.bordersHidden then return nil end
  local p = V.playerById(T, ownerId)
  return p and rgba(p.color) or nil
end

-- Player color, HSL lightness - 0.30, at 55% alpha (table_screen.dart _playerTintColor).
local function tint(argb)
  local r, g, b = color.toRgba(argb)
  local h, s, l = color.rgbToHsl(r, g, b)
  r, g, b = color.hslToRgb(h, s, math.max(0, math.min(1, l - 0.30)))
  return { r, g, b, 0.55 }
end

function V.zoneBackground(T, ownerId)
  if not T.colorTintEnabled or ownerId == nil then return { 0, 0, 0, 0.15 } end
  local p = V.playerById(T, ownerId)
  return p and tint(p.color) or { 0, 0, 0, 0.15 }
end

function V.arrowColor(T, playerId)
  local p = playerId and V.playerById(T, playerId)
  return p and rgba(p.color) or theme.fixed.redAccent
end

---------------------------------------------------------------------------
-- Camera
---------------------------------------------------------------------------

local WW, WH = geometry.worldWidth, geometry.worldHeight
local M = geometry.tablePanMarginFraction

function V.maxPan(T)
  local tr = T.tableRect
  return math.max(0, (WW * (1 + 2 * M) - tr.w) / 2), math.max(0, (WH * (1 + 2 * M) - tr.h) / 2)
end

function V.clampedCamera(T)
  local mx, my = V.maxPan(T)
  return math.max(-mx, math.min(mx, T.camX)), math.max(-my, math.min(my, T.camY))
end

-- World pixel (0..2560 x 0..1440) -> screen.
function V.worldToScreen(T, wx, wy)
  local tr = T.tableRect
  local cx, cy = V.clampedCamera(T)
  return tr.x + tr.w / 2 + (wx + cx - WW / 2) * T.zoom, tr.y + tr.h / 2 + (wy + cy - WH / 2) * T.zoom
end

function V.screenToWorld(T, sx, sy)
  local tr = T.tableRect
  local cx, cy = V.clampedCamera(T)
  return WW / 2 - cx + (sx - tr.x - tr.w / 2) / T.zoom, WH / 2 - cy + (sy - tr.y - tr.h / 2) / T.zoom
end

function V.canonicalToWorld(T, fx, fy)
  return geometry.canonicalToLocalPixel(fx, fy, WW, WH, T.isMirrored)
end

function V.toScreen(T, fx, fy)
  local wx, wy = V.canonicalToWorld(T, fx, fy)
  return V.worldToScreen(T, wx, wy)
end

-- Screen point -> canonical, optionally clamping Y like a dropped card.
function V.screenToCanonical(T, sx, sy, clampHeight)
  local wx, wy = V.screenToWorld(T, sx, sy)
  if clampHeight then wy = geometry.clampCardCenterY(wy, WH, clampHeight) end
  return geometry.localPixelToCanonical(wx, wy, WW, WH, T.isMirrored)
end

function V.worldToCanonical(T, wx, wy)
  return geometry.localPixelToCanonical(wx, wy, WW, WH, T.isMirrored)
end

-- Screen point -> canonical, clamped so an item with the given half
-- extents (world pixels) stays fully on the table.
function V.screenToCanonicalClamped(T, sx, sy, halfW, halfH)
  local wx, wy = V.screenToWorld(T, sx, sy)
  wx, wy = selection.clampWorldCenter(wx, wy, halfW, halfH)
  return V.worldToCanonical(T, wx, wy)
end

---------------------------------------------------------------------------
-- Items (hit regions recorded during draw)
---------------------------------------------------------------------------

function V.addItem(T, item)
  if T.drawMirror then item.mirror = T.drawMirror end
  T.items[#T.items + 1] = item
  return item
end

-- Maps a screen point into an item's unrotated frame and tests it.
function V.hitTest(item, mx, my)
  if item.mirror then
    mx, my = 2 * item.mirror.cx - mx, 2 * item.mirror.cy - my
  end
  if item.angle and item.angle ~= 0 then
    local dx, dy = mx - item.cx, my - item.cy
    local c, s = math.cos(-item.angle), math.sin(-item.angle)
    local lx, ly = dx * c - dy * s, dx * s + dy * c
    return math.abs(lx) <= item.hw and math.abs(ly) <= item.hh
  end
  if item.circle then
    local dx, dy = mx - item.cx, my - item.cy
    return dx * dx + dy * dy <= item.circle * item.circle
  end
  return mx >= item.x and my >= item.y and mx < item.x + item.w and my < item.y + item.h
end

local function addDropZone(T, zoneId, x, y, w, h)
  T.dropZones[#T.dropZones + 1] = { zoneId = zoneId, x = x, y = y, w = w, h = h }
end

-- Runs fn with everything drawn rotated 180 degrees inside box (RotatedBox
-- quarterTurns: 2); items registered meanwhile get mirrored hit tests.
local function withRotated(T, rotate, x, y, w, h, fn)
  if not rotate then return fn() end
  local cx, cy = x + w / 2, y + h / 2
  love.graphics.push()
  love.graphics.translate(cx, cy)
  love.graphics.rotate(math.pi)
  love.graphics.translate(-cx, -cy)
  local prev = T.drawMirror
  T.drawMirror = { cx = cx, cy = cy }
  fn()
  T.drawMirror = prev
  love.graphics.pop()
end

---------------------------------------------------------------------------
-- Animations
---------------------------------------------------------------------------

local ROT_DURATION = 0.15

-- Animated total rotation (in turns) for an instance (AnimatedRotation).
function V.animatedTurns(T, key, target)
  local a = T.rotAnim[key]
  local now = love.timer.getTime()
  if not a then
    a = { from = target, to = target, t0 = now }
    T.rotAnim[key] = a
  elseif a.to ~= target then
    local t = math.min(1, (now - a.t0) / ROT_DURATION)
    local eased = 1 - (1 - t) ^ 3
    a.from = a.from + (a.to - a.from) * eased
    a.to = target
    a.t0 = now
  end
  local t = math.min(1, (now - a.t0) / ROT_DURATION)
  local eased = 1 - (1 - t) ^ 3
  return a.from + (a.to - a.from) * eased
end

function V.wiggleAngle(T, key)
  local t0 = T.wiggle[key]
  if not t0 then return 0 end
  local t = (love.timer.getTime() - t0) / 0.4
  if t >= 1 then
    T.wiggle[key] = nil
    return 0
  end
  return math.sin(t * math.pi * 6) * 0.15 * (1 - t)
end

---------------------------------------------------------------------------
-- Card helpers
---------------------------------------------------------------------------

function V.def(T, card) return card and T.session.definitionsById[card.definitionId] end

-- Table card rotation in turns (mirroring + orientation + quarter turns).
function V.cardTurns(T, card, faceAway)
  local def = V.def(T, card)
  local showingBack = not (card.faceUp and def ~= nil)
  local orientation = CR.shownOrientation(def, showingBack, T.game.cardBacks)
  return (faceAway and 0.5 or 0) + CR.orientationTurns(orientation) + (card.rotationTurns or 0) / 4
end

function V.isDragging(T, id)
  local d = T.drag
  return d and d.started and (d.primaryId == id or (d.groupIds and d.groupIds[id]))
end

-- Opacity for a card that is being dragged here or by another player.
function V.ghostAlpha(T, id)
  if V.isDragging(T, id) then return 0.3 end
  for _, p in pairs(T.session.cardDragPreviews) do
    if p.playerId ~= T.session:actingPlayerId() then
      for _, pid in ipairs(p.instanceIds) do
        if pid == id then return 0.3 end
      end
    end
  end
  return 1
end

---------------------------------------------------------------------------
-- Table area
---------------------------------------------------------------------------

-- A standard playing card is 2.5in wide, so CW world-units == 2.5in gives us
-- the table's px-per-inch scale. A playmat is typically 24in x 12in.
local PX_PER_INCH = CW / 2.5
local PLAYMAT_W, PLAYMAT_H = 24 * PX_PER_INCH, 12 * PX_PER_INCH

-- The original (pre-playmat-sizing) single center marker, kept as-is.
local SINGLE_MARKER_W, SINGLE_MARKER_H = 1280, 720

-- Draws a marker rect sized markW x markH with its top-left world corner at
-- (left, top).
local function drawPlaymatRect(T, left, top, markW, markH)
  local x, y = V.worldToScreen(T, left, top)
  local w, h = markW * T.zoom, markH * T.zoom
  local r = 32 * T.zoom
  local mat = T.playmatIndex >= 1 and T.playmats[T.playmatIndex]
  if mat then
    local img = imageCache.get(mat)
    if img then
      -- Cover-fit, clipped to the rounded marker via a stencil.
      love.graphics.stencil(function() love.graphics.rectangle("fill", x, y, w, h, r, r) end, "replace", 1)
      love.graphics.setStencilTest("greater", 0)
      local iw, ih = img:getDimensions()
      local s = math.max(w / iw, h / ih)
      love.graphics.setColor(1, 1, 1, 0.5)
      love.graphics.draw(img, x + (w - iw * s) / 2, y + (h - ih * s) / 2, 0, s, s)
      love.graphics.setStencilTest()
    end
  end
  local bc = T:playmatBorderColor()
  love.graphics.setColor(bc[1], bc[2], bc[3])
  love.graphics.setLineWidth(4 * T.zoom)
  love.graphics.rectangle("line", x + 2 * T.zoom, y + 2 * T.zoom, w - 4 * T.zoom, h - 4 * T.zoom, r, r)
  love.graphics.setLineWidth(1)
end

-- Per-player markers (toggled with F6): one playmat per player, grouped into
-- the same near/far rows used for hand bands, with 2x card-width padding
-- between mats side by side and 0.5x card-width padding between the near
-- and far rows.
local MAT_GAP_X, MAT_GAP_Y = 2 * CW, CW / 2

-- Left (world-x) of each of `count` mats, evenly spaced and centered.
local function rowMatLefts(count)
  local rowW = count * PLAYMAT_W + (count - 1) * MAT_GAP_X
  local startLeft = (WW - rowW) / 2
  local lefts = {}
  for i = 0, count - 1 do lefts[#lefts + 1] = startLeft + i * (PLAYMAT_W + MAT_GAP_X) end
  return lefts
end

local function drawPerPlayerMarkers(T)
  local rows = T.derived.rows
  local nTop, nBottom = #rows.topRow, #rows.bottomRow
  if nTop == 0 and nBottom == 0 then return end
  local gapY = (nTop > 0 and nBottom > 0) and MAT_GAP_Y or 0
  local blockH = (nTop > 0 and PLAYMAT_H or 0) + gapY + (nBottom > 0 and PLAYMAT_H or 0)
  local topRowTop = (WH - blockH) / 2
  if nTop > 0 then
    for _, left in ipairs(rowMatLefts(nTop)) do drawPlaymatRect(T, left, topRowTop, PLAYMAT_W, PLAYMAT_H) end
  end
  if nBottom > 0 then
    local bottomRowTop = nTop > 0 and (topRowTop + PLAYMAT_H + gapY) or topRowTop
    for _, left in ipairs(rowMatLefts(nBottom)) do drawPlaymatRect(T, left, bottomRowTop, PLAYMAT_W, PLAYMAT_H) end
  end
end

local function drawCenterMarker(T)
  if T.perPlayerPlaymats then
    drawPerPlayerMarkers(T)
    return
  end
  drawPlaymatRect(T, (WW - SINGLE_MARKER_W) / 2, (WH - SINGLE_MARKER_H) / 2, SINGLE_MARKER_W, SINGLE_MARKER_H)
end

local function drawArrow(fromX, fromY, toX, toY, col)
  local dx, dy = toX - fromX, toY - fromY
  if dx * dx + dy * dy < 4 then return end
  ui.setColor(col)
  love.graphics.setLineWidth(3)
  love.graphics.setLineStyle("smooth")
  love.graphics.line(fromX, fromY, toX, toY)
  love.graphics.circle("fill", fromX, fromY, 1.5)
  local angle = math.atan2(dy, dx)
  local hl, ha = 14, math.pi / 7
  love.graphics.polygon("fill", toX, toY,
    toX - math.cos(angle - ha) * hl, toY - math.sin(angle - ha) * hl,
    toX - math.cos(angle + ha) * hl, toY - math.sin(angle + ha) * hl)
  love.graphics.setLineWidth(1)
end
V.drawArrow = drawArrow

local function drawPileBox(T, opts)
  -- Shared by table piles, zones and deck-widget sub-zones. Box is the
  -- 94x124 pile area centered at (cx, cy), scaled by `scale`.
  local s = opts.scale or 1
  local cx, cy = opts.cx, opts.cy
  local boxW, boxH = (CW + EXTRA) * s, (CH + EXTRA) * s
  local bx, by = cx - boxW / 2, cy - boxH / 2
  if opts.count == 0 then
    CR.drawEmptySlot(cx, cy, s)
  else
    local wig = opts.wiggleKey and V.wiggleAngle(T, opts.wiggleKey) or 0
    CR.draw({ def = opts.def, faceUp = opts.faceUp, cx = cx, cy = cy, scale = s, angle = (opts.angle or 0) + wig,
      border = opts.border, alpha = opts.alpha, tint = opts.tint, cardBacks = T.game.cardBacks })
    CR.drawCountBadge(bx + boxW - 12 * s, by + 12 * s, opts.count, s)
    if opts.shuffle then
      local scx, scy = cx, by + boxH + 8 * s - 14 * s
      local hovered = T.hoverItem and T.hoverItem.kind == "shuffle" and T.hoverItem.key == opts.shuffle.key
      love.graphics.setColor(0, 0, 0, hovered and 0.75 or 0.54)
      love.graphics.circle("fill", scx, scy, 14 * s)
      local f = theme.iconFont(16)
      love.graphics.setFont(f)
      love.graphics.setColor(1, 1, 1)
      local g = theme.glyph("shuffle")
      love.graphics.print(g, scx, scy, 0, s, s, f:getWidth(g) / 2, f:getHeight() / 2)
      V.addItem(T, { kind = "shuffle", key = opts.shuffle.key, cx = scx, cy = scy, circle = 14 * s,
        click = opts.shuffle.onClick, tooltip = "Shuffle" })
    end
  end
  if opts.searched then CR.drawSearchBadge(cx, by + 12 * s, s) end
  return bx, by, boxW, boxH
end
V.drawPileBox = drawPileBox

local function drawTablePiles(T)
  local D = T.derived
  local acting = T.session:actingPlayerId()
  for _, rootId in ipairs(D.sortedRoots) do
    local cards = D.pileGroups[rootId]
    local top = stacks.topOf(cards)
    local px, py = V.toScreen(T, top.x, top.y)
    local ownedByOpponent = top.ownerId ~= nil and top.ownerId ~= acting
    local faceAway = T:cardFacesAwayFromMe(top.ownerId)
    local turns = V.animatedTurns(T, top.instanceId, V.cardTurns(T, top, faceAway))
    local angle = turns * 2 * math.pi
    local alpha = V.ghostAlpha(T, top.instanceId)
    local def = V.def(T, top)
    local border = V.ownerBorderColor(T, top.ownerId)
    local interactable = not ownedByOpponent and not T.tabDown
    local tint = T:isRootSelected(rootId) and T:selectionTint() or nil
    if #cards > 1 then
      drawPileBox(T, {
        cx = px, cy = py, scale = T.zoom, count = #cards, def = def, faceUp = top.faceUp, angle = angle,
        border = border, alpha = alpha, tint = tint, wiggleKey = "pile:" .. rootId,
        searched = D.pileSearched[rootId],
        shuffle = interactable and { key = "pile:" .. rootId, onClick = function() T:shufflePile(rootId) end } or nil,
      })
      -- The item covers the 94x124 pile box (rotation ignored, like Flutter's
      -- MouseRegion on the unrotated box); the shuffle button was registered
      -- first so the pile item is added before it... ordering fixed below.
      local boxW, boxH = (CW + EXTRA) * T.zoom, (CH + EXTRA) * T.zoom
      table.insert(T.items, #T.items - (interactable and 1 or 0) + 1, {
        kind = "pile", rootId = rootId, card = top, cards = cards, hoverId = top.instanceId,
        x = px - boxW / 2, y = py - boxH / 2, w = boxW, h = boxH,
        interactable = interactable, ownedByOpponent = ownedByOpponent,
      })
    elseif not (T.flight and T.flight.instanceId == top.instanceId) then
      CR.draw({ def = def, faceUp = top.faceUp, cx = px, cy = py, scale = T.zoom, angle = angle, border = border,
        alpha = alpha, tint = tint, cardBacks = T.game.cardBacks })
      V.addItem(T, {
        kind = "tableCard", card = top, rootId = rootId, hoverId = top.instanceId,
        cx = px, cy = py, hw = CW * T.zoom / 2, hh = CH * T.zoom / 2, angle = angle,
        x = px - CW * T.zoom / 2, y = py - CH * T.zoom / 2, w = CW * T.zoom, h = CH * T.zoom,
        interactable = interactable, ownedByOpponent = ownedByOpponent,
      })
    end
  end
end

local function counterFace(w, x, y, size, alpha)
  local bg = rgba(w.backgroundColor, alpha)
  ui.rect("fill", x, y, size, size, 8 * size / 80, bg)
  love.graphics.setColor(1, 1, 1, 0.24 * alpha)
  love.graphics.rectangle("line", x + 0.5, y + 0.5, size - 1, size - 1, 8 * size / 80, 8 * size / 80)
  local f = theme.font(22, "bold")
  local t = tostring(w.value)
  love.graphics.setFont(f)
  ui.setColor(rgba(w.textColor, alpha))
  local s = size / 80
  local fit = math.min(1, (size - 8 * s) / (f:getWidth(t) * s))
  love.graphics.print(t, x + size / 2, y + size / 2, 0, s * fit, s * fit, f:getWidth(t) / 2, f:getHeight() / 2)
end
V.counterFace = counterFace

local function packFace(T, w, x, y, size, alpha)
  local bg = rgba(w.backgroundColor, alpha)
  local r = 8 * size / 80
  ui.rect("fill", x, y, size, size, r, bg)
  local path = resolver.resolvePackGeneratorImagePath(T.game.folderPath)
  local img = path and imageCache.get(path)
  if img then
    love.graphics.stencil(function() love.graphics.rectangle("fill", x, y, size, size, r, r) end, "replace", 1)
    love.graphics.setStencilTest("greater", 0)
    local iw, ih = img:getDimensions()
    local s = math.max(size / iw, size / ih)
    love.graphics.setColor(1, 1, 1, alpha)
    love.graphics.draw(img, x + (size - iw * s) / 2, y + (size - ih * s) / 2, 0, s, s)
    love.graphics.setStencilTest()
  else
    local f = theme.font(11, "bold")
    local s = size / 80
    love.graphics.setFont(f)
    ui.setColor(rgba(w.textColor, alpha))
    love.graphics.push()
    love.graphics.translate(x + 4 * s, y)
    love.graphics.scale(s, s)
    local _, lines = f:getWrap("Pack Generator", 72)
    love.graphics.printf("Pack Generator", 0, (80 - #lines * f:getHeight()) / 2, 72, "center")
    love.graphics.pop()
  end
  love.graphics.setColor(1, 1, 1, 0.24 * alpha)
  love.graphics.rectangle("line", x + 0.5, y + 0.5, size - 1, size - 1, r, r)
end
V.packFace = packFace

local function tokenFace(w, cx, cy, size, alpha)
  ui.setColor(rgba(w.backgroundColor, alpha))
  love.graphics.circle("fill", cx, cy, size / 2)
  love.graphics.setColor(0, 0, 0, 0.26 * alpha)
  love.graphics.circle("line", cx, cy, size / 2)
end
V.tokenFace = tokenFace

local function deckWidgetFace(T, w, x, y, ww, wh, s, alpha)
  local D = T.derived
  local acting = T.session:actingPlayerId()
  local isOwner = w.ownerId == acting
  local interactable = not T.tabDown
  love.graphics.setColor(0, 0, 0, 0.54 * alpha)
  love.graphics.rectangle("fill", x, y, ww, wh, 8 * s, 8 * s)
  love.graphics.setColor(1, 1, 1, 0.24 * alpha)
  love.graphics.rectangle("line", x + 0.5, y + 0.5, ww - 1, wh - 1, 8 * s, 8 * s)
  -- Header: drag handle + owner label.
  local label = "Deck"
  if w.ownerId == acting then
    label = "My Deck"
  else
    local p = V.playerById(T, w.ownerId)
    if p then label = p.name end
  end
  local hx, hy = x + DECK_PAD * s, y + DECK_PAD * s
  love.graphics.push()
  love.graphics.translate(hx, hy)
  love.graphics.scale(s, s)
  local fi = theme.iconFont(14)
  love.graphics.setFont(fi)
  love.graphics.setColor(1, 1, 1, 0.7 * alpha)
  love.graphics.print(theme.glyph("drag_indicator"), 0, (DECK_HEADER - fi:getHeight()) / 2)
  local f = theme.font(11, "bold")
  love.graphics.setFont(f)
  love.graphics.setColor(1, 1, 1, alpha)
  love.graphics.print(ui.ellipsize(label, f, ww / s - DECK_PAD * 2 - 18), 18, (DECK_HEADER - f:getHeight()) / 2)
  love.graphics.pop()
  if isOwner and interactable then
    V.addItem(T, { kind = "deckHeader", widget = w, x = hx, y = hy, w = ww - 2 * DECK_PAD * s, h = DECK_HEADER * s })
  end
  -- Sub-zones.
  local zx = hx
  local zy = hy + (DECK_HEADER + DECK_SPACING) * s
  for _, zone in ipairs(models.GameDefinition.deckBuildingZones(T.game)) do
    local syntheticId = dwz.build(w.instanceId, zone.id)
    local cards = D.cardsByZoneId[syntheticId] or {}
    local top = #cards > 0 and stacks.topOf(cards) or nil
    local zw, zh = (CW + EXTRA) * s, (CH + EXTRA) * s
    if isOwner then
      love.graphics.setColor(0, 0, 0, 0.38 * alpha)
      love.graphics.rectangle("fill", zx, zy, zw, zh)
    end
    drawPileBox(T, { cx = zx + zw / 2, cy = zy + zh / 2, scale = s, count = #cards, def = top and V.def(T, top),
      faceUp = top and top.faceUp, alpha = (top and V.ghostAlpha(T, top.instanceId) or 1) * alpha,
      searched = T:isZoneSearched(syntheticId, w.ownerId) })
    if isOwner then
      addDropZone(T, syntheticId, zx, zy, zw, zh)
      V.addItem(T, { kind = "zone", zoneId = syntheticId, zone = zone, top = top, cards = cards,
        x = zx, y = zy, w = zw, h = zh, tooltip = zone.name, deckWidget = true, interactable = interactable })
    else
      V.addItem(T, { kind = "tooltip", x = zx, y = zy, w = zw, h = zh, tooltip = zone.name })
    end
    zx = zx + zw + DECK_SPACING * s
  end
  if isOwner then
    local by = zy + (CH + EXTRA + DECK_SPACING) * s
    local bw, bh = ww - 2 * DECK_PAD * s, DECK_FOOTER * s
    local hovered = T.hoverItem and T.hoverItem.kind == "deckSave" and T.hoverItem.widget.instanceId == w.instanceId
    ui.rect("fill", hx, by, bw, bh, bh / 2, theme.alpha(T.light.surfaceContainer, alpha))
    if hovered then ui.rect("fill", hx, by, bw, bh, bh / 2, { 0, 0, 0, 0.06 }) end
    local f = theme.font(14, "medium")
    love.graphics.setFont(f)
    ui.setColor(theme.alpha(interactable and T.light.primary or T.light.disabled, alpha))
    love.graphics.print("Save Deck", hx + bw / 2, by + bh / 2, 0, s, s, f:getWidth("Save Deck") / 2, f:getHeight() / 2)
    if interactable then V.addItem(T, { kind = "deckSave", widget = w, x = hx, y = by, w = bw, h = bh }) end
  end
end

local function drawTableWidgets(T)
  local acting = T.session:actingPlayerId()
  -- Widgets stack in zIndex order (the list order already reflects creation;
  -- Flutter draws them in list order too).
  for _, w in ipairs(T.state.widgets) do
    if w.kind ~= "arrow" and w.zoneId == nil then
      local ww, wh = V.widgetSize(T, w.kind)
      local px, py = V.toScreen(T, w.x, w.y)
      local s = T.zoom
      local x, y = px - ww * s / 2, py - wh * s / 2
      local alpha = 1
      if w.attachedCardId and (V.isDragging(T, w.attachedCardId) or V.ghostAlpha(T, w.attachedCardId) < 1) then alpha = 0.3 end
      if T.drag and T.drag.started and (T.drag.widgetId == w.instanceId or (T.drag.tokenIds and T.drag.tokenIds[w.instanceId])) then
        alpha = 0.3
      end
      local interactable = not T.tabDown
      if w.kind == "simpleCounter" then
        counterFace(w, x, y, ww * s, alpha)
        V.addItem(T, { kind = "counter", widget = w, x = x, y = y, w = ww * s, h = wh * s, interactable = interactable })
      elseif w.kind == "token" then
        tokenFace(w, px, py, ww * s, alpha)
        if T:isTokenSelected(w.instanceId) then
          local c = T:selectionColor()
          love.graphics.setColor(c[1], c[2], c[3], alpha)
          love.graphics.setLineWidth(2)
          love.graphics.circle("line", px, py, ww * s / 2 + 2)
          love.graphics.setLineWidth(1)
        end
        V.addItem(T, { kind = "token", widget = w, cx = px, cy = py, circle = math.max(ww * s / 2, 6), interactable = interactable })
      elseif w.kind == "packGenerator" then
        packFace(T, w, x, y, ww * s, alpha)
        V.addItem(T, { kind = "packGenerator", widget = w, x = x, y = y, w = ww * s, h = wh * s, interactable = interactable })
      elseif w.kind == "deckBuilder" then
        -- Body item first so the header/zones/save registered inside win.
        local body = V.addItem(T, { kind = "deckBody", widget = w, x = x, y = y, w = ww * s, h = wh * s,
          interactable = interactable and w.ownerId == acting })
        deckWidgetFace(T, w, x, y, ww * s, wh * s, s, alpha)
        local _ = body
      end
    end
  end
end

local function drawArrows(T)
  for _, w in ipairs(T.state.widgets) do
    if w.kind == "arrow" and w.x2 and w.y2 then
      local fx, fy = V.toScreen(T, w.x, w.y)
      local tx, ty = V.toScreen(T, w.x2, w.y2)
      drawArrow(fx, fy, tx, ty, V.arrowColor(T, w.creatorId))
    end
  end
  if T.arrowDrag then
    local a = T.arrowDrag
    local fx, fy = V.worldToScreen(T, a.sx, a.sy)
    local tx, ty = V.worldToScreen(T, a.cx, a.cy)
    drawArrow(fx, fy, tx, ty, V.arrowColor(T, T.session:actingPlayerId()))
  end
  for pid, p in pairs(T.session.arrowDragPreviews) do
    if pid ~= T.session:actingPlayerId() then
      local fx, fy = V.toScreen(T, p.fx, p.fy)
      local tx, ty = V.toScreen(T, p.fx2, p.fy2)
      drawArrow(fx, fy, tx, ty, V.arrowColor(T, pid))
    end
  end
end

-- Other players' in-flight card drags: ghost faces at the preview target.
local function drawRemoteGhosts(T)
  local byId = T.derived.cardsById
  for pid, p in pairs(T.session.cardDragPreviews) do
    if pid ~= T.session:actingPlayerId() then
      local primary = byId[p.instanceIds[1]]
      if primary then
        local ox, oy = V.toScreen(T, primary.x, primary.y)
        local tx, ty = V.toScreen(T, p.fx, p.fy)
        for _, id in ipairs(p.instanceIds) do
          local c = byId[id]
          if c then
            local cx, cy = V.toScreen(T, c.x, c.y)
            CR.draw({ def = V.def(T, c), faceUp = c.faceUp, cx = tx + (cx - ox), cy = ty + (cy - oy),
              angle = T:cardFacesAwayFromMe(c.ownerId) and math.pi or 0, cardBacks = T.game.cardBacks })
          end
        end
      end
    end
  end
end

-- The box being dragged out for a selection (anchored in world pixels).
local function drawSelectionBox(T)
  local b = T.boxSelect
  if not b or not b.cx then return end
  local x1, y1 = V.worldToScreen(T, b.sx, b.sy)
  local x2, y2 = V.worldToScreen(T, b.cx, b.cy)
  local c = T:selectionColor()
  love.graphics.setColor(c[1], c[2], c[3], 0.15)
  love.graphics.rectangle("fill", math.min(x1, x2), math.min(y1, y2), math.abs(x2 - x1), math.abs(y2 - y1))
  love.graphics.setColor(c[1], c[2], c[3], 0.9)
  love.graphics.setLineWidth(1.5)
  love.graphics.rectangle("line", math.min(x1, x2), math.min(y1, y2), math.abs(x2 - x1), math.abs(y2 - y1))
  love.graphics.setLineWidth(1)
end

local function drawFlight(T)
  local f = T.flight
  if not f then return end
  local t = math.min(1, (love.timer.getTime() - f.t0) / 0.22)
  if t >= 1 then
    T.flight = nil
    return
  end
  local e = t < 0.5 and 2 * t * t or 1 - (-2 * t + 2) ^ 2 / 2 -- easeInOut
  CR.draw({ def = f.def, faceUp = f.faceUp, cx = f.fromX + (f.toX - f.fromX) * e, cy = f.fromY + (f.toY - f.fromY) * e,
    cardBacks = T.game.cardBacks })
end

function V.drawTable(T)
  local tr = T.tableRect
  ui.pushClip(tr.x, tr.y, tr.w, tr.h)
  V.addItem(T, { kind = "table", x = tr.x, y = tr.y, w = tr.w, h = tr.h })
  drawCenterMarker(T)
  drawTablePiles(T)
  drawTableWidgets(T)
  drawArrows(T)
  drawRemoteGhosts(T)
  drawFlight(T)
  drawSelectionBox(T)
  ui.popClip()
end

---------------------------------------------------------------------------
-- Player panels
---------------------------------------------------------------------------

-- Fanned hand layout: cards sit on a circular arc whose pivot lies below
-- the band, each tilted along the radius like a hand held physically.
-- The shape comes from the user's hand settings (src/data/hand_settings.lua).
local FAN_LIFT_RATE = 18                 -- lift easing speed (1/s)

-- Current fan parameters, derived from the hand settings.
function V.handParams()
  local scale = handSettings.get("cardScale")
  local P = { scale = scale, cw = CW * scale, ch = CH * scale }
  P.step = P.cw * handSettings.get("spacing")          -- natural horizontal step between neighbours
  P.stepAngle = math.rad(handSettings.get("tilt"))     -- tilt between neighbours
  P.maxSpread = math.rad(handSettings.get("maxSpread")) -- total tilt from first to last card
  -- Resting cards stick out of the band over the table by `raise`; a
  -- hovered card rises until `reveal` of its height is visible.
  P.raise = handSettings.get("raise")
  local restVisible = BAND_H - 6 + P.raise
  P.lift = math.max(0, handSettings.get("reveal") * P.ch + 6 - restVisible)
  P.overhang = P.raise + P.lift            -- how far past the band a card can reach
  return P
end

function V.handScale() return handSettings.get("cardScale") end

-- Per-card offsets from the fan center: dx, dy (drop below the apex), angle.
local function fanLayout(P, count, innerW)
  if count == 1 then return { { 0, 0, 0 } } end
  local dTheta = math.min(P.stepAngle, P.maxSpread / (count - 1))
  local mid = (count + 1) / 2
  local out = {}
  if dTheta < 1e-4 then
    -- No tilt: a straight overlapping row, squeezed to fit.
    local step = math.min(P.step, math.max(0, (innerW - P.cw) / (count - 1)))
    for i = 1, count do out[i] = { (i - mid) * step, 0, 0 } end
    return out
  end
  local halfAngle = (count - mid) * dTheta
  -- Shrink the step until the fan fits, including tilted card corners and
  -- the outward slide of an outer card lifted along its tilt.
  local cornerW = P.cw / 2 * math.cos(halfAngle) + P.ch / 2 * math.sin(halfAngle)
    + P.lift * math.sin(halfAngle)
  local radius = P.step / math.sin(dTheta)
  local halfW = radius * math.sin(halfAngle) + cornerW
  if halfW > innerW / 2 then
    radius = math.max(0, (innerW / 2 - cornerW) / math.sin(halfAngle))
  end
  for i = 1, count do
    local a = (i - mid) * dTheta
    out[i] = { radius * math.sin(a), radius * (1 - math.cos(a)), a }
  end
  return out
end

local function drawHandBand(T, player, isLocal, x, y, w, rotate, fanDown)
  local bg = V.zoneBackground(T, player.id)
  ui.rect("fill", x, y, w, BAND_H, 0, bg)
  local border = V.ownerBorderColor(T, player.id)
  local P = V.handParams()
  withRotated(T, rotate, x, y, w, BAND_H, function()
    local innerX, innerW = x + 8, w - 16
    local cards, count
    if isLocal then
      cards = T.derived.localHand
      count = #cards
    else
      count = T.derived.handCount[player.id] or 0
    end
    if isLocal then
      -- Drop target: the band plus the strip of resting cards over the table.
      local ry = fanDown and y or (y - P.raise)
      if T.drawMirror then ry = 2 * T.drawMirror.cy - ry - (BAND_H + P.raise) end
      T.handRect = { x = x, y = ry, w = w, h = BAND_H + P.raise }
      T.handCardCenters = {}
    end
    if count == 0 then
      ui.text(isLocal and "Your hand is empty" or "Opponent's hand is empty", x, y,
        { w = w, h = BAND_H, valign = "middle", align = "center", color = { 1, 1, 1, 0.7 } })
      return
    end
    -- fanDown mirrors the arc vertically (pivot above the band) so a hand
    -- across the table fans toward the table while its cards stay upright.
    local sign = fanDown and -1 or 1
    local apexY = fanDown and (y + BAND_H - 6 + P.raise - P.ch / 2) or (y + 6 - P.raise + P.ch / 2)
    local centerX = innerX + innerW / 2
    local layout = fanLayout(P, count, innerW)
    local hovered = isLocal and not (T.drag and T.drag.started) and T.hoverItem
      and T.hoverItem.kind == "handCard" and T.hoverItem.card.instanceId or nil
    T.handLift = T.handLift or {}
    local k = 1 - math.exp(-FAN_LIFT_RATE * love.timer.getDelta())
    -- Clip the far edge of the band only; the table-side edge stays open
    -- so a hovered card can rise out over the table.
    local clipY = fanDown and y or (y - P.overhang)
    local clipX = innerX
    if T.drawMirror then
      clipX, clipY = 2 * T.drawMirror.cx - innerX - innerW, 2 * T.drawMirror.cy - clipY - (BAND_H + P.overhang)
    end
    ui.pushClip(clipX, clipY, innerW, BAND_H + P.overhang)
    local function drawHandCard(c, cx, cy, angle, lift)
      local id = c.instanceId
      -- Rise along the card's own up axis.
      local lx, ly = sign * lift * math.sin(angle), -sign * lift * math.cos(angle)
      CR.draw({ def = V.def(T, c), faceUp = c.faceUp, cx = cx + lx, cy = cy + ly, angle = angle, scale = P.scale,
        border = border, alpha = V.ghostAlpha(T, id), cardBacks = T.game.cardBacks })
      -- Hit box covers the resting and lifted positions so the hover
      -- does not flicker at the card's lower edge while it rises.
      local hx, hy = cx + lx / 2, cy + ly / 2
      V.addItem(T, { kind = "handCard", card = c, hoverId = id, angle = angle,
        cx = hx, cy = hy, hw = P.cw / 2, hh = P.ch / 2 + lift / 2, scale = P.scale,
        x = hx - P.cw / 2, y = hy - P.ch / 2 - lift / 2, w = P.cw, h = P.ch + lift,
        cardCx = cx + lx, cardCy = cy + ly })
    end
    for i = 1, count do
      local dx, dy, a = layout[i][1], layout[i][2], layout[i][3]
      local cx = centerX + dx
      local cy = apexY + sign * dy
      local angle = sign * a
      if isLocal then
        local c = cards[i]
        local id = c.instanceId
        local lift = (T.handLift[id] or 0) + ((id == hovered and P.lift or 0) - (T.handLift[id] or 0)) * k
        T.handLift[id] = lift
        -- Screen-space center (mirrored when the band is rotated).
        local scx = T.drawMirror and (2 * T.drawMirror.cx - cx) or cx
        T.handCardCenters[#T.handCardCenters + 1] = { id = id, cx = scx }
        -- Drawn and hit-tested in hand order even while lifted, so the
        -- cards to its right stay on top and remain selectable.
        drawHandCard(c, cx, cy, angle, lift)
      else
        CR.draw({ def = nil, faceUp = false, cx = cx, cy = cy, angle = angle, scale = P.scale, border = border, cardBacks = T.game.cardBacks })
      end
    end
    ui.popClip()
  end)
end

local function drawZoneSlot(T, player, zone, isLocal, x, y, rotate)
  local bg = V.zoneBackground(T, player.id)
  ui.rect("fill", x, y, SLOT_W, SLOT_H, 0, bg)
  withRotated(T, rotate, x, y, SLOT_W, SLOT_H, function()
    local cx, cy = x + SLOT_W / 2, y + SLOT_H / 2
    if zone.kind == "widget" then
      local w = T.derived.widgetFor[player.id] and T.derived.widgetFor[player.id][zone.id]
      if w then
        counterFace(w, cx - 40, cy - 40, 80, 1)
        V.addItem(T, { kind = "dockedCounter", widget = w, zone = zone, x = cx - 40, y = cy - 40, w = 80, h = 80,
          interactable = isLocal and not T.tabDown, tooltip = zone.name })
      end
      return
    end
    local cards = T.derived.zoneCards[player.id] and T.derived.zoneCards[player.id][zone.id] or {}
    local top = #cards > 0 and stacks.topOf(cards) or nil
    local border = V.ownerBorderColor(T, player.id)
    drawPileBox(T, {
      cx = cx, cy = cy, count = #cards, def = top and V.def(T, top), faceUp = top and top.faceUp,
      border = border, alpha = top and V.ghostAlpha(T, top.instanceId) or 1, wiggleKey = "zone:" .. player.id .. ":" .. zone.id,
      searched = T:isZoneSearched(zone.id, player.id),
      shuffle = (isLocal and #cards > 0 and zone.shuffleable)
        and { key = "zone:" .. player.id .. ":" .. zone.id, onClick = function() T:shuffleZone(zone.id, "zone:" .. player.id .. ":" .. zone.id) end } or nil,
    })
    if isLocal then
      addDropZone(T, zone.id, x, y, SLOT_W, SLOT_H)
      table.insert(T.items, #T.items - ((#cards > 0 and zone.shuffleable) and 1 or 0) + 1, {
        kind = "zone", zoneId = zone.id, zone = zone, top = top, cards = cards, hoverId = top and top.instanceId,
        x = x, y = y, w = SLOT_W, h = SLOT_H, tooltip = zone.name, interactable = true, mirror = T.drawMirror,
      })
    else
      V.addItem(T, { kind = "tooltip", x = x + 8, y = y + 8, w = SLOT_W - 16, h = SLOT_H - 16, tooltip = zone.name })
    end
  end)
end

local function drawAvatarCorner(T, player, x, y)
  local session = T.session
  local bg = V.zoneBackground(T, player.id)
  ui.rect("fill", x, y, SLOT_W, SLOT_H, 0, bg)
  local isPractice = session.isLocalPractice
  local isActive = player.id == session:actingPlayerId()
  local isLocal = player.id == session.localPlayerId
  local showReal = (isPractice and isActive) or (not isPractice and isLocal)
  local alpha = player.connected and 1 or 0.5
  local nameF = theme.font(10)
  local contentH = CW + 4 + nameF:getHeight()
  local ay = y + 8 + (CH + EXTRA - contentH) / 2
  local ax = x + (SLOT_W - CW) / 2
  local source
  if showReal and T.localAvatarPath then
    source = { path = T.localAvatarPath }
  elseif not showReal and T.avatarKeys and T.avatarKeys[player.id] then
    source = { key = T.avatarKeys[player.id] }
  end
  love.graphics.push("all")
  local widgets = require("src.ui.kit.widgets")
  widgets.avatar(ax, ay, CW, player.color, source, (not isPractice) or isActive)
  love.graphics.pop()
  if alpha < 1 then
    love.graphics.setColor(0, 0, 0, 0.5)
    love.graphics.rectangle("fill", ax, ay, CW, CW)
  end
  local name = player.connected and player.name or (player.name .. " (disconnected)")
  ui.text(ui.ellipsize(name, nameF, SLOT_W - 16), x + 8, ay + CW + 4, { font = nameF, w = SLOT_W - 16, align = "center", color = { 1, 1, 1, 0.7 * alpha } })
  if isPractice then
    V.addItem(T, { kind = "avatar", player = player, x = ax, y = ay, w = CW, h = CW, tooltip = player.name })
  end
end

local function drawPlayerRow(T, rowPlayers, isTopRow, x, y, w)
  if #rowPlayers == 0 then return end
  local n = #rowPlayers
  local panelW = (w - 12 * (n - 1)) / n
  local ownedZones = T.derived.ownedZones
  for i, player in ipairs(rowPlayers) do
    local px = x + (i - 1) * (panelW + 12)
    local isLocal = player.id == T.session:actingPlayerId()
    local rotate = isTopRow and #T.state.players > 2 and player.id ~= T.session.localPlayerId
    local reverse = (n == 2 and i == 1) or (isTopRow and n == 1 and not rotate)
    local zones = {}
    for _, z in ipairs(ownedZones) do zones[#zones + 1] = z end
    if reverse then
      local r = {}
      for k = #zones, 1, -1 do r[#r + 1] = zones[k] end
      zones = r
    end
    local handW = math.max(0, panelW - (#zones + 1) * SLOT_W)
    local cx = px
    -- An unrotated hand in the top row faces the table, so its fan opens downward.
    local fanDown = isTopRow and not rotate
    local function hand() drawHandBand(T, player, isLocal, cx, y, handW, rotate, fanDown); cx = cx + handW end
    local function zoneSlots()
      for _, z in ipairs(zones) do
        drawZoneSlot(T, player, z, isLocal, cx, y, rotate)
        cx = cx + SLOT_W
      end
    end
    local function avatar() drawAvatarCorner(T, player, cx, y); cx = cx + SLOT_W end
    if reverse then
      avatar(); zoneSlots(); hand()
    else
      hand(); zoneSlots(); avatar()
    end
  end
end

local function drawSidebar(T, side, x, y, h)
  local zones = {}
  for _, z in ipairs(T.derived.sharedZones) do
    if z.side == side then zones[#zones + 1] = z end
  end
  if #zones == 0 then return end
  ui.rect("fill", x, y, SLOT_W, h, 0, theme.fixed.black)
  local total = #zones * SLOT_H + (#zones - 1) * 12
  local yy = y + math.max(12, (h - total) / 2)
  for _, zone in ipairs(zones) do
    local cards = T.derived.cardsByZoneId[zone.id] or {}
    -- Shared zone cards are unowned; only those count as the shared pile.
    local top = #cards > 0 and stacks.topOf(cards) or nil
    ui.rect("fill", x, yy, SLOT_W, SLOT_H, 0, theme.fixed.black)
    local key = "shared:" .. zone.id
    drawPileBox(T, { cx = x + SLOT_W / 2, cy = yy + SLOT_H / 2, count = #cards, def = top and V.def(T, top),
      faceUp = top and top.faceUp, alpha = top and V.ghostAlpha(T, top.instanceId) or 1, wiggleKey = key,
      searched = T:isZoneSearched(zone.id, nil),
      shuffle = (#cards > 0 and zone.shuffleable) and { key = key, onClick = function() T:shuffleZone(zone.id, key) end } or nil })
    addDropZone(T, zone.id, x, yy, SLOT_W, SLOT_H)
    table.insert(T.items, #T.items - ((#cards > 0 and zone.shuffleable) and 1 or 0) + 1, {
      kind = "zone", zoneId = zone.id, zone = zone, top = top, cards = cards, hoverId = top and top.instanceId,
      x = x, y = yy, w = SLOT_W, h = SLOT_H, tooltip = zone.name, interactable = true, shared = true,
    })
    yy = yy + SLOT_H + 12
  end
end

---------------------------------------------------------------------------
-- Whole screen
---------------------------------------------------------------------------

-- Computes rects for this frame.
function V.layout(T, x, y, w, h)
  local D = T.derived
  local hasLeft, hasRight = false, false
  for _, z in ipairs(D.sharedZones) do
    if z.side == "left" then hasLeft = true else hasRight = true end
  end
  local midX = x + (hasLeft and SLOT_W or 0)
  local midW = w - (hasLeft and SLOT_W or 0) - (hasRight and SLOT_W or 0)
  local topH = #D.rows.topRow > 0 and BAND_H or 0
  local botH = #D.rows.bottomRow > 0 and BAND_H or 0
  T.layoutRects = {
    left = hasLeft and { x = x, y = y, h = h } or nil,
    right = hasRight and { x = x + w - SLOT_W, y = y, h = h } or nil,
    top = { x = midX, y = y, w = midW },
    bottom = { x = midX, y = y + h - botH, w = midW },
  }
  T.tableRect = { x = midX, y = y + topH, w = midW, h = h - topH - botH }
end

function V.draw(T, x, y, w, h)
  T.items, T.dropZones, T.handRect, T.handCardCenters = {}, {}, nil, {}
  V.layout(T, x, y, w, h)
  ui.rect("fill", x, y, w, h, 0, T:feltColor())
  V.drawTable(T)
  local L = T.layoutRects
  drawPlayerRow(T, T.derived.rows.topRow, true, L.top.x, L.top.y, L.top.w)
  drawPlayerRow(T, T.derived.rows.bottomRow, false, L.bottom.x, L.bottom.y, L.bottom.w)
  if L.left then drawSidebar(T, "left", L.left.x, L.left.y, L.left.h) end
  if L.right then drawSidebar(T, "right", L.right.x, L.right.y, L.right.h) end
end

return V
