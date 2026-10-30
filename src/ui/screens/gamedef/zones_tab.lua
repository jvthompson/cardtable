-- Port of widgets/zones_tab.dart, laid out as list + detail: a reorderable
-- zone list on the left and the selected zone's settings on the right.
-- Settings that can't apply to the zone as configured are hidden rather
-- than greyed out (their stored values are kept). Edits apply straight to
-- game.zones.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local widgets = require("src.ui.kit.widgets")
local colorpicker = require("src.ui.kit.colorpicker")
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

local KIND_OPTIONS = { { value = "card", label = "Card Zone" }, { value = "widget", label = "Widget Zone" } }
local WIDGET_KIND_OPTIONS = { { value = "counter", label = "Counter" }, { value = "tokenBag", label = "Token Bag" } }
local SIDE_OPTIONS = { { value = "left", label = "Left" }, { value = "right", label = "Right" } }

local LIST_W = 300
local ROW_H = 56

local function isInteger(s) return s:match("^%-?%d+$") ~= nil end

-- Short flags shown under a zone's name in the list.
local function badgesOf(zone)
  if zone.kind ~= "card" then
    if zone.widgetKind == "tokenBag" then
      local total = 0
      for _, e in ipairs(zone.bagEntries) do total = total + e.quantity end
      return total .. " token" .. (total == 1 and "" or "s")
    end
    return "Counter"
  end
  local b = {}
  if zone.shared then b[#b + 1] = "Shared" end
  if zone.dealsBuiltDeck and not zone.shared then b[#b + 1] = "Deck" end
  if zone.faceUp then b[#b + 1] = "Face up" end
  if zone.isDiscardPile then b[#b + 1] = "Discard" end
  return #b > 0 and table.concat(b, " · ") or "Card zone"
end

---------------------------------------------------------------------------
-- List
---------------------------------------------------------------------------

function T:drawList(x, y, w, h)
  local c = theme.c
  local game = self.editor.game
  ui.rect("fill", x, y, w, h, 0, c.surfaceContainer)
  local hh, add = common.sectionHeader("zt:list", "Zones", x + 16, y + 12, w - 32, {
    count = #game.zones, action = { label = "Add Zone", icon = "add", id = "zt:add" } })
  if add then
    local zone = models.ZoneDefinition.new({ id = uuid.v4(), name = "New Zone" })
    game.zones[#game.zones + 1] = zone
    self.selected = zone
  end
  local ly = y + 12 + hh + 8
  local lh = y + h - ly
  local off = ui.beginScroll("zt:list", x, ly, w, lh)
  local ro = widgets.reorder("zt:zones")
  local yy = ly - off
  for i, zone in ipairs(game.zones) do
    local rx, rw = x + 8, w - 16
    local sel = zone == self.selected
    local r = ui.region("zt:row:" .. keyOf(zone), rx + 40, yy, rw - 40, ROW_H, { cursor = "hand" })
    if sel then
      ui.rect("fill", rx, yy, rw, ROW_H, 8, c.secondaryContainer)
    elseif r.hovered then
      ui.rect("fill", rx, yy, rw, ROW_H, 8, theme.alpha(c.onSurface, 0.05))
    end
    ro:handle(i, rx, yy + (ROW_H - 40) / 2, yy, ROW_H)
    local fg = sel and c.onSecondaryContainer or c.onSurface
    ui.icon(zone.kind == "card" and "layers" or "widgets", rx + 42, yy + (ROW_H - 20) / 2, 20, sel and fg or c.onSurfaceVariant)
    local tx = rx + 72
    ui.text(zone.name == "" and "(unnamed zone)" or zone.name, tx, yy + 9, { w = rx + rw - 8 - tx, ellipsis = true,
      weight = sel and "medium" or nil, color = fg })
    ui.text(badgesOf(zone), tx, yy + 30, { w = rx + rw - 8 - tx, ellipsis = true, size = 12, color = c.onSurfaceVariant })
    if r.clicked then
      self.selected = zone
      ui.blur()
    end
    yy = yy + ROW_H + 2
  end
  local from, to = ro:finish(x + 8, w - 16)
  if from then widgets.moveItem(game.zones, from, to) end
  ui.endScroll("zt:list", #game.zones * (ROW_H + 2) + 12)
end

---------------------------------------------------------------------------
-- Detail
---------------------------------------------------------------------------

-- A labelled sub-group heading with a little space above. Returns height.
local function group(text, x, y, w)
  return 20 + common.groupLabel(text, x, y + 20, w) + 2
end

-- A text field with a (i) help icon inside its right end. Returns text.
local function fieldWithInfo(id, x, y, w, text, label, help)
  local v = ui.textField(id, x, y, w, text, { label = label, trailingW = 28 })
  common.infoIcon(id .. ":info", x + w - 30, y + (common.FIELD_H - 18) / 2, help)
  return v
end

-- The card-zone settings below the Zone Type picker. Returns height used.
function T:drawCardZoneFields(zone, k, x, y, w)
  local c = theme.c
  local cards = self.editor.game.cards
  local yy = y

  -- Ownership.
  yy = yy + group("Ownership", x, yy, w)
  local rows = {
    { id = k .. ":shared", label = "Shared", help = "One public pile for everyone, instead of one private pile per player",
      get = function() return zone.shared end, set = function(v) zone.shared = v end },
  }
  if not zone.shared then
    rows[#rows + 1] = { id = k .. ":visible", label = "Visible To All", help = "Let opponents see the real cards in this owned zone",
      get = function() return zone.visibleToAll end, set = function(v) zone.visibleToAll = v end }
  end
  yy = yy + common.toggleGrid(rows, x, yy, w)

  -- Behavior.
  yy = yy + group("Behavior", x, yy, w)
  yy = yy + common.toggleGrid({
    { id = k .. ":faceup", label = "Face Up", help = "Cards in this zone show their real face",
      get = function() return zone.faceUp end, set = function(v) zone.faceUp = v end },
    { id = k .. ":shufflable", label = "Shuffleable", help = "Show a shuffle button for this zone",
      get = function() return zone.shuffleable end, set = function(v) zone.shuffleable = v end },
    { id = k .. ":autoshuffle", label = "Auto Shuffle", help = "Randomize this zone's order automatically when the game loads",
      get = function() return zone.autoShuffle end, set = function(v) zone.autoShuffle = v end },
    { id = k .. ":discard", label = "Is Discard Pile", help = "Pressing D sends a hovered table card here",
      get = function() return zone.isDiscardPile end, set = function(v) zone.isDiscardPile = v end },
  }, x, yy, w)

  -- Dealing (owned zones) or the shared deck (shared zones).
  local h
  if not zone.shared then
    yy = yy + group("Dealing", x, yy, w)
    zone.dealsBuiltDeck, h = common.toggleRow(k .. ":deals", "Deals Built Deck",
      "Receives the player's own loaded deck at game start (owned zones only)", x, yy, w, zone.dealsBuiltDeck)
    yy = yy + h
    if zone.dealsBuiltDeck then
      yy = yy + 8
      -- Deck Type keeps what's typed; an empty field means main_deck.
      local function deckTypeOf(s) return util.trim(s) == "" and "main_deck" or s end
      local st = ui.state(k .. ":deckTypeText")
      if st.text == nil or deckTypeOf(st.text) ~= zone.deckType then st.text = zone.deckType end
      local dw = w >= 560 and (w - 32) / 2 or w
      st.text = fieldWithInfo(k .. ":decktype", x, yy, dw, st.text, "Deck Type",
        "Which subdeck (by name) this zone loads from a chosen deck file -- defaults to main_deck")
      zone.deckType = deckTypeOf(st.text)
      if w >= 560 then
        zone.deckOptional = common.toggleRow(k .. ":optional", "Deck Optional",
          "A chosen deck may leave this zone's subdeck empty or missing (deals empty instead of being rejected)",
          x + dw + 32, yy + 2, dw, zone.deckOptional)
        yy = yy + common.FIELD_H
      else
        yy = yy + common.FIELD_H + 4
        zone.deckOptional, h = common.toggleRow(k .. ":optional", "Deck Optional",
          "A chosen deck may leave this zone's subdeck empty or missing (deals empty instead of being rejected)",
          x, yy, w, zone.deckOptional)
        yy = yy + h
      end
    end
  else
    yy = yy + group("Shared Deck", x, yy, w)
    zone.standardDeck, h = common.toggleRow(k .. ":standard", "Standard 52-Card Deck",
      "Deal one of each traditional playing card automatically", x, yy, w, zone.standardDeck)
    yy = yy + h + 8
    local sideW = 40 + 200
    local dw = zone.standardDeck and 0 or (w - sideW - 24)
    if not zone.standardDeck then
      local text = fieldWithInfo(k .. ":deckname", x, yy, dw, zone.deckName or "", "Deck Name",
        "Loads this deck from the Deck Library's folder for this game")
      if text ~= (zone.deckName or "") then zone.deckName = text ~= "" and text or nil end
    end
    local sx = zone.standardDeck and x or (x + dw + 24)
    ui.text("Side", sx, yy + 4, { h = 40, valign = "middle", color = c.onSurfaceVariant })
    zone.side = ui.segmented(k .. ":side", sx + 40, yy + 4, sideW - 40, SIDE_OPTIONS, zone.side)
    yy = yy + common.FIELD_H
  end

  -- Starting contents, ignored when another source fills the zone (only
  -- the sources that apply to this kind of zone -- see session.lua).
  yy = yy + group("Starting Contents", x, yy, w)
  local hasDeckName = zone.deckName ~= nil and zone.deckName ~= ""
  local why
  if not zone.shared and zone.dealsBuiltDeck then
    why = "Ignored while Deals Built Deck is on."
  elseif zone.shared and zone.standardDeck then
    why = "Ignored while Standard 52-Card Deck is on."
  elseif zone.shared and hasDeckName then
    why = "Ignored while a Deck Name is set."
  end
  if why then
    ui.text(why, x, yy, { h = 32, valign = "middle", color = c.onSurfaceVariant })
    return yy + 32 - y
  end
  local options = util.map(cards, function(card) return { value = card.id, label = card.cardTitle } end)
  local remove
  for i, entry in ipairs(zone.entries) do
    local ek = k .. ":entry" .. i
    local dw = w - 8 - common.stepperWidth
    local picked = ui.dropdown(ek .. ":card", x, yy + 4, dw, options, entry.definitionId,
      { h = 40, placeholder = "(unknown card)", size = 14 })
    if picked ~= entry.definitionId then zone.entries[i] = models.DeckEntry.new(picked, entry.quantity) end
    local q, removed = common.stepper(ek, x + w, yy + 4, entry.quantity, { removeTooltip = "Remove Entry" })
    if q ~= entry.quantity then zone.entries[i] = models.DeckEntry.new(zone.entries[i].definitionId, q) end
    if removed then remove = i end
    yy = yy + 48
  end
  if remove then table.remove(zone.entries, remove) end
  if ui.button("Add Entry", x - 8, yy, nil, 40, { variant = "text", icon = "add", id = k .. ":addentry",
    disabled = #cards == 0 }) then
    zone.entries[#zone.entries + 1] = models.DeckEntry.new(cards[1].id, 1)
  end
  yy = yy + 40
  return yy - y
end

-- The widget-zone settings. Returns height used.
function T:drawWidgetZoneFields(zone, k, x, y, w)
  local G = common.GAP
  local yy = y + group("Widget", x, y, w) + 8
  local hw = (w - G) / 2
  zone.widgetKind = ui.dropdown(k .. ":wkind", x, yy, hw, WIDGET_KIND_OPTIONS, zone.widgetKind, { label = "Widget Type" })
  yy = yy + common.FIELD_H + G

  if zone.widgetKind == "tokenBag" then
    return (yy - y) + self:drawTokenBagFields(zone, k, x, yy, w)
  end

  -- Starting Value keeps what's typed; anything unparsable counts as 0.
  local function valueOf(s) return isInteger(s) and tonumber(s) or 0 end
  local st = ui.state(k .. ":startText")
  if st.text == nil or valueOf(st.text) ~= zone.counterStartingValue then
    st.text = tostring(zone.counterStartingValue)
  end
  st.text = ui.textField(k .. ":start", x, yy, hw, st.text, { label = "Starting Value",
    filter = function(s) return s:match("^[%d%-]*$") ~= nil end })
  zone.counterStartingValue = valueOf(st.text)
  yy = yy + common.FIELD_H + G
  local h1, h2
  zone.counterStartingColor, h1 = colorpicker.field(k .. ":color", x, yy, hw, zone.counterStartingColor,
    { hexLabel = "Starting Color (hex)" })
  zone.counterStartingTextColor, h2 = colorpicker.field(k .. ":textcolor", x + hw + G, yy, hw, zone.counterStartingTextColor,
    { hexLabel = "Starting Text Color (hex)" })
  yy = yy + math.max(h1, h2)
  return yy - y
end

-- Fields for widgetKind == "tokenBag": the bag's own idle image, whether a
-- returned token goes back into the bag or is destroyed, and the bag's
-- contents (a token image + quantity per row, like the card-entries editor
-- below does for DeckEntry, but picking a token image instead of a card).
function T:drawTokenBagFields(zone, k, x, y, w)
  local c = theme.c
  local yy = y
  local THUMB = 56
  local thumb = ui.region(k .. ":bagimg", x, yy, THUMB, THUMB, { cursor = "hand", tooltip = "Choose Bag Image..." })
  common.imagePreviewBox(zone.bagImagePath and fs.join(self.editor.folderPath, "tokens", zone.bagImagePath),
    x, yy, THUMB, THUMB)
  if thumb.clicked then
    common.chooseTokenImage(self.editor.folderPath, function(file) zone.bagImagePath = file end)
  end
  ui.text(zone.bagImagePath or "(no bag image)", x + THUMB + 12, yy, { w = w - THUMB - 12, h = THUMB,
    valign = "middle", ellipsis = true, color = zone.bagImagePath and c.onSurface or c.onSurfaceVariant })
  yy = yy + THUMB + 12

  local th
  zone.bagReturnable, th = common.toggleRow(k .. ":returnable", "Returnable",
    "A returned token goes back into the bag's contents; off, it's destroyed instead", x, yy, w, zone.bagReturnable)
  yy = yy + th + 12

  yy = yy + common.groupLabel("Contents", x, yy, w) + 4
  local images = common.tokenFolderImages(self.editor.folderPath)
  local options = util.map(images, function(img) return { value = img.file, label = img.name } end)
  local remove
  for i, entry in ipairs(zone.bagEntries) do
    local ek = k .. ":bagentry" .. i
    local dw = w - 8 - common.stepperWidth
    local picked = ui.dropdown(ek .. ":img", x, yy + 4, dw, options, entry.definitionId,
      { h = 40, placeholder = "(choose image)", size = 14 })
    if picked ~= entry.definitionId then zone.bagEntries[i] = models.DeckEntry.new(picked, entry.quantity) end
    local q, removed = common.stepper(ek, x + w, yy + 4, entry.quantity, { removeTooltip = "Remove Entry" })
    if q ~= entry.quantity then zone.bagEntries[i] = models.DeckEntry.new(zone.bagEntries[i].definitionId, q) end
    if removed then remove = i end
    yy = yy + 48
  end
  if remove then table.remove(zone.bagEntries, remove) end
  if ui.button("Add Entry", x - 8, yy, nil, 40, { variant = "text", icon = "add", id = k .. ":addbagentry",
    disabled = #images == 0 }) then
    zone.bagEntries[#zone.bagEntries + 1] = models.DeckEntry.new(images[1].file, 1)
  end
  yy = yy + 40
  return yy - y
end

function T:drawDetail(zone, x, y, w, h)
  local k = "zt:" .. keyOf(zone)
  local G = common.GAP
  local off = ui.beginScroll("zt:detail", x, y, w, h)
  local cx, cw = common.column(x, w)
  local yy = y + common.PAD - off

  -- Header: name and delete.
  ui.text(zone.name == "" and "(unnamed zone)" or zone.name, cx, yy, { size = 20, weight = "medium", h = 40,
    valign = "middle", w = cw - 160, ellipsis = true })
  local bw = ui.buttonWidth("Delete Zone", { icon = "delete_outline" })
  if ui.button("Delete Zone", cx + cw - bw, yy, bw, 40, { variant = "text", icon = "delete_outline", id = k .. ":del" }) then
    self.pendingRemove = zone
  end
  yy = yy + 40 + 16

  local hw = (cw - G) / 2
  zone.name = ui.textField(k .. ":name", cx, yy, hw, zone.name, { label = "Zone Name" })
  zone.id = ui.textField(k .. ":id", cx + hw + G, yy, hw, zone.id, { label = "Zone ID" })
  yy = yy + common.FIELD_H + 16
  zone.kind = ui.segmented(k .. ":kind", cx, yy, math.min(cw, 320), KIND_OPTIONS, zone.kind)
  yy = yy + 40 + 8

  if zone.kind == "card" then
    yy = yy + self:drawCardZoneFields(zone, k, cx, yy, cw)
  else
    yy = yy + self:drawWidgetZoneFields(zone, k, cx, yy, cw)
  end
  yy = yy + common.PAD
  ui.endScroll("zt:detail", yy + off - y)
end

function T:draw(x, y, w, h)
  local game = self.editor.game
  self.pendingRemove = nil
  listDetail.draw(self, x, y, w, h, game.zones, LIST_W, T.drawList, T.drawDetail, "Add a zone to get started")
  if self.pendingRemove then
    local i
    for j, z in ipairs(game.zones) do if z == self.pendingRemove then i = j end end
    util.removeValue(game.zones, self.pendingRemove)
    self.selected = i and game.zones[math.min(i, #game.zones)] or nil
  end
end

return T
