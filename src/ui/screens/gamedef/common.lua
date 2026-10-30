-- Helpers shared by the Game Definition Editor's tabs.
--
-- The editor works on a GameDefinition holding BARE image file names (see
-- gamedef_ops.loadGameDefFile); anything that renders an image builds a
-- display-only copy with resolved paths, never stored back.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local fs = require("src.data.fs")
local ops = require("src.data.gamedef_ops")
local resolver = require("src.data.image_resolver")
local imageCache = require("src.data.image_cache")
local CR = require("src.ui.table.card_render")
local fileDialog = require("src.platform.file_dialog")

local C = {}

-- Stable per-object key for widget ids: list items keep their text field
-- state across reorders and across edits to their own (editable) ids.
local keys = setmetatable({}, { __mode = "k" })
local nextKey = 0
function C.keyOf(obj)
  local k = keys[obj]
  if not k then
    nextKey = nextKey + 1
    k = "o" .. nextKey
    keys[obj] = k
  end
  return k
end

C.orientationOptions = {
  { value = "portrait", label = "portrait" },
  { value = "left", label = "left" },
  { value = "right", label = "right" },
}

C.imageFilters = { { name = "Images", extensions = ops.imageFilterList } }

-- A copy of card with its image path resolved for drawing.
function C.displayCard(folderPath, card)
  if card.imagePath == nil then return card end
  local copy = {}
  for k, v in pairs(card) do copy[k] = v end
  copy.imagePath = resolver.resolveBareImagePath(folderPath, card.imagePath, card.setId)
  return copy
end

function C.displayCardBacks(folderPath, cardBacks)
  local out = {}
  for i, b in ipairs(cardBacks) do
    if b.imagePath == nil then
      out[i] = b
    else
      out[i] = { id = b.id, name = b.name, orientation = b.orientation,
        imagePath = resolver.resolveBareImagePath(folderPath, b.imagePath) }
    end
  end
  return out
end

-- Picks an image file and copies it into destFolder; onResult(fileName)
-- fires with its bare file name, or nil when cancelled or the copy failed
-- (with a snackbar).
function C.chooseImage(destFolder, correctCardOrientation, onResult)
  fileDialog.openFile({ title = "Choose Image", filters = C.imageFilters }, function(path)
    if not path then onResult(nil); return end
    local ok, fileName, err = pcall(ops.copyPickedImage, path, destFolder, correctCardOrientation)
    if not ok or not fileName then
      overlays.toast("Could not copy that image: " .. tostring(ok and err or fileName))
      onResult(nil)
      return
    end
    -- The copy may have replaced a file the caches already hold.
    imageCache.invalidate(fs.join(destFolder, fileName))
    resolver.clearCache()
    onResult(fileName)
  end)
end

-- Shared layout scale for the editor's tabs.
C.PAD = 24          -- page gutter
C.GAP = 12          -- between fields / rows
C.SECTION_GAP = 32  -- between sections
C.FIELD_H = 48
C.MAX_CONTENT = 760 -- single-column pages are capped and centered

-- The centered content column for a page of width w: (x, w).
function C.column(x, w)
  local cw = math.min(C.MAX_CONTENT, w - 2 * C.PAD)
  return x + math.floor((w - cw) / 2), cw
end

-- A small (i) icon whose tooltip holds the help text. Returns its width.
function C.infoIcon(id, x, y, text)
  local s = 18
  local r = ui.region(id, x - 3, y - 3, s + 6, s + 6, { tooltip = text })
  ui.icon("info_outline", x, y, s, r.hovered and theme.c.primary or theme.c.outline)
  return s
end

-- A page section title (16 medium) with an optional (i) help tooltip, a
-- count, and a right-aligned button. opts: info, count, action = {label,
-- icon, id, disabled, variant}. Returns (height, actionClicked).
function C.sectionHeader(id, title, x, y, w, opts)
  opts = opts or {}
  local c = theme.c
  local h = 40
  local tx = x
  ui.text(title, tx, y, { size = 16, weight = "medium", h = h, valign = "middle" })
  tx = tx + ui.textWidth(title, 16, "medium") + 8
  if opts.count then
    local label = tostring(opts.count)
    local bw = ui.textWidth(label, 12, "medium") + 14
    ui.rect("fill", tx, y + (h - 20) / 2, bw, 20, 10, c.surfaceContainerHighest)
    ui.text(label, tx, y, { w = bw, h = h, size = 12, weight = "medium", align = "center", valign = "middle",
      color = c.onSurfaceVariant })
    tx = tx + bw + 8
  end
  if opts.info then C.infoIcon(id .. ":info", tx, y + (h - 18) / 2, opts.info) end
  local clicked = false
  local a = opts.action
  if a then
    local bw = ui.buttonWidth(a.label, { icon = a.icon })
    clicked = ui.button(a.label, x + w - bw, y, bw, h, { variant = a.variant or "tonal", icon = a.icon,
      id = a.id or (id .. ":action"), disabled = a.disabled })
  end
  return h, clicked
end

-- A small grey group label inside a section (e.g. "Behavior"). Returns its height.
function C.groupLabel(text, x, y, w)
  ui.text(text, x, y, { size = 12, weight = "medium", w = w, color = theme.c.primary })
  return 20
end

-- A compact on/off row: label, optional (i) tooltip, switch at the right.
-- Returns (value, height).
C.TOGGLE_H = 44
function C.toggleRow(id, label, help, x, y, w, value, opts)
  opts = opts or {}
  local c = theme.c
  local h = C.TOGGLE_H
  local disabled = opts.disabled
  local lw = math.min(ui.textWidth(label, 14), w - 52 - 16 - (help and 26 or 0))
  ui.text(label, x, y, { w = lw + 1, h = h, valign = "middle", ellipsis = true,
    color = disabled and c.disabled or c.onSurface })
  if help then C.infoIcon(id .. ":info", x + lw + 8, y + (h - 18) / 2, help) end
  value = ui.switch(id, x + w - 52, y + (h - 32) / 2, value, { disabled = disabled })
  return value, h
end

-- Lays toggle rows out in one or two columns (two when w allows).
-- rows = { {id=, label=, help=, get=fn, set=fn(v), disabled=}, ... }.
-- Returns the height used.
function C.toggleGrid(rows, x, y, w)
  if #rows == 0 then return 0 end
  local cols = w >= 560 and 2 or 1
  local gap = 32
  local colW = (w - (cols - 1) * gap) / cols
  local perCol = math.ceil(#rows / cols)
  for i, r in ipairs(rows) do
    local col = math.floor((i - 1) / perCol)
    local row = (i - 1) % perCol
    local v = C.toggleRow(r.id, r.label, r.help, x + col * (colW + gap), y + row * C.TOGGLE_H, colW, r.get(),
      { disabled = r.disabled })
    if v ~= r.get() then r.set(v) end
  end
  return perCol * C.TOGGLE_H
end

-- Draws an image into a box: "contain" (whole image, letterboxed) or
-- "cover" (fills, cropped). quarterTurns rotates it in place. Returns
-- true when drawn, false when missing/broken (caller draws a fallback),
-- or "loading". rounded (contain only) gives it card-style rounded corners.
function C.drawImageInBox(path, x, y, w, h, fit, quarterTurns, rounded)
  if not path then return false end
  local img = imageCache.get(path)
  if not img then
    return imageCache.status(path) == "loading" and "loading" or false
  end
  local iw, ih = img:getDimensions()
  local turned = quarterTurns ~= nil and quarterTurns % 2 == 1
  local bw, bh = turned and ih or iw, turned and iw or ih
  local s = fit == "cover" and math.max(w / bw, h / bh) or math.min(w / bw, h / bh)
  if fit == "cover" then ui.pushClip(x, y, w, h) end
  rounded = rounded and fit ~= "cover"
    and CR.setRoundedShader({ 0, 0, 1, 1 }, iw * s, ih * s, CR.radiusFor(math.min(iw, ih) * s))
  love.graphics.setColor(1, 1, 1)
  love.graphics.draw(img, x + w / 2, y + h / 2, (quarterTurns or 0) * math.pi / 2, s, s, iw / 2, ih / 2)
  if rounded then love.graphics.setShader() end
  if fit == "cover" then ui.popClip() end
  return true
end

-- The card-sized (70x100) thumbnail box used by the card-back rows: the
-- image cover-fit, or an icon when there's none / it can't load.
function C.imagePreviewBox(path, x, y, w, h)
  local c = theme.c
  local drawn = C.drawImageInBox(path, x + 1, y + 1, w - 2, h - 2, "cover")
  if drawn ~= true and drawn ~= "loading" then
    ui.iconCentered(path and "broken_image" or "image_not_supported", x, y, w, h, 24, c.outline)
  end
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, 6, c.outline)
end

-- A clickable row that toggles a collapsible group: chevron, title, and
-- optional grey trailing text. Returns true when clicked.
function C.collapseHeader(id, title, x, y, w, h, expanded, trailing)
  local c = theme.c
  local r = ui.region(id, x, y, w, h, { cursor = "hand" })
  if r.hovered then ui.rect("fill", x, y, w, h, 6, theme.alpha(c.onSurface, 0.05)) end
  ui.iconCentered(expanded and "expand_more" or "chevron_right", x, y, 28, h, 20, c.onSurfaceVariant)
  local tw = w - 32 - (trailing and 8 or 0)
  ui.text(title, x + 28, y, { weight = "medium", h = h, valign = "middle", w = tw, ellipsis = true })
  if trailing then
    local nw = ui.textWidth(title, 14, "medium")
    ui.text(trailing, x + 28 + nw + 8, y, { size = 12, h = h, valign = "middle", w = math.max(0, tw - nw - 8),
      ellipsis = true, color = c.onSurfaceVariant })
  end
  return r.clicked == true
end

-- Scans <folderPath>/tokens for image files (same filter table_screen.lua's
-- T:loadTokenImages uses at the table), sorted by name. Each entry:
-- { name, file, path } -- file is the bare name to store, path a resolved
-- one for display.
function C.tokenFolderImages(folderPath)
  if not folderPath then return {} end
  local dir = fs.join(folderPath, "tokens")
  local list = {}
  for _, e in ipairs(fs.list(dir) or {}) do
    local ext = fs.extension(e.name)
    if not e.isDir and (ext == ".png" or ext == ".jpg" or ext == ".jpeg" or ext == ".webp") then
      list[#list + 1] = { name = fs.stripExtension(e.name), file = e.name, path = fs.join(dir, e.name) }
    end
  end
  table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
  return list
end

-- A small thumbnail-grid popover to pick one bare file name out of
-- <folderPath>/tokens, plus an "Add Image..." tile that copies a new file
-- in via C.chooseImage. onResult(fileName) fires once, on pick or add
-- (never on cancel).
function C.chooseTokenImage(folderPath, onResult)
  local images = C.tokenFolderImages(folderPath)
  local TILE, GAP, COLS = 72, 8, 4
  local GRID_H = 280
  overlays.dialog({
    title = "Choose Token Image", width = COLS * TILE + (COLS - 1) * GAP + 48,
    content = function(d, x, y, w)
      local addW = ui.buttonWidth("Add Image...", { icon = "add" })
      if ui.button("Add Image...", x, y, addW, 40, { variant = "outlined", icon = "add", id = "ctok:add" }) then
        C.chooseImage(fs.join(folderPath, "tokens"), false, function(name)
          if name then
            onResult(name)
            d:close()
          end
        end)
      end
      local gy = y + 40 + 12
      if #images == 0 then
        ui.text("No images in this game's tokens folder yet.", x, gy,
          { w = w, h = GRID_H, align = "center", valign = "middle", color = theme.c.onSurfaceVariant })
        return 40 + 12 + GRID_H
      end
      local off = ui.beginScroll("ctok:grid", x, gy, w, GRID_H)
      local rowH = TILE + 20 + GAP
      local picked
      for i, img in ipairs(images) do
        local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
        local tx, ty = x + col * (TILE + GAP), gy - off + row * rowH
        if ty + TILE + 20 > gy and ty < gy + GRID_H then
          local r = ui.region("ctok:img:" .. i, tx, ty, TILE, TILE, { cursor = "hand" })
          C.imagePreviewBox(img.path, tx, ty, TILE, TILE)
          ui.text(img.name, tx, ty + TILE + 2, { size = 11, w = TILE, align = "center", maxLines = 1 })
          if r.clicked then picked = img.file end
        end
      end
      ui.endScroll("ctok:grid", math.ceil(#images / COLS) * rowH)
      if picked then
        onResult(picked)
        d:close()
      end
      return 40 + 12 + GRID_H
    end,
    actions = { { label = "Cancel", variant = "text" } },
  })
end

-- -, quantity, + and a remove button for a quantity row ending at right.
-- Returns (newQuantity, removeClicked). opts: removeTooltip, disabled.
function C.stepper(id, right, y, quantity, opts)
  opts = opts or {}
  local x = right - 40 - 40 - 24 - 40
  local q = quantity
  local off = opts.disabled
  if ui.iconButton("remove", x, y, { id = id .. ":dec", disabled = off or quantity <= 1 }) then q = quantity - 1 end
  ui.text(tostring(quantity), x + 40, y, { w = 24, h = 40, align = "center", valign = "middle",
    color = off and theme.c.disabled or theme.c.onSurface })
  if ui.iconButton("add", x + 64, y, { id = id .. ":inc", disabled = off }) then q = quantity + 1 end
  local removed = ui.iconButton("close", x + 104, y, { id = id .. ":rm", tooltip = opts.removeTooltip, disabled = off })
  return q, removed
end
C.stepperWidth = 40 + 24 + 40 + 40

return C
