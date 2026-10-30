-- Ports of widgets/card_view_tab.dart and card_detail_panel.dart: three
-- resizable columns -- a filtered pool grid, a large live preview, and the
-- selected card's form. Edits apply straight to the card in game.cards.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local widgets = require("src.ui.kit.widgets")
local filterBar = require("src.ui.kit.card_filter_bar")
local json = require("lib.json")
local models = require("src.core.models")
local util = require("src.core.util")
local uuid = require("src.core.uuid")
local fs = require("src.data.fs")
local filters = require("src.core.card_filters")
local tagMatch = require("src.core.tag_match")
local resolver = require("src.data.image_resolver")
local common = require("src.ui.screens.gamedef.common")
local CR = require("src.ui.table.card_render")
local poolGrid = require("src.ui.table.card_pool_grid")

local CW, CH = CR.cardWidth, CR.cardHeight
local PW, PH, POOL_SCALE, NAME_LINES = poolGrid.PW, poolGrid.PH, poolGrid.SCALE, poolGrid.NAME_LINES
local keyOf = common.keyOf

local T = {}
T.__index = T

local MIN_FRACTION = 0.15
local DIVIDER = 9

function T.new(editor)
  local self = setmetatable({ editor = editor }, T)
  self.filters = filterBar.newState(editor.game)
  self.poolFraction, self.previewFraction = 0.5, 0.25
  self.formTab = "main" -- "main" | "extra": which half of the card form is shown
  self.tabNavigatesInsideForm = false
  self.tabFocusesTitle = false -- Tab to a card also focuses its title, text selected
  self.hiddenTagGroups = {} -- tag group id -> true while its chips are collapsed
  return self
end

-- Drops filter entries for tag groups, tags and sets that no longer exist
-- (they're editable on the other tabs) and adds empty ones for new groups.
function T:syncFilters()
  local game, st = self.editor.game, self.filters
  local groupIds = {}
  for _, g in ipairs(game.tagGroups) do
    groupIds[g.id] = true
    local tags = util.toSet(g.tags)
    for _, map in ipairs({ st.selected, st.excluded }) do
      map[g.id] = map[g.id] or {}
      for t in pairs(map[g.id]) do
        if not tags[t] then map[g.id][t] = nil end
      end
    end
  end
  for _, map in ipairs({ st.selected, st.excluded }) do
    for id in pairs(map) do
      if not groupIds[id] then map[id] = nil end
    end
  end
  local setIds = {}
  for _, s in ipairs(game.sets) do setIds[s.id] = true end
  for id in pairs(st.sets) do
    if not setIds[id] then st.sets[id] = nil end
  end
  local key = st.sortKey
  if key and key ~= filters.sortBySet and key ~= filters.sortByName and not groupIds[key] then st.sortKey = nil end
  for id in pairs(self.hiddenTagGroups) do
    if not groupIds[id] then self.hiddenTagGroups[id] = nil end
  end
end

function T:visibleCards()
  return filterBar.visible(self.filters, self.editor.game)
end

local function indexOf(list, item)
  for i, v in ipairs(list) do
    if v == item then return i end
  end
  return -1
end

function T:selectRelative(delta)
  local visible = self:visibleCards()
  if #visible == 0 then return end
  local i = indexOf(visible, self.selected)
  if delta > 0 then
    local n = i == -1 and 1 or i + 1
    if n <= #visible then self.selected = visible[n] end
  elseif i > 1 then
    self.selected = visible[i - 1]
  end
end

-- Tab / Shift+Tab to the next / previous card; with tabFocusesTitle on,
-- the new card's title field is focused with its text selected.
function T:tabToCard(delta)
  self:selectRelative(delta)
  if self.tabFocusesTitle and self.selected then
    ui.focusField("cv:form:" .. keyOf(self.selected) .. ":title", true)
  end
end

-- Tab / Shift+Tab with no field focused: next / previous card.
function T:keypressed(key)
  if key == "tab" then
    self:tabToCard(love.keyboard.isDown("lshift", "rshift") and -1 or 1)
    return true
  end
  return false
end

function T:addBlankCard()
  local game = self.editor.game
  -- With no Set filter, fall back to every set, so a single-set game still
  -- puts new cards in its one set.
  local candidates = {}
  if next(self.filters.sets) then
    for id in pairs(self.filters.sets) do candidates[#candidates + 1] = id end
  else
    for _, s in ipairs(game.sets) do candidates[#candidates + 1] = s.id end
  end
  local card = models.CardDefinition.new({ id = uuid.v4(), cardTitle = "New Card",
    setId = #candidates == 1 and candidates[1] or nil })
  game.cards[#game.cards + 1] = card
  self.selected = card
end

function T:deleteCard(card)
  local game = self.editor.game
  util.removeValue(game.cards, card)
  models.GameDefinition.invalidateIndex(game)
  if self.selected == card then self.selected = nil end
end

---------------------------------------------------------------------------
-- Pool
---------------------------------------------------------------------------

function T:drawPool(x, y, w, h, visible)
  local folder = self.editor.folderPath
  local cardBacks = self.displayBacks
  local gy = y + 4
  local gh = y + h - gy
  local nameH = poolGrid.nameH()
  poolGrid.draw("cv:pool", visible, x, gy, w, gh, 12, function(card, i, tx, ty, tileW, cx)
    local r = ui.region("cv:card:" .. keyOf(card), cx - PW / 2 - 4, ty - 4, PW + 8, PH + 8 + 2 + nameH, { cursor = "hand" })
    CR.draw({ def = common.displayCard(folder, card), faceUp = true, cx = cx, cy = ty + PH / 2, scale = POOL_SCALE,
      angle = CR.orientationTurns(card.orientation) * 2 * math.pi, cardBacks = cardBacks })
    if card == self.selected then
      -- Match the card's footprint: turned cards are landscape around the same center.
      local turned = CR.orientationTurns(card.orientation) ~= 0
      local hw, hh = turned and PH or PW, turned and PW or PH
      ui.rect("line", cx - hw / 2 - 4, ty + PH / 2 - hh / 2 - 4, hw + 8, hh + 8, 8, theme.fixed.blue, 2)
    end
    ui.text(card.cardTitle, tx, ty + PH + 6, { size = 11, w = tileW, align = "center", maxLines = NAME_LINES })
    if r.clicked then
      self.selected = card
      ui.blur()
    end
  end)
end

---------------------------------------------------------------------------
-- Preview
---------------------------------------------------------------------------

local function turnsOf(orientation)
  if orientation == "right" then return 1 end
  if orientation == "left" then return -1 end
  return 0
end

-- A card drawn as large as fits the box, turned to its orientation.
local function fitCard(def, faceUp, orientation, cardBacks, x, y, w, h)
  local turned = orientation ~= "portrait"
  local bw, bh = turned and CH or CW, turned and CW or CH
  local s = math.min(w / bw, h / bh)
  CR.draw({ def = def, faceUp = faceUp, cx = x + w / 2, cy = y + h / 2, scale = s,
    angle = CR.orientationTurns(orientation) * 2 * math.pi, cardBacks = cardBacks })
end

-- The front: the actual image uncropped at its own aspect ratio (unlike
-- the grid tiles), or the drawn card face when it has none.
function T:drawFrontPane(card, x, y, w, h)
  ui.rect("fill", x, y, w, h, 0, { 0, 0, 0, 0.05 })
  local display = common.displayCard(self.editor.folderPath, card)
  local px, py, pw, ph = x + 20, y + 20, w - 40, h - 40
  local drawn = common.drawImageInBox(display.imagePath, px, py, pw, ph, "contain", turnsOf(card.orientation), true)
  if drawn == false then fitCard(display, true, card.orientation, self.displayBacks, px, py, pw, ph) end
end

function T:drawBackPane(card, x, y, w, h)
  ui.rect("fill", x, y, w, h, 0, { 0, 0, 0, 0.05 })
  local display = common.displayCard(self.editor.folderPath, card)
  local _, _, orientation = resolver.resolveCardBackImagePath(self.displayBacks, display)
  fitCard(display, false, orientation or "portrait", self.displayBacks, x + 20, y + 20, w - 40, h - 40)
end

function T:drawPreview(x, y, w, h, visible)
  local c = theme.c
  local card = self.selected
  local controlsH = 8 + 40 + 28 + 8
  local ph = h - controlsH
  if not card then
    ui.text("Select a card to preview", x, y, { w = w, h = ph, align = "center", valign = "middle", color = c.onSurfaceVariant })
  elseif card.cardBackId == nil then
    self:drawFrontPane(card, x, y, w, ph)
  else
    local pw = (w - 12) / 2
    local labelH = 8 + 16
    self:drawFrontPane(card, x, y, pw, ph - labelH)
    ui.text("Front", x, y + ph - 16, { w = pw, size = 12, align = "center", color = c.onSurfaceVariant })
    self:drawBackPane(card, x + pw + 12, y, pw, ph - labelH)
    ui.text("Back", x + pw + 12, y + ph - 16, { w = pw, size = 12, align = "center", color = c.onSurfaceVariant })
  end
  -- Previous / position / next on the left, the Tab options on the right.
  local by = y + ph + 8
  local i = indexOf(visible, card)
  local canPrev = i > 1
  local canNext = #visible > 0 and (i == -1 or i < #visible)
  if ui.iconButton("chevron_left", x + 4, by, { id = "cv:prev", tooltip = "Previous Card", disabled = not canPrev }) then
    self:selectRelative(-1)
  end
  local pos = (i > 0 and i or "-") .. " / " .. #visible
  local posW = math.max(56, ui.textWidth(pos, 12) + 12)
  ui.text(pos, x + 44, by, { w = posW, h = 40, size = 12, align = "center", valign = "middle", color = c.onSurfaceVariant })
  if ui.iconButton("chevron_right", x + 44 + posW, by, { id = "cv:next", tooltip = "Next Card", disabled = not canNext }) then
    self:selectRelative(1)
  end
  -- The two Tab options, right-aligned: one beside the arrows, one below.
  local options = {
    { id = "cv:tabnav", key = "tabNavigatesInsideForm", label = "Tab navigates inside form fields" },
    { id = "cv:tabtitle", key = "tabFocusesTitle", label = "Tab focuses and selects Card Title" },
  }
  local minX = x + 44 + posW + 40 + 16
  for oi, o in ipairs(options) do
    local oy = oi == 1 and by + 11 or by + 40 + 5
    local cbW = 18 + 8 + ui.textWidth(o.label, 14)
    local fits = (oi == 1 and minX or x + 8) + cbW <= x + w - 8
    if fits then
      self[o.key] = ui.checkbox(o.id, x + w - 8 - cbW, oy, self[o.key], { label = o.label })
    else
      self[o.key] = ui.checkbox(o.id, x + w - 8 - 18, oy, self[o.key], { tooltip = o.label })
    end
  end
end

---------------------------------------------------------------------------
-- Detail form (CardDetailPanel)
---------------------------------------------------------------------------

-- Extra fields are edited as an ordered list of rows so a key can be
-- renamed in place; the card's map is rebuilt from the rows on each edit.
function T:extraRows(card)
  local st = ui.state("cv:extra:" .. keyOf(card))
  if not st.rows or st.source ~= card.extraFields then
    local rows = {}
    local mt = getmetatable(card.extraFields)
    local keys = {}
    if mt and mt.__order then
      local seen = {}
      for _, k in ipairs(mt.__order) do
        if card.extraFields[k] ~= nil and not seen[k] then
          seen[k] = true
          keys[#keys + 1] = k
        end
      end
    end
    local listed = util.toSet(keys)
    local rest = {}
    for k in pairs(card.extraFields) do
      if not listed[k] then rest[#rest + 1] = k end
    end
    table.sort(rest)
    for _, k in ipairs(rest) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do rows[#rows + 1] = { key = k, value = tostring(card.extraFields[k]) } end
    st.rows = rows
    st.source = card.extraFields
  end
  return st
end

local function writeExtraFields(card, st)
  local o = json.object()
  for _, r in ipairs(st.rows) do o[r.key] = r.value end
  card.extraFields = o
  st.source = o
end

function T:confirmDelete(card)
  overlays.confirm("Delete Card", 'Delete "' .. card.cardTitle .. '"? This does not delete its image file.', "Delete",
    function() self:deleteCard(card) end)
end

function T:drawForm(card, x, y, w, h)
  local c = theme.c
  local editor = self.editor
  local game = editor.game
  local k = "cv:form:" .. keyOf(card)
  local G = common.GAP
  local nextCard = function(shift) self:tabToCard(shift and -1 or 1) end
  local fieldOpts = function(label)
    return { label = label, h = 44, onTab = self.tabNavigatesInsideForm and nextCard or nil }
  end

  local sel = self.formTab == "extra" and 2 or 1
  local newSel = widgets.tabBar("cv:formtab", x, y, w, { "Main Data", "Extra Data" }, sel)
  self.formTab = newSel == 2 and "extra" or "main"
  y, h = y + widgets.tabBarHeight, h - widgets.tabBarHeight

  if self.formTab == "extra" then
    self:drawExtraFields(card, x, y, w, h)
    return
  end

  -- With tabFocusesTitle on, Tab in the title moves on to the next card too.
  local titleOpts = fieldOpts("Card Title")
  if self.tabFocusesTitle then titleOpts.onTab = nextCard end
  local off = ui.beginScroll("cv:form:main", x, y, w, h)
  local pad = 16
  local fx, fw = x + pad, w - 2 * pad
  local hw = (fw - G) / 2
  local yy = y + pad - off

  -- Title and delete.
  card.cardTitle = ui.textField(k .. ":title", fx, yy, fw - 48, card.cardTitle, titleOpts)
  if ui.iconButton("delete_outline", fx + fw - 40, yy + 2, { id = k .. ":delete", tooltip = "Delete Card" }) then
    self:confirmDelete(card)
  end
  yy = yy + 44 + G

  -- Orientation and set side by side.
  local hasSets = #game.sets > 0
  card.orientation = ui.dropdown(k .. ":orient", fx, yy, hasSets and hw or fw, common.orientationOptions, card.orientation,
    { label = "Orientation", h = 44 })
  if hasSets then
    local options = { { value = nil, label = "(none)" } }
    for _, s in ipairs(game.sets) do options[#options + 1] = { value = s.id, label = s.name } end
    card.setId = ui.dropdown(k .. ":set", fx + hw + G, yy, hw, options, card.setId, { label = "Set", h = 44 })
  end
  yy = yy + 44 + G

  -- Image: file name, Choose, and Clear on one line.
  local chooseW = ui.buttonWidth("Choose...")
  local nameW = fw - chooseW - 4 - (card.imagePath and 44 or 0)
  ui.rect("line", fx + 0.5, yy + 0.5, nameW - 1, 43, 4, c.outline)
  local lf = theme.font(12)
  ui.rect("fill", fx + 8, yy - 2, lf:getWidth("Image") + 8, 4, 0, c.surface)
  ui.text("Image", fx + 12, yy - lf:getHeight() / 2, { font = lf, color = c.onSurfaceVariant })
  ui.text(card.imagePath or "(no image)", fx + 12, yy, { w = nameW - 24, h = 44, valign = "middle", ellipsis = true,
    color = card.imagePath and c.onSurface or c.onSurfaceVariant })
  if ui.button("Choose...", fx + nameW + 4, yy + 2, chooseW, 40, { variant = "outlined", id = k .. ":choose",
    tooltip = "Choose Image..." }) then
    local dest = card.setId == nil and editor.folderPath or fs.join(editor.folderPath, card.setId)
    common.chooseImage(dest, true, function(name)
      if name then card.imagePath = name end
    end)
  end
  if card.imagePath ~= nil then
    if ui.iconButton("close", fx + fw - 40, yy + 2, { id = k .. ":clear", tooltip = "Clear Image" }) then
      card.imagePath = nil
    end
  end
  yy = yy + 44 + G

  -- Card back, plus its orientation when Unique.
  local backOptions = { { value = nil, label = "(Default)" } }
  for _, b in ipairs(game.cardBacks) do backOptions[#backOptions + 1] = { value = b.id, label = b.name } end
  backOptions[#backOptions + 1] = { value = models.uniqueCardBackId, label = "Unique" }
  local unique = card.cardBackId == models.uniqueCardBackId
  card.cardBackId = ui.dropdown(k .. ":back", fx, yy, unique and hw or fw, backOptions, card.cardBackId,
    { label = "Card Back", h = 44 })
  if unique then
    card.uniqueBackOrientation = ui.dropdown(k .. ":backorient", fx + hw + G, yy, hw, common.orientationOptions,
      card.uniqueBackOrientation, { label = "Back Orientation", h = 44 })
  end
  yy = yy + 44

  -- One collapsible chip section per non-empty tag group.
  for _, group in ipairs(game.tagGroups) do
    if #group.tags > 0 then
      yy = yy + G
      local hidden = self.hiddenTagGroups[group.id] == true
      local on = 0
      for _, tag in ipairs(group.tags) do if tagMatch.hasTag(card.types, group.name, tag) then on = on + 1 end end
      if common.collapseHeader(k .. ":vis:" .. group.id, group.name, fx - 4, yy, fw + 4, 32, not hidden,
        on > 0 and (on .. " selected") or nil) then
        self.hiddenTagGroups[group.id] = not hidden or nil
      end
      yy = yy + 32
      if not hidden then
        yy = yy + 6
        local place, bottom = widgets.flow(fx, yy, fw, widgets.chipHeight, 8)
        for ti, tag in ipairs(group.tags) do
          local isOn = tagMatch.hasTag(card.types, group.name, tag)
          local px, py = place(widgets.chipWidth(tag, isOn))
          if widgets.chip(tag, px, py, isOn, { id = k .. ":tag:" .. group.id .. ":" .. ti }) then
            if isOn then
              tagMatch.removeTag(card.types, group.name, tag)
            else
              card.types[#card.types + 1] = tagMatch.encode(group.name, tag)
            end
          end
        end
        yy = bottom()
      end
    end
  end

  local th
  card.unownable, th = common.toggleRow(k .. ":unownable", "Unownable",
    "Always stays unowned on the table -- any player can interact with it", fx, yy, fw, card.unownable)
  yy = yy + th + pad
  card.isFreeCard, th = common.toggleRow(k .. ":freecard", "Free Card",
    "On collection-mode servers, every player always has unlimited copies", fx, yy, fw, card.isFreeCard)
  yy = yy + th + pad
  if game.hasScenarios then
    card.isScenarioCard, th = common.toggleRow(k .. ":scenariocard", "Scenario Card",
      "Belongs to a scenario's card pool (Card Placement / Deck Builder) instead of the regular player card pool",
      fx, yy, fw, card.isScenarioCard)
    yy = yy + th + pad
  end
  ui.endScroll("cv:form:main", yy + off - y)
end

-- The "Extra Data" tab: one row per extraField, key above a wrapping
-- 3-line value box so longer strings (e.g. an episode synopsis) stay
-- readable and editable.
function T:drawExtraFields(card, x, y, w, h)
  local k = "cv:form:" .. keyOf(card)
  local nextCard = function(shift) self:tabToCard(shift and -1 or 1) end
  local onTab = self.tabNavigatesInsideForm and nextCard or nil
  local off = ui.beginScroll("cv:form:extra", x, y, w, h)
  local pad = 16
  local fx, fw = x + pad, w - 2 * pad
  local yy = y + pad - off

  local extra = self:extraRows(card)
  local removeRow
  local valueH = ui.textAreaHeight(3)
  for i, row in ipairs(extra.rows) do
    local rk = k .. ":extra" .. i
    local newKey = ui.textField(rk .. ":k", fx, yy, fw - 48, row.key, { label = "Key", h = 44, onTab = onTab })
    if ui.iconButton("close", fx + fw - 40, yy + 2, { id = rk .. ":rm", tooltip = "Remove Field" }) then removeRow = i end
    yy = yy + 44 + 8
    local newValue = ui.textArea(rk .. ":v", fx, yy, fw, valueH, row.value, { label = "Value", onTab = onTab })
    if newKey ~= row.key or newValue ~= row.value then
      row.key, row.value = newKey, newValue
      writeExtraFields(card, extra)
    end
    yy = yy + valueH + 16
  end
  if removeRow then
    table.remove(extra.rows, removeRow)
    writeExtraFields(card, extra)
  end
  if ui.button("Add Field", fx - 8, yy, nil, 40, { variant = "text", icon = "add", id = k .. ":addfield" }) then
    local taken = {}
    for _, r in ipairs(extra.rows) do taken[r.key] = true end
    local newKey, suffix = "field", 1
    while taken[newKey] do
      newKey = "field" .. suffix
      suffix = suffix + 1
    end
    extra.rows[#extra.rows + 1] = { key = newKey, value = "" }
    writeExtraFields(card, extra)
  end
  yy = yy + 40 + 12
  ui.endScroll("cv:form:extra", yy + off - y)
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

-- A draggable column divider; returns the horizontal drag delta.
local function splitHandle(id, x, y, h)
  local r = ui.region(id, x, y, DIVIDER, h, { cursor = "sizewe" })
  ui.rect("fill", x + math.floor(DIVIDER / 2), y, 1, h, 0, theme.c.outlineVariant)
  local st = ui.state(id)
  local mx = ui.mouse()
  local dx = 0
  if r.held then
    if st.lastX then dx = mx - st.lastX end
    st.lastX = mx
  else
    st.lastX = nil
  end
  if r.held then ui.setCursor("sizewe") end
  return dx
end

function T:draw(x, y, w, h)
  local game = self.editor.game
  self:syncFilters()
  if self.selected and indexOf(game.cards, self.selected) == -1 then self.selected = nil end
  self.displayBacks = common.displayCardBacks(self.editor.folderPath, game.cardBacks)

  local yy = filterBar.drawFilters("cv", self.filters, game, x + 12, y, w - 24, { compact = true,
    leading = { { label = "Add Card", icon = "add", id = "cv:add", onClick = function() self:addBlankCard() end } } })
  yy = filterBar.drawSearch("cv", self.filters, game, x + 12, yy + 12, w - 24, { labelBackground = theme.c.surface })
  if yy > y then yy = yy + 4 end
  local visible = self:visibleCards()
  local bh = y + h - yy
  local usable = w - DIVIDER * 2
  local poolW = math.floor(usable * self.poolFraction)
  local previewW = math.floor(usable * self.previewFraction)
  local formW = usable - poolW - previewW

  ui.pushClip(x, yy, poolW, bh)
  self:drawPool(x, yy, poolW, bh, visible)
  ui.popClip()
  local d1x = x + poolW
  local dx = splitHandle("cv:split1", d1x, yy, bh)
  if dx ~= 0 then
    local df = util.clamp(dx / usable, MIN_FRACTION - self.poolFraction, self.previewFraction - MIN_FRACTION)
    self.poolFraction = self.poolFraction + df
    self.previewFraction = self.previewFraction - df
  end
  local px = d1x + DIVIDER
  ui.pushClip(px, yy, previewW, bh)
  self:drawPreview(px, yy, previewW, bh, visible)
  ui.popClip()
  local d2x = px + previewW
  dx = splitHandle("cv:split2", d2x, yy, bh)
  if dx ~= 0 then
    local formFraction = 1 - self.poolFraction - self.previewFraction
    local df = util.clamp(dx / usable, MIN_FRACTION - self.previewFraction, formFraction - MIN_FRACTION)
    self.previewFraction = self.previewFraction + df
  end
  local fx = d2x + DIVIDER
  ui.pushClip(fx, yy, formW, bh)
  if self.selected then
    self:drawForm(self.selected, fx, yy, formW, bh)
  else
    ui.text("Select a card to edit", fx, yy, { w = formW, h = bh, align = "center", valign = "middle", color = theme.c.onSurfaceVariant })
  end
  ui.popClip()
end

return T
