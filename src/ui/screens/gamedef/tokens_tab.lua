-- The Tokens tab: a reorderable list of named token images (list + detail,
-- like zones_tab.lua) backed by game.tokens. A token's name may carry a
-- "|Type" suffix (e.g. "Daisy Walker|Investigator") that groups it for the
-- Token Widget's type filter at the table -- see models.TokenDefinition.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local widgets = require("src.ui.kit.widgets")
local overlays = require("src.ui.kit.overlays")
local models = require("src.core.models")
local util = require("src.core.util")
local uuid = require("src.core.uuid")
local common = require("src.ui.screens.gamedef.common")
local listDetail = require("src.ui.kit.list_detail")
local fs = require("src.data.fs")

local keyOf = common.keyOf

local T = {}
T.__index = T

function T.new(editor)
  return setmetatable({ editor = editor }, T)
end

local LIST_W = 300
local ROW_H = 56
local THUMB = 40
local BTN_H = 36

---------------------------------------------------------------------------
-- List
---------------------------------------------------------------------------

-- Scans <folderPath>/tokens recursively and adds a token for every image
-- not already referenced by an existing token's imagePath. A file found
-- one subfolder down is named "<file>|<subfolder>" so that subfolder
-- becomes its type (see models.TokenDefinition.typeOf); deeper nesting
-- uses the file's immediate containing folder. Never touches tokens that
-- already exist, so running it again only picks up new images.
function T:autoAddTokens()
  local game = self.editor.game
  local folder = self.editor.folderPath
  if not folder then return end
  local used = {}
  for _, tok in ipairs(game.tokens) do
    if tok.imagePath then used[tok.imagePath] = true end
  end
  local added = 0
  for _, e in ipairs(fs.listFilesRecursive(fs.join(folder, "tokens"))) do
    local ext = fs.extension(e.rel)
    if not used[e.rel] and (ext == ".png" or ext == ".jpg" or ext == ".jpeg" or ext == ".webp") then
      local dirPart = fs.dirname(e.rel)
      local tokenType = dirPart ~= "." and fs.basename(dirPart) or nil
      local baseName = fs.stripExtension(fs.basename(e.rel))
      local name = tokenType and (baseName .. "|" .. tokenType) or baseName
      game.tokens[#game.tokens + 1] = models.TokenDefinition.new({ id = uuid.v4(), name = name, imagePath = e.rel })
      used[e.rel] = true
      added = added + 1
    end
  end
  overlays.toast(added > 0 and (added .. " token" .. (added == 1 and "" or "s") .. " added.")
    or "No new images found in the tokens folder.")
end

function T:drawList(x, y, w, h)
  local c = theme.c
  local game = self.editor.game
  ui.rect("fill", x, y, w, h, 0, c.surfaceContainer)
  local hh = common.sectionHeader("tt:list", "Tokens", x + 16, y + 12, w - 32, { count = #game.tokens })
  local by = y + 12 + hh + 8
  local btnW = w - 32
  if ui.button("Add Token", x + 16, by, btnW, BTN_H, { variant = "tonal", icon = "add", id = "tt:add" }) then
    local tok = models.TokenDefinition.new({ id = uuid.v4(), name = "New Token" })
    game.tokens[#game.tokens + 1] = tok
    self.selected = tok
  end
  by = by + BTN_H + 8
  if ui.button("Auto Add Tokens", x + 16, by, btnW, BTN_H, { variant = "outlined", icon = "upload_file", id = "tt:auto" }) then
    self:autoAddTokens()
  end
  local ly = by + BTN_H + 8
  local lh = y + h - ly
  local off = ui.beginScroll("tt:list", x, ly, w, lh)
  local ro = widgets.reorder("tt:tokens")
  local yy = ly - off
  for i, tok in ipairs(game.tokens) do
    local rx, rw = x + 8, w - 16
    local sel = tok == self.selected
    local r = ui.region("tt:row:" .. keyOf(tok), rx + 40, yy, rw - 40, ROW_H, { cursor = "hand" })
    if sel then
      ui.rect("fill", rx, yy, rw, ROW_H, 8, c.secondaryContainer)
    elseif r.hovered then
      ui.rect("fill", rx, yy, rw, ROW_H, 8, theme.alpha(c.onSurface, 0.05))
    end
    ro:handle(i, rx, yy + (ROW_H - 40) / 2, yy, ROW_H)
    local ix = rx + 40 + (ROW_H - THUMB) / 2
    common.imagePreviewBox(tok.imagePath and fs.join(self.editor.folderPath, "tokens", tok.imagePath),
      ix, yy + (ROW_H - THUMB) / 2, THUMB, THUMB)
    local fg = sel and c.onSecondaryContainer or c.onSurface
    local tx = ix + THUMB + 12
    local name = models.TokenDefinition.displayName(tok)
    ui.text(name == "" and "(unnamed token)" or name, tx, yy + 9, { w = rx + rw - 8 - tx, ellipsis = true,
      weight = sel and "medium" or nil, color = fg })
    ui.text(models.TokenDefinition.typeOf(tok) or "No type", tx, yy + 30, { w = rx + rw - 8 - tx, ellipsis = true,
      size = 12, color = c.onSurfaceVariant })
    if r.clicked then
      self.selected = tok
      ui.blur()
    end
    yy = yy + ROW_H + 2
  end
  local from, to = ro:finish(x + 8, w - 16)
  if from then widgets.moveItem(game.tokens, from, to) end
  ui.endScroll("tt:list", #game.tokens * (ROW_H + 2) + 12)
end

---------------------------------------------------------------------------
-- Detail
---------------------------------------------------------------------------

function T:drawDetail(tok, x, y, w, h)
  local c = theme.c
  local k = "tt:" .. keyOf(tok)
  local off = ui.beginScroll("tt:detail", x, y, w, h)
  local cx, cw = common.column(x, w)
  local yy = y + common.PAD - off

  local name = models.TokenDefinition.displayName(tok)
  ui.text(name == "" and "(unnamed token)" or name, cx, yy, { size = 20, weight = "medium", h = 40,
    valign = "middle", w = cw - 160, ellipsis = true })
  local bw = ui.buttonWidth("Delete Token", { icon = "delete_outline" })
  if ui.button("Delete Token", cx + cw - bw, yy, bw, 40, { variant = "text", icon = "delete_outline", id = k .. ":del" }) then
    self.pendingRemove = tok
  end
  yy = yy + 40 + 16

  tok.name = ui.textField(k .. ":name", cx, yy, cw, tok.name, { label = "Name", trailingW = 28 })
  common.infoIcon(k .. ":name:info", cx + cw - 30, yy + (common.FIELD_H - 18) / 2,
    "Add a \"|\" followed by a type to group this token for the Token Widget's type filter at the table, "
      .. "e.g. \"Daisy Walker|Investigator\".")
  yy = yy + common.FIELD_H + 4

  local parsedType = models.TokenDefinition.typeOf(tok)
  ui.text("Shown as \"" .. (name == "" and "(unnamed token)" or name) .. "\""
    .. (parsedType and (", type \"" .. parsedType .. "\"") or ", no type"),
    cx, yy, { w = cw, h = 20, size = 12, color = c.onSurfaceVariant })
  yy = yy + 20 + common.GAP

  local THUMB_BIG = 96
  local thumb = ui.region(k .. ":img", cx, yy, THUMB_BIG, THUMB_BIG, { cursor = "hand", tooltip = "Choose Token Image..." })
  common.imagePreviewBox(tok.imagePath and fs.join(self.editor.folderPath, "tokens", tok.imagePath),
    cx, yy, THUMB_BIG, THUMB_BIG)
  if thumb.clicked then
    common.chooseTokenImage(self.editor.folderPath, function(file) tok.imagePath = file end)
  end
  ui.text(tok.imagePath or "(no image)", cx + THUMB_BIG + 12, yy, { w = cw - THUMB_BIG - 12, h = THUMB_BIG,
    valign = "middle", ellipsis = true, color = tok.imagePath and c.onSurface or c.onSurfaceVariant })
  yy = yy + THUMB_BIG + common.PAD

  ui.endScroll("tt:detail", yy + off - y)
end

function T:draw(x, y, w, h)
  local game = self.editor.game
  self.pendingRemove = nil
  listDetail.draw(self, x, y, w, h, game.tokens, LIST_W, T.drawList, T.drawDetail, "Add a token to get started")
  if self.pendingRemove then
    local i
    for j, t in ipairs(game.tokens) do if t == self.pendingRemove then i = j end end
    util.removeValue(game.tokens, self.pendingRemove)
    self.selected = i and game.tokens[math.min(i, #game.tokens)] or nil
  end
end

return T
