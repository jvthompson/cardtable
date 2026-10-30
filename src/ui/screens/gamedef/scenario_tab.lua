-- The Scenarios tab: named setups (shared zones, starting entries or a
-- built subdeck, and cards placed on the table) a host can load from the
-- in-game menu. Shown only while game.hasScenarios is on (see
-- gamedef_editor.lua). Edits apply straight to game.scenarios; nothing is
-- saved to separate files.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local panel = require("src.ui.kit.panel")
local widgets = require("src.ui.kit.widgets")
local filterBar = require("src.ui.kit.card_filter_bar")
local poolGrid = require("src.ui.table.card_pool_grid")
local listDetail = require("src.ui.kit.list_detail")
local models = require("src.core.models")
local util = require("src.core.util")
local uuid = require("src.core.uuid")
local common = require("src.ui.screens.gamedef.common")
local CR = require("src.ui.table.card_render")
local color = require("src.core.color")
local tableSettings = require("src.data.table_settings")
local fs = require("src.data.fs")
local colorpicker = require("src.ui.kit.colorpicker")

local keyOf = common.keyOf

local function isInteger(s) return s:match("^%-?%d+$") ~= nil end

local T = {}
T.__index = T

function T.new(editor)
  return setmetatable({
    editor = editor,
    view = "zones",
    zonesSubByScenario = {},
    activeDeckTypeByScenario = {},
    deckPoolScenario = true,
    placementLibraryScenario = true,
  }, T)
end

local ROW_H = 56
local SIDE_OPTIONS = { { value = "left", label = "Left" }, { value = "right", label = "Right" } }
local ZONE_KIND_OPTIONS = { { value = "card", label = "Card Zone" }, { value = "widget", label = "Widget Zone" } }
-- Any new widget kind here needs fields in T.drawScenarioZoneDetail's widget
-- branch below AND in zones_tab.lua's T:drawWidgetZoneFields -- the Token
-- Bag and Counter-image features each initially missed the scenario side.
local ZONE_WIDGET_KIND_OPTIONS = { { value = "counter", label = "Counter" }, { value = "tokenBag", label = "Token Bag" } }
local VIEW_OPTIONS = {
  { value = "zones", label = "Zones" },
  { value = "placement", label = "Card Placement" },
  { value = "deck", label = "Deck Builder" },
}
local SCENARIO_MODE_OPTIONS = { { value = false, label = "Player Cards" }, { value = true, label = "Scenario Cards" } }

---------------------------------------------------------------------------
-- Top-level scenario list / detail
---------------------------------------------------------------------------

-- Deep copy with a fresh scenario id and fresh zone ids (so both the
-- original and the copy can be loaded into the same session without their
-- shared zones colliding); placements and decks need no id changes.
function T:duplicateScenario(scenario)
  local game = self.editor.game
  local copy = util.deepCopy(scenario)
  copy.id = uuid.v4()
  copy.name = scenario.name .. " Copy"
  for _, z in ipairs(copy.zones) do z.id = uuid.v4() end
  game.scenarios[#game.scenarios + 1] = copy
  self.selected = copy
end

function T:openDuplicateScenarioMenu(x, y)
  local game = self.editor.game
  local items = {}
  for _, s in ipairs(game.scenarios) do
    items[#items + 1] = { label = s.name == "" and "(unnamed scenario)" or s.name,
      onSelect = function() self:duplicateScenario(s) end }
  end
  overlays.menu(x, y, items)
end

function T.drawScenarioList(self, x, y, w, h)
  local c = theme.c
  local game = self.editor.game
  ui.rect("fill", x, y, w, h, 0, c.surfaceContainer)
  local hh = common.sectionHeader("scen:list", "Scenarios", x + 16, y + 12, w - 32, { count = #game.scenarios })
  local bx, bw = x + 16, w - 32
  local by = y + 12 + hh + 4
  if ui.button("Add Scenario", bx, by, bw, 40, { variant = "tonal", icon = "add", id = "scen:add" }) then
    local scenario = models.Scenario.new({ id = uuid.v4(), name = "New Scenario" })
    game.scenarios[#game.scenarios + 1] = scenario
    self.selected = scenario
  end
  by = by + 40 + 8
  if ui.button("Duplicate Scenario...", bx, by, bw, 40,
    { variant = "outlined", icon = "copy_all", id = "scen:dup", disabled = #game.scenarios == 0 }) then
    self:openDuplicateScenarioMenu(bx, by + 40 + 4)
  end
  local ly = by + 40 + 12
  local lh = y + h - ly
  local off = ui.beginScroll("scen:list:scroll", x, ly, w, lh)
  local ro = widgets.reorder("scen:scenarios")
  local yy = ly - off
  for i, scenario in ipairs(game.scenarios) do
    local rx, rw = x + 8, w - 16
    local sel = scenario == self.selected
    local r = ui.region("scen:row:" .. keyOf(scenario), rx + 40, yy, rw - 40, ROW_H, { cursor = "hand" })
    if sel then
      ui.rect("fill", rx, yy, rw, ROW_H, 8, c.secondaryContainer)
    elseif r.hovered then
      ui.rect("fill", rx, yy, rw, ROW_H, 8, theme.alpha(c.onSurface, 0.05))
    end
    ro:handle(i, rx, yy + (ROW_H - 40) / 2, yy, ROW_H)
    local fg = sel and c.onSecondaryContainer or c.onSurface
    ui.icon("folder", rx + 42, yy + (ROW_H - 20) / 2, 20, sel and fg or c.onSurfaceVariant)
    local tx = rx + 72
    ui.text(scenario.name == "" and "(unnamed scenario)" or scenario.name, tx, yy + 9,
      { w = rx + rw - 8 - tx, ellipsis = true, weight = sel and "medium" or nil, color = fg })
    local subtitle = #scenario.zones .. " zone(s) \xc2\xb7 " .. #scenario.placements .. " placed"
    ui.text(subtitle, tx, yy + 30, { w = rx + rw - 8 - tx, ellipsis = true, size = 12, color = c.onSurfaceVariant })
    if r.clicked then
      self.selected = scenario
      ui.blur()
    end
    yy = yy + ROW_H + 2
  end
  local from, to = ro:finish(x + 8, w - 16)
  if from then widgets.moveItem(game.scenarios, from, to) end
  ui.endScroll("scen:list:scroll", #game.scenarios * (ROW_H + 2) + 12)
end

function T.drawScenarioDetail(self, scenario, x, y, w, h)
  local cx, cw = common.column(x, w)
  local yy = y + common.PAD
  local bw = ui.buttonWidth("Delete Scenario", { icon = "delete_outline" })
  scenario.name = ui.textField("scen:name", cx, yy, cw - bw - common.GAP, scenario.name, { label = "Scenario Name" })
  if ui.button("Delete Scenario", cx + cw - bw, yy, bw, common.FIELD_H,
    { variant = "text", icon = "delete_outline", id = "scen:del" }) then
    self.pendingRemove = scenario
  end
  yy = yy + common.FIELD_H + 16
  self.view = ui.segmented("scen:view", cx, yy, math.min(cw, 480), VIEW_OPTIONS, self.view, { h = 40 })
  yy = yy + 40 + 16

  ui.pushClip(x, yy, w, y + h - yy)
  if self.view == "placement" then
    self:drawPlacementView(scenario, x, yy, w, y + h - yy)
  elseif self.view == "deck" then
    self:drawDeckBuilderView(scenario, x, yy, w, y + h - yy)
  else
    self:drawZonesView(scenario, x, yy, w, y + h - yy)
  end
  ui.popClip()
end

function T:draw(x, y, w, h)
  local game = self.editor.game
  self.pendingRemove = nil
  self.hoveredId = nil
  listDetail.draw(self, x, y, w, h, game.scenarios, 300, T.drawScenarioList, T.drawScenarioDetail,
    "Add a scenario to get started")
  if self.pendingRemove then
    local i
    for j, s in ipairs(game.scenarios) do
      if s == self.pendingRemove then i = j end
    end
    util.removeValue(game.scenarios, self.pendingRemove)
    self.selected = i and game.scenarios[math.min(i, #game.scenarios)] or nil
    self.pendingRemove = nil
  end
  ui.overlay(function() self:drawPreview() end)
end

function T:keypressed(key)
  if self.view ~= "placement" or not self.selected or not self.selectedPlacement then return end
  if key == "f" then
    self.selectedPlacement.faceUp = not self.selectedPlacement.faceUp
  elseif key == "delete" or key == "backspace" then
    util.removeValue(self.selected.placements, self.selectedPlacement)
    self.selectedPlacement = nil
  end
end

---------------------------------------------------------------------------
-- Zones sub-view: a nested list + detail over scenario.zones.
---------------------------------------------------------------------------

function T:drawZonesView(scenario, x, y, w, h)
  local sub = self.zonesSubByScenario[keyOf(scenario)]
  if not sub then
    sub = {}
    self.zonesSubByScenario[keyOf(scenario)] = sub
  end
  sub.scenario, sub.editor, sub.pendingRemove = scenario, self.editor, nil
  listDetail.draw(sub, x, y, w, h, scenario.zones, 260, T.drawScenarioZoneList, T.drawScenarioZoneDetail,
    "Add a zone to get started")
  if sub.pendingRemove then
    local i
    for j, z in ipairs(scenario.zones) do
      if z == sub.pendingRemove then i = j end
    end
    util.removeValue(scenario.zones, sub.pendingRemove)
    sub.selected = i and scenario.zones[math.min(i, #scenario.zones)] or nil
  end
end

local function scenarioZoneBadge(zone)
  if zone.kind == "widget" then
    if zone.widgetKind == "tokenBag" then
      local total = 0
      for _, e in ipairs(zone.bagEntries) do total = total + e.quantity end
      return total .. " token" .. (total == 1 and "" or "s")
    end
    return "Counter"
  end
  return zone.dealsBuiltDeck and ("Deck: " .. zone.deckType) or (#zone.entries .. " entries")
end

function T.drawScenarioZoneList(sub, x, y, w, h)
  local c = theme.c
  local scenario = sub.scenario
  ui.rect("fill", x, y, w, h, 0, c.surfaceContainer)
  local hh, add = common.sectionHeader("scen:zlist", "Zones", x + 16, y + 12, w - 32, {
    count = #scenario.zones, action = { label = "Add Zone", icon = "add", id = "scen:zadd" } })
  if add then
    local zone = models.ZoneDefinition.new({ id = uuid.v4(), name = "New Zone", shared = true })
    scenario.zones[#scenario.zones + 1] = zone
    sub.selected = zone
  end
  local ly = y + 12 + hh + 8
  local lh = y + h - ly
  local off = ui.beginScroll("scen:zlist:scroll:" .. keyOf(scenario), x, ly, w, lh)
  local ro = widgets.reorder("scen:zones:" .. keyOf(scenario))
  local yy = ly - off
  for i, zone in ipairs(scenario.zones) do
    local rx, rw = x + 8, w - 16
    local sel = zone == sub.selected
    local r = ui.region("scen:zrow:" .. keyOf(zone), rx + 40, yy, rw - 40, ROW_H, { cursor = "hand" })
    if sel then
      ui.rect("fill", rx, yy, rw, ROW_H, 8, c.secondaryContainer)
    elseif r.hovered then
      ui.rect("fill", rx, yy, rw, ROW_H, 8, theme.alpha(c.onSurface, 0.05))
    end
    ro:handle(i, rx, yy + (ROW_H - 40) / 2, yy, ROW_H)
    local fg = sel and c.onSecondaryContainer or c.onSurface
    ui.icon(zone.kind == "card" and "layers" or "widgets", rx + 42, yy + (ROW_H - 20) / 2, 20, sel and fg or c.onSurfaceVariant)
    local tx = rx + 72
    ui.text(zone.name == "" and "(unnamed zone)" or zone.name, tx, yy + 9,
      { w = rx + rw - 8 - tx, ellipsis = true, weight = sel and "medium" or nil, color = fg })
    local badge = scenarioZoneBadge(zone)
    ui.text(badge, tx, yy + 30, { w = rx + rw - 8 - tx, ellipsis = true, size = 12, color = c.onSurfaceVariant })
    if r.clicked then
      sub.selected = zone
      ui.blur()
    end
    yy = yy + ROW_H + 2
  end
  local from, to = ro:finish(x + 8, w - 16)
  if from then widgets.moveItem(scenario.zones, from, to) end
  ui.endScroll("scen:zlist:scroll:" .. keyOf(scenario), #scenario.zones * (ROW_H + 2) + 12)
end

-- A labelled sub-group heading with a little space above (matches
-- zones_tab.lua's own `group` helper). Returns the height used.
local function group(text, x, y, w)
  return 20 + common.groupLabel(text, x, y + 20, w) + 2
end

-- Mirrors zones_tab.lua's T:drawTokenBagFields, for a scenario-defined
-- widget zone: the bag's own idle image, the returnable toggle, and its
-- contents (token image + quantity per row).
local function drawScenarioTokenBagFields(sub, zone, k, x, y, w)
  local c = theme.c
  local folderPath = sub.editor.folderPath
  local yy = y
  local THUMB = 56
  local thumb = ui.region(k .. ":bagimg", x, yy, THUMB, THUMB, { cursor = "hand", tooltip = "Choose Bag Image..." })
  common.imagePreviewBox(zone.bagImagePath and fs.join(folderPath, "tokens", zone.bagImagePath), x, yy, THUMB, THUMB)
  if thumb.clicked then
    common.chooseTokenImage(folderPath, function(file) zone.bagImagePath = file end)
  end
  ui.text(zone.bagImagePath or "(no bag image)", x + THUMB + 12, yy, { w = w - THUMB - 12, h = THUMB,
    valign = "middle", ellipsis = true, color = zone.bagImagePath and c.onSurface or c.onSurfaceVariant })
  yy = yy + THUMB + 12

  local th
  zone.bagReturnable, th = common.toggleRow(k .. ":returnable", "Returnable",
    "A returned token goes back into the bag's contents; off, it's destroyed instead", x, yy, w, zone.bagReturnable)
  yy = yy + th + 12

  yy = yy + common.groupLabel("Contents", x, yy, w) + 4
  local images = common.tokenFolderImages(folderPath)
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

-- Mirrors zones_tab.lua's counter branch of T:drawWidgetZoneFields, for a
-- scenario-defined widget zone: an optional image (replaces the solid fill
-- as the counter's main graphic; its color becomes a small accent circle
-- behind the number), starting value, and starting/text colors.
local function drawScenarioCounterFields(sub, zone, k, x, y, w)
  local c = theme.c
  local folderPath = sub.editor.folderPath
  local yy = y
  local hw = (w - common.GAP) / 2
  local THUMB = 56
  local thumb = ui.region(k .. ":counterimg", x, yy, THUMB, THUMB, { cursor = "hand", tooltip = "Choose Counter Image..." })
  common.imagePreviewBox(zone.counterImagePath and fs.join(folderPath, "tokens", zone.counterImagePath), x, yy, THUMB, THUMB)
  if thumb.clicked then
    common.chooseTokenImage(folderPath, function(file) zone.counterImagePath = file end)
  end
  ui.text(zone.counterImagePath or "(no image)", x + THUMB + 12, yy, { w = w - THUMB - 12, h = THUMB,
    valign = "middle", ellipsis = true, color = zone.counterImagePath and c.onSurface or c.onSurfaceVariant })
  yy = yy + THUMB + common.GAP

  local function valueOf(s) return isInteger(s) and tonumber(s) or 0 end
  local st = ui.state(k .. ":startText")
  if st.text == nil or valueOf(st.text) ~= zone.counterStartingValue then
    st.text = tostring(zone.counterStartingValue)
  end
  st.text = ui.textField(k .. ":start", x, yy, hw, st.text, { label = "Starting Value",
    filter = function(s) return s:match("^[%d%-]*$") ~= nil end })
  zone.counterStartingValue = valueOf(st.text)
  yy = yy + common.FIELD_H + common.GAP

  local h1, h2
  zone.counterStartingColor, h1 = colorpicker.field(k .. ":color", x, yy, hw, zone.counterStartingColor,
    { hexLabel = "Starting Color (hex)" })
  zone.counterStartingTextColor, h2 = colorpicker.field(k .. ":textcolor", x + hw + common.GAP, yy, hw, zone.counterStartingTextColor,
    { hexLabel = "Starting Text Color (hex)" })
  yy = yy + math.max(h1, h2)
  return yy - y
end

function T.drawScenarioZoneDetail(sub, zone, x, y, w, h)
  -- Scenario zones are always shared.
  zone.shared = true
  local k = "scen:zone:" .. keyOf(zone)
  local off = ui.beginScroll("scen:zdetail", x, y, w, h)
  local cx, cw = common.column(x, w)
  local yy = y + common.PAD - off

  ui.text(zone.name == "" and "(unnamed zone)" or zone.name, cx, yy,
    { size = 20, weight = "medium", h = 40, valign = "middle", w = cw - 160, ellipsis = true })
  local bw = ui.buttonWidth("Delete Zone", { icon = "delete_outline" })
  if ui.button("Delete Zone", cx + cw - bw, yy, bw, 40, { variant = "text", icon = "delete_outline", id = k .. ":del" }) then
    sub.pendingRemove = zone
  end
  yy = yy + 40 + 16

  local G = common.GAP
  local hw = (cw - G) / 2
  zone.name = ui.textField(k .. ":name", cx, yy, hw, zone.name, { label = "Zone Name" })
  zone.id = ui.textField(k .. ":id", cx + hw + G, yy, hw, zone.id, { label = "Zone ID" })
  yy = yy + common.FIELD_H + 20

  zone.kind = ui.segmented(k .. ":kind", cx, yy, math.min(cw, 320), ZONE_KIND_OPTIONS, zone.kind)
  yy = yy + 40 + 20

  if zone.kind == "widget" then
    zone.widgetKind = ui.dropdown(k .. ":wkind", cx, yy, hw, ZONE_WIDGET_KIND_OPTIONS, zone.widgetKind, { label = "Widget Type" })
    ui.text("Side", cx + hw + G, yy + 4, { h = 40, valign = "middle", color = theme.c.onSurfaceVariant })
    zone.side = ui.segmented(k .. ":side", cx + hw + G + 40, yy + 4, hw - 40, SIDE_OPTIONS, zone.side)
    yy = yy + common.FIELD_H + G
    if zone.widgetKind == "tokenBag" then
      yy = yy + drawScenarioTokenBagFields(sub, zone, k, cx, yy, cw)
    else
      yy = yy + drawScenarioCounterFields(sub, zone, k, cx, yy, cw)
    end
    yy = yy + common.PAD
    ui.endScroll("scen:zdetail", yy + off - y)
    return
  end

  yy = yy + group("Display", cx, yy, cw)
  ui.text("Side", cx, yy + 4, { h = 40, valign = "middle", color = theme.c.onSurfaceVariant })
  zone.side = ui.segmented(k .. ":side", cx + 40, yy + 4, hw - 40, SIDE_OPTIONS, zone.side)
  zone.orientation = ui.dropdown(k .. ":orient", cx + hw + G, yy, hw, common.orientationOptions, zone.orientation,
    { label = "Zone Orientation" })
  yy = yy + common.FIELD_H + 8

  yy = yy + group("Behavior", cx, yy, cw)
  yy = yy + common.toggleGrid({
    { id = k .. ":faceup", label = "Face Up", help = "Cards in this zone show their real face",
      get = function() return zone.faceUp end, set = function(v) zone.faceUp = v end },
    { id = k .. ":shuffleable", label = "Shuffleable", help = "Show a shuffle button for this zone",
      get = function() return zone.shuffleable end, set = function(v) zone.shuffleable = v end },
    { id = k .. ":autoshuffle", label = "Auto Shuffle", help = "Randomize this zone's order when the scenario loads",
      get = function() return zone.autoShuffle end, set = function(v) zone.autoShuffle = v end },
    { id = k .. ":discard", label = "Is Discard Pile", help = "Pressing D sends a hovered table card here",
      get = function() return zone.isDiscardPile end, set = function(v) zone.isDiscardPile = v end },
  }, cx, yy, cw)

  yy = yy + group("Contents", cx, yy, cw)
  local th
  zone.dealsBuiltDeck, th = common.toggleRow(k .. ":deals", "Loads Built Deck",
    "Deals from a named subdeck built in this scenario's Deck Builder sub-view, instead of the entries below",
    cx, yy, cw, zone.dealsBuiltDeck)
  yy = yy + th + 8

  if zone.dealsBuiltDeck then
    -- Deck Name keeps what's typed; an empty field means main_deck.
    local function deckTypeOf(s) return util.trim(s) == "" and "main_deck" or s end
    local st = ui.state(k .. ":decktypetext")
    if st.text == nil or deckTypeOf(st.text) ~= zone.deckType then st.text = zone.deckType end
    local dw = math.min(360, cw)
    st.text = ui.textField(k .. ":decktype", cx, yy, dw, st.text, { label = "Deck Name" })
    zone.deckType = deckTypeOf(st.text)
    yy = yy + common.FIELD_H + 4
    ui.text('Cards come from the "' .. zone.deckType .. '" deck in the Deck Builder sub-view.', cx, yy,
      { w = cw, color = theme.c.onSurfaceVariant })
    yy = yy + 24
  else
    local game = sub.editor.game
    local options = util.map(game.cards, function(card) return { value = card.id, label = card.cardTitle } end)
    local remove
    for i, entry in ipairs(zone.entries) do
      local ek = k .. ":entry" .. i
      local dw = cw - 8 - common.stepperWidth
      local picked = ui.dropdown(ek .. ":card", cx, yy + 4, dw, options, entry.definitionId,
        { h = 40, placeholder = "(unknown card)", size = 14 })
      if picked ~= entry.definitionId then zone.entries[i] = models.DeckEntry.new(picked, entry.quantity) end
      local q, removed = common.stepper(ek, cx + cw, yy + 4, entry.quantity, { removeTooltip = "Remove Entry" })
      if q ~= entry.quantity then zone.entries[i] = models.DeckEntry.new(zone.entries[i].definitionId, q) end
      if removed then remove = i end
      yy = yy + 48
    end
    if remove then table.remove(zone.entries, remove) end
    if ui.button("Add Entry", cx - 8, yy, nil, 40,
      { variant = "text", icon = "add", id = k .. ":addentry", disabled = #game.cards == 0 }) then
      zone.entries[#zone.entries + 1] = models.DeckEntry.new(game.cards[1].id, 1)
    end
    yy = yy + 40
  end
  yy = yy + common.PAD
  ui.endScroll("scen:zdetail", yy + off - y)
end

---------------------------------------------------------------------------
-- Deck Builder sub-view
---------------------------------------------------------------------------

-- One slot per distinct deckType a scenario zone with dealsBuiltDeck
-- declares, labelled by the first zone using it (mirrors deck_editor.lua's
-- buildSlots, but scoped to this scenario's own zones).
local function buildDeckSlots(scenario)
  local slots, byType = {}, {}
  for _, z in ipairs(scenario.zones) do
    if z.dealsBuiltDeck and not byType[z.deckType] then
      byType[z.deckType] = { deckType = z.deckType, label = z.name }
      slots[#slots + 1] = byType[z.deckType]
    end
  end
  return slots
end

function T:activeDeckType(scenario, slots)
  local sk = keyOf(scenario)
  local cur = self.activeDeckTypeByScenario[sk]
  if not util.any(slots, function(s) return s.deckType == cur end) then
    cur = slots[1] and slots[1].deckType
    self.activeDeckTypeByScenario[sk] = cur
  end
  return cur
end

function T:addDeckCopy(scenario, deckType, defId)
  local sd = models.Scenario.subdeck(scenario, deckType)
  if not sd then
    sd = models.SubDeck.new(deckType, {})
    scenario.decks[#scenario.decks + 1] = sd
  end
  for _, e in ipairs(sd.entries) do
    if e.definitionId == defId then
      e.quantity = e.quantity + 1
      return
    end
  end
  sd.entries[#sd.entries + 1] = models.DeckEntry.new(defId, 1)
end

function T:removeDeckCopy(scenario, deckType, defId)
  local sd = models.Scenario.subdeck(scenario, deckType)
  if not sd then return end
  for i, e in ipairs(sd.entries) do
    if e.definitionId == defId then
      if e.quantity <= 1 then
        table.remove(sd.entries, i)
      else
        e.quantity = e.quantity - 1
      end
      return
    end
  end
end

function T:drawDeckPool(scenario, deckType, x, y, w, h)
  local c = theme.c
  local game = self.editor.game
  local yy = y
  local hasScenarioCards = util.any(game.cards, function(card) return card.isScenarioCard == true end)
  if hasScenarioCards then
    self.deckPoolScenario = ui.segmented("scen:deckmode", x + 12, yy + 12, w - 24, SCENARIO_MODE_OPTIONS,
      self.deckPoolScenario, { h = 40 })
    yy = yy + 12 + 40 + 12
  end
  self.deckFilters = self.deckFilters or filterBar.newState(game)
  yy = filterBar.drawFilters("scendeck", self.deckFilters, game, x + 12, yy, w - 24)
  yy = filterBar.drawSearch("scendeck", self.deckFilters, game, x + 12, yy + 12, w - 24, { labelBackground = c.surface }) + 4
  local visible = filterBar.visible(self.deckFilters, game)
  if hasScenarioCards then
    visible = util.filter(visible, function(def) return (def.isScenarioCard == true) == self.deckPoolScenario end)
  end
  local sd = models.Scenario.subdeck(scenario, deckType)
  local nameH = poolGrid.nameH()
  local folder = self.editor.folderPath
  local displayBacks = common.displayCardBacks(folder, game.cardBacks)
  poolGrid.draw("scendeckpool", visible, x, yy, w, y + h - yy, 12, function(def, i, tx, ty, tileW, cx)
    local r = ui.region("scendeck:card:" .. def.id, cx - poolGrid.PW / 2, ty, poolGrid.PW, poolGrid.PH + 6 + nameH,
      { cursor = "hand" })
    CR.draw({ def = common.displayCard(folder, def), faceUp = true, cx = cx, cy = ty + poolGrid.PH / 2, scale = poolGrid.SCALE,
      angle = CR.orientationTurns(def.orientation) * 2 * math.pi, cardBacks = displayBacks, scenarioCardBackId = game.scenarioCardBackId })
    local n = 0
    if sd then
      for _, e in ipairs(sd.entries) do
        if e.definitionId == def.id then n = e.quantity end
      end
    end
    if n > 0 then CR.drawCountBadge(cx + poolGrid.PW / 2 - 12, ty + 12, n, 1) end
    ui.text(def.cardTitle, tx, ty + poolGrid.PH + 6, { size = 11, w = tileW, align = "center", maxLines = poolGrid.NAME_LINES })
    if r.hovered then self.hoveredId = def.id end
    if r.clicked then self:addDeckCopy(scenario, deckType, def.id) end
  end)
end

-- Space preview: a big copy of the hovered pool card, as elsewhere in the
-- app (deck_editor.lua, the table screen). The editor's GameDefinition
-- holds bare image paths, so the preview needs a resolved display copy
-- just like the pool tiles do.
function T:drawPreview()
  if overlays.anyOpen() or ui.focus or not love.keyboard.isDown("space") then return end
  local game = self.editor.game
  local def = self.hoveredId and models.GameDefinition.cardById(game, self.hoveredId)
  if not def then return end
  local folder = self.editor.folderPath
  local display = common.displayCard(folder, def)
  local displayBacks = common.displayCardBacks(folder, game.cardBacks)
  local sw, sh = ui.screenSize()
  CR.drawPreview(CR.definitionFaces(display, displayBacks, game.scenarioCardBackId), displayBacks, sw, sh, (ui.mouse()),
    game.scenarioCardBackId)
end

function T:drawDeckList(scenario, deckType, x, y, w, h)
  local c = theme.c
  local game = self.editor.game
  local sd = models.Scenario.subdeck(scenario, deckType)
  local entries = sd and sd.entries or {}
  if #entries == 0 then
    ui.text("Click a card to add it", x, y, { w = w, h = h, align = "center", valign = "middle", color = c.onSurfaceVariant })
    return
  end
  local rowH = 48
  local off = ui.beginScroll("scendecklist", x, y, w, h)
  local removeId
  for i, e in ipairs(entries) do
    local ry = y + (i - 1) * rowH - off
    if ry + rowH > y and ry < y + h then
      local def = models.GameDefinition.cardById(game, e.definitionId)
      local r = ui.region("scendeckrow:" .. e.definitionId, x, ry, w, rowH, { cursor = "hand" })
      if r.hovered then ui.rect("fill", x, ry, w, rowH, 0, theme.alpha(c.onSurface, 0.08)) end
      local trailing = "\xc3\x97" .. e.quantity
      local tw = ui.textWidth(trailing, 14)
      ui.text(def and def.cardTitle or e.definitionId, x + 16, ry, { h = rowH, valign = "middle", w = w - 48 - tw, ellipsis = true })
      ui.text(trailing, x, ry, { w = w - 16, h = rowH, valign = "middle", align = "right", color = c.onSurfaceVariant })
      if r.clicked then removeId = e.definitionId end
    end
  end
  ui.endScroll("scendecklist", #entries * rowH)
  if removeId then self:removeDeckCopy(scenario, deckType, removeId) end
end

function T:drawDeckBuilderView(scenario, x, y, w, h)
  local c = theme.c
  local slots = buildDeckSlots(scenario)
  if #slots == 0 then
    ui.text('Mark a zone\'s "Loads Built Deck" on in the Zones sub-view to build a deck for it here.',
      x, y, { w = w, h = h, align = "center", valign = "middle", color = c.onSurfaceVariant })
    return
  end
  local activeType = self:activeDeckType(scenario, slots)
  local function slotLabel(s)
    local n = 0
    for _, e in ipairs(models.Scenario.entriesFor(scenario, s.deckType)) do n = n + e.quantity end
    return s.label .. " -- " .. n .. (n == 1 and " card" or " cards")
  end
  local yy = y
  if #slots > 1 then
    local opts = {}
    for _, s in ipairs(slots) do opts[#opts + 1] = { value = s.deckType, label = slotLabel(s) } end
    activeType = ui.dropdown("scen:deckslots", x + 12, yy + 12, w - 24, opts, activeType, { h = 40, size = 14 })
    self.activeDeckTypeByScenario[keyOf(scenario)] = activeType
    yy = yy + 12 + 40 + 12
  else
    ui.text(slotLabel(slots[1]), x + 12, yy + 12, { weight = "bold", w = w - 24, ellipsis = true })
    yy = yy + 12 + 20 + 12
  end
  ui.divider(x, yy, w)
  yy = yy + 1
  local deckW = 240
  local poolW = w - deckW - 1
  ui.rect("fill", x + poolW, yy, 1, y + h - yy, 0, c.outlineVariant)
  self:drawDeckPool(scenario, activeType, x, yy, poolW, y + h - yy)
  self:drawDeckList(scenario, activeType, x + poolW + 1, yy, deckW, y + h - yy)
end

---------------------------------------------------------------------------
-- Card Placement sub-view
---------------------------------------------------------------------------

local WORLD_W, WORLD_H = 2560, 1440

local function canvasRect(x, y, w, h)
  local scale = math.min(w / WORLD_W, h / WORLD_H)
  local cw, ch = WORLD_W * scale, WORLD_H * scale
  return x + (w - cw) / 2, y + (h - ch) / 2, cw, ch, scale
end

function T:drawPlacementLibrary(game)
  self.placementFilters = self.placementFilters or filterBar.newState(game)
  local sw, sh = ui.screenSize()
  local pw, ph = math.min(1280, sw - 40), math.min(720, sh - overlays.contentTop - 40)
  local saved = theme.c
  theme.c = theme.dark
  local x, y, w, h = panel.draw("scenplacelib", pw, ph, "Card Library", function() self.placementLibraryOpen = false end)
  local yy = y
  local hasScenarioCards = util.any(game.cards, function(card) return card.isScenarioCard == true end)
  if hasScenarioCards then
    self.placementLibraryScenario = ui.segmented("scenplacelib:mode", x + 16, yy, w - 32, SCENARIO_MODE_OPTIONS,
      self.placementLibraryScenario, { h = 40 })
    yy = yy + 52
  end
  yy = filterBar.drawFilters("scenplacelib", self.placementFilters, game, x + 16, yy, w - 32) + 12
  yy = filterBar.drawSearch("scenplacelib", self.placementFilters, game, x + 16, yy, w - 32,
    { labelBackground = theme.fixed.overlayPanel, clearColor = theme.fixed.white }) + 4
  local visible = filterBar.visible(self.placementFilters, game)
  if hasScenarioCards then
    visible = util.filter(visible, function(def) return (def.isScenarioCard == true) == self.placementLibraryScenario end)
  end
  local nameH = poolGrid.nameH()
  local folder = self.editor.folderPath
  local displayBacks = common.displayCardBacks(folder, game.cardBacks)
  poolGrid.draw("scenplacelib:grid", visible, x, yy, w, y + h - yy, 12, function(def, i, tx, ty, tileW, cx)
    local r = ui.region("scenplacelib:card:" .. def.id, cx - poolGrid.PW / 2, ty, poolGrid.PW, poolGrid.PH + 6 + nameH,
      { cursor = "hand" })
    CR.draw({ def = common.displayCard(folder, def), faceUp = true, cx = cx, cy = ty + poolGrid.PH / 2, scale = poolGrid.SCALE,
      angle = CR.orientationTurns(def.orientation) * 2 * math.pi, cardBacks = displayBacks, scenarioCardBackId = game.scenarioCardBackId })
    ui.text(def.cardTitle, tx, ty + poolGrid.PH + 6,
      { size = 11, w = tileW, align = "center", maxLines = poolGrid.NAME_LINES, color = theme.fixed.white })
    if r.hovered then self.hoveredId = def.id end
    if r.pressed then
      self.placingDraft = def
      self.placementLibraryOpen = false
    end
  end)
  theme.c = saved
end

function T:drawPlacementView(scenario, x, y, w, h)
  local c = theme.c
  local game = self.editor.game
  if self.selectedPlacement and not util.contains(scenario.placements, self.selectedPlacement) then
    self.selectedPlacement = nil
  end

  local toolbarH = 40
  local flipW = ui.buttonWidth("Flip")
  local delW = ui.buttonWidth("Delete", { icon = "delete_outline" })
  ui.text("Right-click the table for the Card Library. Drag placed cards to move them.", x + 12, y,
    { h = toolbarH, valign = "middle", size = 12, color = c.onSurfaceVariant, w = w - 24 - flipW - delW - 16 })
  if ui.button("Flip", x + w - 12 - delW - 8 - flipW, y, flipW, toolbarH,
    { variant = "outlined", id = "scen:place:flip", disabled = self.selectedPlacement == nil }) then
    self.selectedPlacement.faceUp = not self.selectedPlacement.faceUp
  end
  if ui.button("Delete", x + w - 12 - delW, y, delW, toolbarH,
    { variant = "outlined", icon = "delete_outline", id = "scen:place:delete", disabled = self.selectedPlacement == nil }) then
    util.removeValue(scenario.placements, self.selectedPlacement)
    self.selectedPlacement = nil
  end

  local cx, cy, cw, ch, scale = canvasRect(x, y + toolbarH + 8, w, h - toolbarH - 8)
  ui.rect("fill", cx, cy, cw, ch, 0, { color.toRgba(tableSettings.feltColor(game.tableColor)) })
  ui.rect("line", cx + 1, cy + 1, cw - 2, ch - 2, 0, { color.toRgba(tableSettings.playmatBorderColor(game.playmatBorderColor)) })

  local canvasRegion = ui.region("scen:place:canvas", cx, cy, cw, ch)
  if canvasRegion.rightClicked then self.placementLibraryOpen = true end

  for _, p in ipairs(scenario.placements) do
    local def = models.GameDefinition.cardById(game, p.definitionId)
    if def then
      local sx, sy = cx + p.x * cw, cy + p.y * ch
      local turned = def.orientation ~= "portrait"
      local bw0, bh0 = turned and CR.cardHeight or CR.cardWidth, turned and CR.cardWidth or CR.cardHeight
      local bw, bh = bw0 * scale, bh0 * scale
      local r = ui.region("scen:place:" .. keyOf(p), sx - bw / 2, sy - bh / 2, bw, bh, { cursor = "hand" })
      if r.pressed then self.selectedPlacement = p end
      if r.held then
        local mx, my = ui.mouse()
        local hwF, hhF = (bw / 2) / cw, (bh / 2) / ch
        p.x = util.clamp((mx - cx) / cw, hwF, 1 - hwF)
        p.y = util.clamp((my - cy) / ch, hhF, 1 - hhF)
      end
      CR.draw({ def = common.displayCard(self.editor.folderPath, def), faceUp = p.faceUp, cx = sx, cy = sy, scale = scale,
        angle = CR.orientationTurns(def.orientation) * 2 * math.pi,
        cardBacks = common.displayCardBacks(self.editor.folderPath, game.cardBacks),
        scenarioCardBackId = game.scenarioCardBackId })
      if p == self.selectedPlacement then
        ui.rect("line", sx - bw / 2 - 2, sy - bh / 2 - 2, bw + 4, bh + 4, 4, theme.fixed.blue)
      end
      ui.text(def.cardTitle, sx - bw / 2, sy + bh / 2 + 4, { w = bw, align = "center", size = 11, color = theme.fixed.white })
    end
  end

  if self.placingDraft then
    local def = self.placingDraft
    local mx, my = ui.mouse()
    CR.draw({ def = common.displayCard(self.editor.folderPath, def), faceUp = true, cx = mx, cy = my, scale = scale,
      angle = CR.orientationTurns(def.orientation) * 2 * math.pi,
      cardBacks = common.displayCardBacks(self.editor.folderPath, game.cardBacks),
      scenarioCardBackId = game.scenarioCardBackId, alpha = 0.85 })
    if ui.mouseReleased(1) then
      if mx >= cx and mx <= cx + cw and my >= cy and my <= cy + ch then
        local turned = def.orientation ~= "portrait"
        local bw0, bh0 = turned and CR.cardHeight or CR.cardWidth, turned and CR.cardWidth or CR.cardHeight
        local hwF, hhF = (bw0 * scale / 2) / cw, (bh0 * scale / 2) / ch
        local fx = util.clamp((mx - cx) / cw, hwF, 1 - hwF)
        local fy = util.clamp((my - cy) / ch, hhF, 1 - hhF)
        local placement = models.ScenarioPlacement.new({ definitionId = def.id, x = fx, y = fy, faceUp = true })
        scenario.placements[#scenario.placements + 1] = placement
        self.selectedPlacement = placement
      end
      self.placingDraft = nil
    end
  end

  if self.placementLibraryOpen then ui.overlay(function() self:drawPlacementLibrary(game) end) end
end

return T
