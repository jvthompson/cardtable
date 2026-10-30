-- Card drawing: ports of card_face_widget.dart and card_back_widget.dart.
-- Cards are drawn at their base size (70x100) under a transform, so callers
-- position by center with a scale and rotation.
local theme = require("src.ui.kit.theme")
local color = require("src.core.color")
local imageCache = require("src.data.image_cache")
local resolver = require("src.data.image_resolver")

local R = {}

R.cardWidth = 70
R.cardHeight = 100
R.radius = 3.5
R.pileExtra = 24

local W, H, RAD = R.cardWidth, R.cardHeight, R.radius

local SUIT_GLYPHS = { hearts = "♥", diamonds = "♦", clubs = "♣", spades = "♠" }
local DEFAULT_COLOR = "#9E9E9E"

function R.orientationTurns(o)
  if o == "right" then return 0.25 end
  if o == "left" then return -0.25 end
  return 0
end

-- Rounded-corner image shader: discards pixels outside a rounded rect in
-- the quad's own coordinate space.
local shader
local function roundedShader()
  if shader == nil then
    local ok, s = pcall(love.graphics.newShader, [[
      extern vec4 quadRect;   // u0, v0, u1, v1
      extern vec2 size;       // destination size in base pixels
      extern float radius;
      vec4 effect(vec4 col, Image tex, vec2 tc, vec2 sc) {
        vec2 uv = (tc - quadRect.xy) / (quadRect.zw - quadRect.xy);
        vec2 p = uv * size;
        vec2 q = min(p, size - p);
        if (q.x < radius && q.y < radius && distance(q, vec2(radius)) > radius) discard;
        return Texel(tex, tc) * col;
      }
    ]])
    shader = ok and s or false
  end
  return shader or nil
end

-- Sets the rounded-corner shader for drawing an image (or the quadRect
-- part of it, in UVs) into a w x h destination. Returns false when shaders
-- are unavailable; otherwise the caller resets with setShader().
function R.setRoundedShader(quadRect, w, h, radius)
  local sh = roundedShader()
  if not sh then return false end
  love.graphics.setShader(sh)
  sh:send("quadRect", quadRect)
  sh:send("size", { w, h })
  sh:send("radius", radius)
  return true
end

-- Corner radius for a card image displayed with the given short side, so
-- it matches the drawn cards' proportions at any size.
function R.radiusFor(shortSide)
  return RAD / W * shortSide
end

-- Draws `img` cover-fit into the base card rect with rounded corners.
local function drawImageCover(img)
  local iw, ih = img:getDimensions()
  local target = W / H
  local qw, qh
  if iw / ih > target then
    qh = ih
    qw = ih * target
  else
    qw = iw
    qh = iw / target
  end
  local qx, qy = (iw - qw) / 2, (ih - qh) / 2
  local quad = R._quad or love.graphics.newQuad(0, 0, 1, 1, 1, 1)
  R._quad = quad
  quad:setViewport(qx, qy, qw, qh, iw, ih)
  local rounded = R.setRoundedShader({ qx / iw, qy / ih, (qx + qw) / iw, (qy + qh) / ih }, W, H, RAD)
  love.graphics.draw(img, quad, 0, 0, 0, W / qw, H / qh)
  if rounded then love.graphics.setShader() end
end

local function shadow(alpha)
  love.graphics.setColor(0, 0, 0, 0.18 * alpha)
  love.graphics.rectangle("fill", 0.5, 1.5, W + 1, H + 1, RAD + 1, RAD + 1)
  love.graphics.setColor(0, 0, 0, 0.22 * alpha)
  love.graphics.rectangle("fill", 1, 1, W, H, RAD, RAD)
end

local function thinBorder(alpha)
  love.graphics.setColor(0, 0, 0, 0.26 * alpha)
  love.graphics.setLineWidth(1)
  love.graphics.rectangle("line", 0.5, 0.5, W - 1, H - 1, RAD, RAD)
end

-- Text is drawn under a scaling transform; to stay crisp it uses a font
-- sized for the current scale (quantized to quarter steps so font objects
-- get reused) and undoes that factor in the print call.
local textScale = 1

local function scaledPrint(text, size, weight, x, y, ox, oy, extraScale)
  local q = textScale
  local f = theme.font(size * q, weight)
  love.graphics.setFont(f)
  local s = (extraScale or 1) / q
  love.graphics.print(text, x, y, 0, s, s, (ox or 0) * q, (oy or 0) * q)
  return f, q
end

local function corner(def, col, glyph, alpha)
  love.graphics.setColor(col[1], col[2], col[3], alpha)
  scaledPrint(def.cardTitle, 15, "bold", 0, 0)
  if glyph then scaledPrint(glyph, 13, nil, 0, 15) end
end

-- Code-drawn face (no image, or the image failed to load).
local function codeDrawnFace(def, alpha)
  shadow(alpha)
  love.graphics.setColor(1, 1, 1, alpha)
  love.graphics.rectangle("fill", 0, 0, W, H, RAD, RAD)
  thinBorder(alpha)
  local col = { color.parseHexRgb(def.colorHex or DEFAULT_COLOR) }
  if not col[1] then col = { color.parseHexRgb(DEFAULT_COLOR) } end
  local glyph = def.suit and SUIT_GLYPHS[def.suit:lower()]
  -- Clip the text to the card's padded interior.
  love.graphics.push()
  love.graphics.translate(4, 4)
  corner(def, col, glyph, alpha)
  love.graphics.pop()
  local centerText = glyph or def.cardTitle
  local size = glyph and 34 or 22
  local base = theme.font(size, "bold")
  love.graphics.setColor(col[1], col[2], col[3], alpha)
  local tw = base:getWidth(centerText)
  local fit = math.min(1, (W - 8) / math.max(1, tw))
  scaledPrint(centerText, size, "bold", W / 2, H / 2, tw / 2, base:getHeight() / 2, fit)
  love.graphics.push()
  love.graphics.translate(W - 4, H - 4)
  love.graphics.rotate(math.pi)
  corner(def, col, glyph, alpha)
  love.graphics.pop()
end

local function codeDrawnBack(alpha)
  shadow(alpha)
  love.graphics.setColor(0x15 / 255, 0x65 / 255, 0xC0 / 255, alpha)
  love.graphics.rectangle("fill", 0, 0, W, H, RAD, RAD)
  thinBorder(alpha)
  -- Inner frame (white24, 2px) at 6px padding with a crosshatch + diamond.
  local ix, iy, iw, ih = 6, 6, W - 12, H - 12
  love.graphics.setColor(1, 1, 1, 0.12 * alpha)
  love.graphics.setLineWidth(1)
  local step = 8
  -- Crosshatch clipped by computing segment ends against the inner rect.
  for x = -ih, iw, step do
    local x1, y1, x2, y2 = x, 0, x + ih, ih
    if x1 < 0 then y1, x1 = -x1, 0 end
    if x2 > iw then y2, x2 = ih - (x2 - iw), iw end
    if y2 > y1 then love.graphics.line(ix + x1, iy + y1, ix + x2, iy + y2) end
    local a1, b1, a2, b2 = x + ih, 0, x, ih
    if a1 > iw then b1, a1 = a1 - iw, iw end
    if a2 < 0 then b2, a2 = ih + a2, 0 end
    if b2 > b1 then love.graphics.line(ix + a1, iy + b1, ix + a2, iy + b2) end
  end
  love.graphics.setColor(1, 1, 1, 0.24 * alpha)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", ix, iy, iw, ih, 3, 3)
  love.graphics.setColor(1, 1, 1, 0.35 * alpha)
  love.graphics.setLineWidth(1.5)
  local cx, cy, r = W / 2, H / 2, math.min(iw, ih) * 0.22
  love.graphics.polygon("line", cx, cy - r, cx + r, cy, cx, cy + r, cx - r, cy)
  love.graphics.setLineWidth(1)
end

local function missingBack(alpha)
  shadow(alpha)
  love.graphics.setColor(0xB7 / 255, 0x1C / 255, 0x1C / 255, alpha)
  love.graphics.rectangle("fill", 0, 0, W, H, RAD, RAD)
  thinBorder(alpha)
  local f = theme.iconFont(32)
  love.graphics.setFont(f)
  love.graphics.setColor(1, 1, 1, alpha)
  local g = theme.glyph("warning_amber")
  love.graphics.print(g, (W - f:getWidth(g)) / 2, (H - f:getHeight()) / 2)
end

local function imageFace(path, alpha, fallback)
  local img = imageCache.get(path)
  if img then
    shadow(alpha)
    love.graphics.setColor(1, 1, 1, alpha)
    drawImageCover(img)
    thinBorder(alpha)
    return
  end
  if imageCache.status(path) == "loading" then
    -- Placeholder while decoding.
    shadow(alpha)
    love.graphics.setColor(0.85, 0.85, 0.85, alpha)
    love.graphics.rectangle("fill", 0, 0, W, H, RAD, RAD)
    thinBorder(alpha)
    return
  end
  fallback(alpha)
end

-- Draws the face (in base coordinates; caller sets up the transform).
function R.drawFaceBase(def, alpha)
  alpha = alpha or 1
  if def.imagePath then
    imageFace(def.imagePath, alpha, function(a) codeDrawnFace(def, a) end)
  else
    codeDrawnFace(def, alpha)
  end
end

function R.drawBackBase(cardBacks, def, alpha, scenarioCardBackId)
  alpha = alpha or 1
  local path, missing = resolver.resolveCardBackImagePath(cardBacks or {}, def, scenarioCardBackId)
  if missing then return missingBack(alpha) end
  if not path then return codeDrawnBack(alpha) end
  imageFace(path, alpha, codeDrawnBack)
end

-- Which way the shown side of a card is oriented (card or its back).
function R.shownOrientation(def, showingBack, cardBacks, scenarioCardBackId)
  if showingBack then
    local _, _, o = resolver.resolveCardBackImagePath(cardBacks or {}, def, scenarioCardBackId)
    return o
  end
  return def and def.orientation or "portrait"
end

-- Full card draw.
-- opts: def (CardDefinition or nil), faceUp, cx, cy (screen center), scale,
--       angle (radians), border (rgba color table or nil), alpha, cardBacks,
--       scenarioCardBackId, forceFaceUp, tint (rgba laid over the card, e.g.
--       the selection color)
function R.draw(opts)
  local scale = opts.scale or 1
  local alpha = opts.alpha or 1
  local def = opts.def
  local showFace = (opts.faceUp or opts.forceFaceUp) and def ~= nil
  love.graphics.push()
  love.graphics.translate(opts.cx, opts.cy)
  if opts.angle and opts.angle ~= 0 then love.graphics.rotate(opts.angle) end
  love.graphics.scale(scale, scale)
  textScale = math.max(0.5, math.floor(scale * 4 + 0.5) / 4)
  love.graphics.translate(-W / 2, -H / 2)
  if showFace then R.drawFaceBase(def, alpha) else R.drawBackBase(opts.cardBacks, def, alpha, opts.scenarioCardBackId) end
  if opts.tint then
    love.graphics.setColor(opts.tint[1], opts.tint[2], opts.tint[3], (opts.tint[4] or 1) * alpha)
    love.graphics.rectangle("fill", 0, 0, W, H, RAD, RAD)
  end
  if opts.border then
    love.graphics.setColor(opts.border[1], opts.border[2], opts.border[3], (opts.border[4] or 1) * alpha)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", 1, 1, W - 2, H - 2, RAD, RAD)
    love.graphics.setLineWidth(1)
  end
  love.graphics.pop()
end

-- Empty zone outline (EmptyZoneBox): a card-sized white24 rounded outline.
function R.drawEmptySlot(cx, cy, scale)
  scale = scale or 1
  love.graphics.setColor(1, 1, 1, 0.24)
  love.graphics.setLineWidth(1.5 * scale)
  love.graphics.rectangle("line", cx - W * scale / 2, cy - H * scale / 2, W * scale, H * scale, RAD * scale, RAD * scale)
  love.graphics.setLineWidth(1)
end

-- Count badge: black87 circle (r=12) with the count, at (cx, cy).
function R.drawCountBadge(cx, cy, count, scale)
  scale = scale or 1
  love.graphics.setColor(0, 0, 0, 0.87)
  love.graphics.circle("fill", cx, cy, 12 * scale)
  local f = theme.font(11)
  love.graphics.setFont(f)
  love.graphics.setColor(1, 1, 1)
  local t = tostring(count)
  love.graphics.print(t, cx, cy, 0, scale, scale, f:getWidth(t) / 2, f:getHeight() / 2)
end

-- Search eye badge (48px black54 circle).
function R.drawSearchBadge(cx, cy, scale)
  scale = scale or 1
  love.graphics.setColor(0, 0, 0, 0.54)
  love.graphics.circle("fill", cx, cy, 24 * scale)
  local f = theme.iconFont(32)
  love.graphics.setFont(f)
  love.graphics.setColor(1, 1, 1)
  local g = theme.glyph("visibility")
  love.graphics.print(g, cx, cy, 0, scale, scale, f:getWidth(g) / 2, f:getHeight() / 2)
end

-- Preview faces for a card definition as browsed in a list: its front, then
-- its back when it has its own (explicit, or a scenario card's configured default).
function R.definitionFaces(def, cardBacks, scenarioCardBackId)
  local faces = { { def = def, faceUp = true, orientation = def.orientation } }
  if def.cardBackId ~= nil or (def.isScenarioCard and scenarioCardBackId ~= nil) then
    local _, _, backOrientation = resolver.resolveCardBackImagePath(cardBacks, def, scenarioCardBackId)
    faces[2] = { def = def, faceUp = false, orientation = backOrientation or "portrait" }
  end
  return faces
end

-- Hover preview (table_screen.dart _previewGeometry): big copies of the
-- faces ({ def, faceUp, orientation } each), stacked top to bottom and
-- centered in the half of the (sw x sh) screen away from mouse x mx. One
-- face is 70% of the screen tall, a stack 90%; at most 42% wide either way.
local PREVIEW_GAP = 16
function R.drawPreview(faces, cardBacks, sw, sh, mx, scenarioCardBackId)
  local boxes, stackH, maxW = {}, 0, 0
  for i, f in ipairs(faces) do
    local rotated = f.orientation ~= "portrait"
    local bw, bh = rotated and H or W, rotated and W or H
    boxes[i] = { bw = bw, bh = bh }
    stackH, maxW = stackH + bh, math.max(maxW, bw)
  end
  local gaps = PREVIEW_GAP * (#faces - 1)
  local heightFrac = #faces == 1 and 0.7 or 0.9
  local s = math.min((sh * heightFrac - gaps) / stackH, sw * 0.42 / maxW)
  local pw, ph = maxW * s, stackH * s + gaps
  local targetX = mx < sw / 2 and sw * 0.75 or sw * 0.25
  local left = math.max(0, math.min(targetX - pw / 2, sw - pw))
  local y = math.max(0, math.min(sh / 2 - ph / 2, sh - ph))
  for i, f in ipairs(faces) do
    local bh = boxes[i].bh * s
    R.draw({ def = f.def, faceUp = f.faceUp, cx = left + pw / 2, cy = y + bh / 2, scale = s,
      angle = R.orientationTurns(f.orientation) * 2 * math.pi, cardBacks = cardBacks, scenarioCardBackId = scenarioCardBackId })
    y = y + bh + PREVIEW_GAP
  end
end

return R
