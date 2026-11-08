-- Playmat editor: define playmat images and whether the game uses one
-- shared centerpiece mat or individual per-player mats. Laid out as a mode
-- switch above a list + detail split (mirrors zones_tab.lua), with a table
-- preview (mirrors scenario_tab.lua's Card Placement canvas) in the detail
-- pane showing the selected playmat's size at its authored scale, plus a
-- draggable reference card for scale comparison.
--
-- src/ui/table/table_screen.lua resolves game.playmats/playmatType at
-- runtime: F11 toggles on/off, F12 cycles through them.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local widgets = require("src.ui.kit.widgets")
local models = require("src.core.models")
local util = require("src.core.util")
local common = require("src.ui.screens.gamedef.common")
local listDetail = require("src.ui.kit.list_detail")
local fs = require("src.data.fs")
local tableSettings = require("src.data.table_settings")
local color = require("src.core.color")
local geometry = require("src.core.geometry")
local imageCache = require("src.data.image_cache")
local CR = require("src.ui.table.card_render")

local keyOf = common.keyOf

local T = {}
T.__index = T

function T.new(editor)
  -- cardFx/cardFy: the draggable reference card's position in the preview,
  -- normalized [0,1] canvas-relative -- ephemeral UI state, never saved.
  return setmetatable({ editor = editor, cardFx = 0.5, cardFy = 0.72 }, T)
end

local MODE_OPTIONS = { { value = "shared", label = "Shared" }, { value = "individual", label = "Individual" } }
local LIST_W = 300
local ROW_H = 56
local MODE_BAR_H = 64

-- A standard playing card, purely as a fixed size reference -- independent
-- of whatever game is being edited (matches the live table's card size).
local REFERENCE_CARD = { cardTitle = "A", suit = "hearts", colorHex = "#D32F2F" }

-- Base (unscaled) mat sizes, mirrored from table_view.lua's SINGLE_MARKER_W/H
-- and PLAYMAT_W/H.
local PX_PER_INCH = CR.cardWidth / 2.5
local SHARED_W, SHARED_H = 1280, 720
local INDIVIDUAL_W, INDIVIDUAL_H = 24 * PX_PER_INCH, 12 * PX_PER_INCH

---------------------------------------------------------------------------
-- List
---------------------------------------------------------------------------

function T:drawList(x, y, w, h)
  local c = theme.c
  local game = self.editor.game
  local hh, add = common.sectionHeader("pt:list", "Playmats", x + 16, y + 12, w - 32, {
    count = #game.playmats, action = { label = "Add Playmat", icon = "add", id = "pt:add" } })
  if add then
    common.choosePlaymatImage(self.editor.folderPath, function(file)
      local pm = models.PlaymatDefinition.new({ imagePath = file })
      game.playmats[#game.playmats + 1] = pm
      self.selected = pm
    end)
  end
  local ly = y + 12 + hh + 8
  local lh = y + h - ly
  local off = ui.beginScroll("pt:list", x, ly, w, lh)
  local ro = widgets.reorder("pt:playmats")
  local yy = ly - off
  local THUMB = 40
  for i, pm in ipairs(game.playmats) do
    local rx, rw = x + 8, w - 16
    local sel = pm == self.selected
    local r = ui.region("pt:row:" .. keyOf(pm), rx + 40, yy, rw - 40, ROW_H, { cursor = "hand" })
    if sel then
      ui.rect("fill", rx, yy, rw, ROW_H, 8, c.secondaryContainer)
    elseif r.hovered then
      ui.rect("fill", rx, yy, rw, ROW_H, 8, theme.alpha(c.onSurface, 0.05))
    end
    ro:handle(i, rx, yy + (ROW_H - 40) / 2, yy, ROW_H)
    common.imagePreviewBox(pm.imagePath and fs.join(self.editor.folderPath, "_playmats", pm.imagePath),
      rx + 42, yy + (ROW_H - THUMB) / 2, THUMB, THUMB)
    local fg = sel and c.onSecondaryContainer or c.onSurface
    local tx = rx + 42 + THUMB + 12
    ui.text(pm.imagePath or "(no image)", tx, yy + 9, { w = rx + rw - 8 - tx, ellipsis = true,
      weight = sel and "medium" or nil, color = fg })
    ui.text(math.floor((pm.scale or 1) * 100 + 0.5) .. "%", tx, yy + 30,
      { w = rx + rw - 8 - tx, ellipsis = true, size = 12, color = c.onSurfaceVariant })
    if r.clicked then
      self.selected = pm
      ui.blur()
    end
    yy = yy + ROW_H + 2
  end
  local from, to = ro:finish(x + 8, w - 16)
  if from then widgets.moveItem(game.playmats, from, to) end
  ui.endScroll("pt:list", #game.playmats * (ROW_H + 2) + 12)
end

---------------------------------------------------------------------------
-- Table preview
---------------------------------------------------------------------------

local function canvasRect(x, y, w, h)
  local scale = math.min(w / geometry.worldWidth, h / geometry.worldHeight)
  local cw, ch = geometry.worldWidth * scale, geometry.worldHeight * scale
  return x + (w - cw) / 2, y + (h - ch) / 2, cw, ch, scale
end

-- A playmat's native size is its own image's pixel dimensions at 100% scale
-- (mirrors table_view.lua's playmatSize) -- falls back to fallbackW/H while
-- the image hasn't loaded yet, or when there's no image chosen.
local function playmatSize(matPath, scale, fallbackW, fallbackH)
  local img = matPath and imageCache.get(matPath)
  if img then
    local iw, ih = img:getDimensions()
    return iw * scale, ih * scale
  end
  return fallbackW * scale, fallbackH * scale
end

-- Shows the selected playmat's size on a letterboxed table canvas (centered
-- for "shared", near the viewer's own edge for "individual" -- just one
-- representative mat, not the full per-seat layout), plus a draggable
-- reference card for scale comparison.
function T:drawTablePreview(pm, x, y, w, h)
  local game = self.editor.game
  local folder = self.editor.folderPath
  local cx, cy, cw, ch, scale = canvasRect(x, y, w, h)
  ui.rect("fill", cx, cy, cw, ch, 0, { color.toRgba(tableSettings.feltColor(game.tableColor)) })
  ui.rect("line", cx + 1, cy + 1, cw - 2, ch - 2, 0,
    { color.toRgba(tableSettings.playmatBorderColor(game.playmatBorderColor)) })

  local matScale = pm.scale or 1.0
  local matPath = pm.imagePath and fs.join(folder, "_playmats", pm.imagePath)
  local matW, matH, matLeft, matTop
  if game.playmatType == "shared" then
    matW, matH = playmatSize(matPath, matScale, SHARED_W, SHARED_H)
    matLeft, matTop = (geometry.worldWidth - matW) / 2, (geometry.worldHeight - matH) / 2
  else
    matW, matH = playmatSize(matPath, matScale, INDIVIDUAL_W, INDIVIDUAL_H)
    matLeft = (geometry.worldWidth - matW) / 2
    matTop = geometry.worldHeight - matH - 0.12 * geometry.worldHeight
  end
  local mx, my, mw, mh = cx + matLeft * scale, cy + matTop * scale, matW * scale, matH * scale
  local r = 16
  if matPath then
    local img = imageCache.get(matPath)
    if img then
      love.graphics.stencil(function() love.graphics.rectangle("fill", mx, my, mw, mh, r, r) end, "replace", 1)
      love.graphics.setStencilTest("greater", 0)
      local iw, ih = img:getDimensions()
      local s = math.max(mw / iw, mh / ih)
      love.graphics.setColor(1, 1, 1, 0.5)
      love.graphics.draw(img, mx + (mw - iw * s) / 2, my + (mh - ih * s) / 2, 0, s, s)
      love.graphics.setStencilTest()
    end
  end
  love.graphics.setColor(color.toRgba(tableSettings.playmatBorderColor(game.playmatBorderColor)))
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", mx + 1, my + 1, mw - 2, mh - 2, r, r)
  love.graphics.setLineWidth(1)

  -- Draggable reference card.
  local cardW, cardH = CR.cardWidth * scale, CR.cardHeight * scale
  local ccx, ccy = cx + self.cardFx * cw, cy + self.cardFy * ch
  local cr = ui.region("pt:refcard", ccx - cardW / 2, ccy - cardH / 2, cardW, cardH, { cursor = "hand" })
  if cr.held then
    local mxp, myp = ui.mouse()
    local hwF, hhF = (cardW / 2) / cw, (cardH / 2) / ch
    self.cardFx = util.clamp((mxp - cx) / cw, hwF, 1 - hwF)
    self.cardFy = util.clamp((myp - cy) / ch, hhF, 1 - hhF)
    ccx, ccy = cx + self.cardFx * cw, cy + self.cardFy * ch
  end
  CR.draw({ def = REFERENCE_CARD, faceUp = true, cx = ccx, cy = ccy, scale = scale })

  return h
end

---------------------------------------------------------------------------
-- Detail
---------------------------------------------------------------------------

-- No scroll wrapper here (unlike zones_tab/other tabs): the preview below
-- is meant to fill whatever space is left, not be one more item in a
-- scrolling list, so the header controls above it stay fixed instead.
function T:drawDetail(pm, x, y, w, h)
  local k = "pt:" .. keyOf(pm)
  local folder = self.editor.folderPath
  local cx, cw = common.column(x, w)
  local yy = y + common.PAD

  local THUMB = 64
  common.imagePreviewBox(pm.imagePath and fs.join(folder, "_playmats", pm.imagePath), cx, yy, THUMB, THUMB)
  local chooseW = ui.buttonWidth("Choose Image...")
  local delW = ui.buttonWidth("Delete Playmat", { icon = "delete_outline" })
  if ui.button("Choose Image...", cx + THUMB + 12, yy, chooseW, 40, { variant = "outlined", id = k .. ":choose" }) then
    common.choosePlaymatImage(folder, function(file) pm.imagePath = file end)
  end
  if ui.button("Delete Playmat", cx + cw - delW, yy, delW, 40,
    { variant = "text", icon = "delete_outline", id = k .. ":del" }) then
    self.pendingRemove = pm
  end
  yy = yy + THUMB + 16

  pm.scale = ui.sliderRow(k .. ":scale", "Scale", cx, yy, math.min(cw, 400), pm.scale or 1.0, 0.10, 2.00,
    { step = 0.01, format = function(v) return math.floor(v * 100 + 0.5) .. "%" end })
  yy = yy + 64 + 16

  common.groupLabel("Table Preview", cx, yy, cw)
  yy = yy + 24

  -- The preview spans the full detail pane width (not the capped text
  -- column) and fills all remaining height down to the bottom gutter.
  local previewH = math.max(100, y + h - common.PAD - yy)
  self:drawTablePreview(pm, x + common.PAD, yy, w - 2 * common.PAD, previewH)
end

---------------------------------------------------------------------------
-- Tab
---------------------------------------------------------------------------

function T:draw(x, y, w, h)
  local game = self.editor.game
  local c = theme.c
  ui.rect("fill", x, y, w, MODE_BAR_H, 0, c.surfaceContainer)
  ui.text("Playmat Type", x + 16, y + 10, { size = 12, weight = "medium", color = c.onSurfaceVariant })
  game.playmatType = ui.segmented("pt:mode", x + 16, y + 28, 280, MODE_OPTIONS, game.playmatType)
  ui.rect("fill", x, y + MODE_BAR_H, w, 1, 0, c.outlineVariant)

  self.pendingRemove = nil
  listDetail.draw(self, x, y + MODE_BAR_H + 1, w, h - MODE_BAR_H - 1, game.playmats, LIST_W, T.drawList, T.drawDetail,
    "Add a playmat to get started")
  if self.pendingRemove then
    local i
    for j, p in ipairs(game.playmats) do if p == self.pendingRemove then i = j end end
    util.removeValue(game.playmats, self.pendingRemove)
    self.selected = i and game.playmats[math.min(i, #game.playmats)] or nil
  end
end

return T
