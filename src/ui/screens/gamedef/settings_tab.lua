-- Port of widgets/game_settings_tab.dart (the "General" tab): the game's
-- name, its card backs (the first is the default) and its tag groups. The
-- duplicate-card checks live in the editor toolbar's Tools menu. Edits
-- apply straight to the editor's working GameDefinition.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local widgets = require("src.ui.kit.widgets")
local models = require("src.core.models")
local util = require("src.core.util")
local uuid = require("src.core.uuid")
local fs = require("src.data.fs")
local resolver = require("src.data.image_resolver")
local common = require("src.ui.screens.gamedef.common")
local ops = require("src.data.gamedef_ops")
local CR = require("src.ui.table.card_render")
local color = require("src.core.color")
local colorpicker = require("src.ui.kit.colorpicker")
local tableSettings = require("src.data.table_settings")

local keyOf = common.keyOf

local T = {}
T.__index = T

function T.new(editor)
  return setmetatable({ editor = editor, newGroupName = "", expanded = {}, newTag = {}, duplicateTag = {} }, T)
end

local THUMB_W, THUMB_H = math.floor(CR.cardWidth * 0.7), math.floor(CR.cardHeight * 0.7)
local ORIENT_W = 150

-- One card back's row: drag handle, thumbnail (click to choose an image),
-- name and orientation side by side, delete. Returns its height.
function T:drawCardBackRow(ro, i, back, x, y, w)
  local c = theme.c
  local folder = self.editor.folderPath
  local k = "gs:back:" .. keyOf(back)
  local h = THUMB_H + 16
  ro:handle(i, x - 4, y + (h - 40) / 2, y, h)

  -- Thumbnail: click to choose; a small clear button on hover.
  local tx, ty = x + 40, y + 8
  local path = back.imagePath and resolver.resolveBareImagePath(folder, back.imagePath)
  local thumb = ui.region(k .. ":thumb", tx, ty, THUMB_W, THUMB_H, { cursor = "hand", tooltip = "Choose Image..." })
  common.imagePreviewBox(path, tx, ty, THUMB_W, THUMB_H)
  if thumb.hovered then ui.rect("fill", tx, ty, THUMB_W, THUMB_H, 6, theme.alpha(c.onSurface, 0.08)) end
  local cleared = false
  if back.imagePath ~= nil and ui.hoverIgnoringLayer(tx, ty, THUMB_W, THUMB_H) then
    cleared = ui.iconButton("close", tx + THUMB_W - 22, ty + 2, { size = 20, id = k .. ":clear", tooltip = "Clear Image",
      background = c.surface })
  end
  if cleared then
    back.imagePath = nil
  elseif thumb.clicked then
    common.chooseImage(folder, nil, function(name)
      if name then back.imagePath = name end
    end)
  end

  local fx = tx + THUMB_W + 16
  local fy = y + (h - common.FIELD_H) / 2
  local right = x + w - 44
  local badgeW = 0
  if i == 1 then
    badgeW = ui.textWidth("Default", 12, "medium") + 16
    local bx = right - badgeW - 8
    ui.rect("fill", bx, y + (h - 24) / 2, badgeW, 24, 12, c.secondaryContainer)
    ui.text("Default", bx, y, { w = badgeW, h = h, size = 12, weight = "medium", align = "center", valign = "middle",
      color = c.onSecondaryContainer })
    badgeW = badgeW + 8
  end
  local fw = right - badgeW - 8 - fx - ORIENT_W - common.GAP
  back.name = ui.textField(k .. ":name", fx, fy, fw, back.name, { label = "Name" })
  back.orientation = ui.dropdown(k .. ":orient", fx + fw + common.GAP, fy, ORIENT_W, common.orientationOptions,
    back.orientation, { label = "Orientation" })
  if ui.iconButton("delete_outline", x + w - 40, y + (h - 40) / 2, { id = k .. ":del", tooltip = "Remove Card Back" }) then
    self.pendingRemoveBack = back
  end
  return h
end

-- A group's tags as removable chips, drag-to-reorder. Returns the height.
local CHIP_H, CHIP_GAP = 32, 8
local function chipWidth(tag) return ui.textWidth(tag, 14) + 12 + 28 end

function T:drawTagChips(k, tags, x, y, w)
  local c = theme.c
  local st = ui.state(k .. ":chips")
  -- Layout first, so drag targets know every chip's rect.
  local rects = {}
  local place, bottom = widgets.flow(x, y, w, CHIP_H, CHIP_GAP)
  for i, tag in ipairs(tags) do
    local cw = math.min(chipWidth(tag), w)
    local px, py = place(cw)
    rects[i] = { x = px, y = py, w = cw }
  end
  local mx, my = ui.mouse()
  local removeTag
  for i, tag in ipairs(tags) do
    local r = rects[i]
    local body = ui.region(k .. ":chip" .. i, r.x, r.y, r.w - 28, CHIP_H, { cursor = "sizeall", tooltip = "Drag to reorder" })
    if body.pressed and ui.mousePressed(1) then st.press, st.px, st.py = i, mx, my end
    local dragged = st.dragging == i
    ui.rect("fill", r.x, r.y, r.w, CHIP_H, 8, dragged and theme.alpha(c.primary, 0.16) or c.surfaceContainerHigh)
    if body.hovered and not st.dragging then ui.rect("fill", r.x, r.y, r.w, CHIP_H, 8, theme.alpha(c.onSurface, 0.06)) end
    ui.text(tag, r.x + 12, r.y, { h = CHIP_H, valign = "middle", w = r.w - 12 - 28, ellipsis = true })
    if ui.iconButton("close", r.x + r.w - 28, r.y + 4, { size = 24, id = k .. ":rmtag:" .. i, tooltip = "Remove Tag" }) then
      removeTag = i
    end
  end
  -- A press becomes a drag once the mouse moves a little.
  if st.press and not st.dragging then
    if not ui.mouseDown(1) then
      st.press = nil
    elseif math.abs(mx - st.px) + math.abs(my - st.py) > 4 then
      st.dragging = st.press
    end
  end
  if st.dragging then
    ui.setCursor("sizeall")
    -- Insertion slot: before the nearest chip if the mouse is on its left half.
    local best, bestD = nil, math.huge
    for i, r in ipairs(rects) do
      local cx, cy = r.x + r.w / 2, r.y + CHIP_H / 2
      local d = (mx - cx) ^ 2 + ((my - cy) * 3) ^ 2
      if d < bestD then best, bestD = i, d end
    end
    local p = best and (mx < rects[best].x + rects[best].w / 2 and best or best + 1) or 1
    local lr = rects[math.min(p, #rects)]
    if lr then
      local lx = p <= #rects and lr.x - CHIP_GAP / 2 - 1 or lr.x + lr.w + CHIP_GAP / 2 - 1
      ui.rect("fill", lx, lr.y, 3, CHIP_H, 1.5, c.primary)
    end
    if not ui.mouseDown(1) then
      local from = st.dragging
      st.dragging, st.press = nil, nil
      local to = p > from and p - 1 or p
      if to ~= from and tags[from] then widgets.moveItem(tags, from, to) end
    end
  end
  if removeTag then table.remove(tags, removeTag) end
  if #tags == 0 then return 0 end
  return bottom() - y
end

-- One tag group: handle, collapse toggle, name (editable while expanded),
-- delete; expanded, its chips and a new-tag field. Returns its height.
function T:drawTagGroup(ro, i, group, x, y, w)
  local c = theme.c
  local gk = keyOf(group)
  local k = "gs:group:" .. gk
  local expanded = self.expanded[gk]
  local headerH = 56
  local st = ui.state(k)
  local h = headerH + (expanded and (st.bodyH or 0) or 0)
  ro:handle(i, x - 4, y + 8, y, h)

  local hx = x + 40
  local hw = w - 40 - 44
  local count = #group.tags .. (#group.tags == 1 and " tag" or " tags")
  if expanded then
    if ui.iconButton("expand_more", hx, y + 8, { id = k .. ":exp", tooltip = "Collapse" }) then self.expanded[gk] = false end
    local nw = math.min(360, hw - 48 - 80)
    local oldName = group.name
    group.name = ui.textField(k .. ":name", hx + 44, y + 4, nw, group.name, { label = "Group Name" })
    if group.name ~= oldName and oldName ~= "" then
      ops.renameTagGroupInCards(self.editor.game.cards, oldName, group.name)
    end
    ui.text(count, hx + 44 + nw + 12, y, { size = 12, h = headerH, valign = "middle", color = c.onSurfaceVariant })
  else
    local title = group.name == "" and "(unnamed group)" or group.name
    if common.collapseHeader(k .. ":hdr", title, hx + 6, y + 8, hw - 6, 40, false, count) then self.expanded[gk] = true end
  end
  if ui.iconButton("delete_outline", x + w - 40, y + 8, { id = k .. ":del", tooltip = "Delete Group" }) then
    self.pendingRemoveGroup = group
  end
  if not expanded then return h end

  local bx, bw = hx + 44, w - 40 - 44 - 44
  local by = y + headerH + 4
  local chipsH = self:drawTagChips(k, group.tags, bx, by, bw)
  if chipsH > 0 then by = by + chipsH + common.GAP end
  local err = self.duplicateTag[gk] and "Tag already exists" or nil
  local fw = math.min(320, bw - 48)
  local text, changed, submitted = ui.textField(k .. ":newtag", bx, by, fw, self.newTag[gk] or "",
    { label = "New tag", h = 40, error = err })
  self.newTag[gk] = text
  if changed then self.duplicateTag[gk] = nil end
  local add = ui.iconButton("add", bx + fw + 4, by, { id = k .. ":addtag", tooltip = "Add Tag" })
  if submitted or add then
    local trimmed = util.trim(text)
    if trimmed ~= "" then
      if util.contains(group.tags, trimmed) then
        self.duplicateTag[gk] = true
      else
        group.tags[#group.tags + 1] = trimmed
        self.newTag[gk] = ""
        self.duplicateTag[gk] = nil
      end
    end
  end
  by = by + ui.textFieldHeight({ h = 40, error = err }) + common.GAP
  st.bodyH = by - (y + headerH)
  return headerH + st.bodyH
end

function T:addGroup()
  local game = self.editor.game
  local trimmed = util.trim(self.newGroupName)
  if trimmed == "" or util.any(game.tagGroups, function(g) return g.name == trimmed end) then return end
  game.tagGroups[#game.tagGroups + 1] = models.TagGroup.new({ id = uuid.v4(), name = trimmed, tags = {} })
  self.newGroupName = ""
end

function T:addCardBack()
  local editor = self.editor
  common.chooseImage(editor.folderPath, nil, function(name)
    if not name then return end
    local backs = editor.game.cardBacks
    backs[#backs + 1] = models.CardBackDefinition.new({ id = uuid.v4(), name = fs.stripExtension(name), imagePath = name })
  end)
end

function T:draw(x, y, w, h)
  local game = self.editor.game
  local c = theme.c
  self.pendingRemoveBack, self.pendingRemoveGroup = nil, nil
  local off = ui.beginScroll("gs:scroll", x, y, w, h)
  local cx, cw = common.column(x, w)
  local yy = y + common.PAD - off

  game.name = ui.textField("gs:name", cx, yy, cw, game.name, { label = "Game Name" })
  yy = yy + common.FIELD_H + common.GAP

  local scenariosH
  game.hasScenarios, scenariosH = common.toggleRow("gs:scenarios", "Contains Scenarios",
    "Scenarios are named setups -- shared zones, starting cards, and cards placed on the table -- that the host "
      .. "can load from the Game Menu during a session. Turn this on to edit them on the Scenarios tab.",
    cx, yy, cw, game.hasScenarios)
  yy = yy + scenariosH + common.GAP

  local orientH
  game.sameOrientationForAll, orientH = common.toggleRow("gs:sameorient", "Same Table Orientation For Everyone",
    "Cooperative games: the shared table and any cards placed on it look the same for every player, regardless "
      .. "of seat, instead of appearing mirrored/upside-down for players sitting \"across the table.\"",
    cx, yy, cw, game.sameOrientationForAll)
  yy = yy + orientH + common.SECTION_GAP

  -- Card backs.
  local hh, add = common.sectionHeader("gs:backs", "Card Backs", cx, yy, cw, {
    count = #game.cardBacks,
    info = 'The first one is this game\'s default -- drag to reorder and change which one that is. Each card can '
      .. 'then pick a specific back (or "Unique") on the Cards tab.',
    action = { label = "Add Card Back...", icon = "add", id = "gs:addback" } })
  if add then self:addCardBack() end
  yy = yy + hh + 4
  local ro = widgets.reorder("gs:backs")
  for i, back in ipairs(game.cardBacks) do
    if i > 1 then ui.divider(cx + 40, yy, cw - 40) end
    yy = yy + self:drawCardBackRow(ro, i, back, cx, yy, cw)
  end
  local from, to = ro:finish(cx, cw)
  if from then widgets.moveItem(game.cardBacks, from, to) end
  if self.pendingRemoveBack then util.removeValue(game.cardBacks, self.pendingRemoveBack) end
  if #game.cardBacks == 0 then
    ui.text("No card backs yet.", cx, yy, { h = 32, valign = "middle", color = c.onSurfaceVariant })
    yy = yy + 32
  end
  yy = yy + common.SECTION_GAP

  -- Table colors: optional per-game defaults for the felt and the playmat
  -- border. Left cleared (nil), a player's own Settings choice -- or the
  -- app's hardcoded default -- applies instead.
  local tch = common.sectionHeader("gs:tablecolors", "Table Colors", cx, yy, cw, {
    info = "Optional. Leave cleared to use the app's default, or whatever a player has picked in their own Settings." })
  yy = yy + tch + 4

  ui.text("Table color", cx, yy, { size = 12, color = c.onSurfaceVariant })
  yy = yy + 20
  local feltArgb = (game.tableColor and color.colorFromHex(game.tableColor, tableSettings.defaultFeltColor))
    or tableSettings.defaultFeltColor
  local pickedFelt, fh = colorpicker.field("gs:tableColor", cx, yy, cw, feltArgb)
  if pickedFelt ~= feltArgb then game.tableColor = "#" .. color.hexFromColor(pickedFelt) end
  yy = yy + fh + 4
  local clearLabel = "Clear table color"
  if ui.button(clearLabel, cx - 12, yy, ui.buttonWidth(clearLabel), nil,
    { variant = "text", disabled = game.tableColor == nil, id = "gs:tableColor:clear" }) then
    game.tableColor = nil
  end
  yy = yy + ui.BUTTON_H + common.GAP

  ui.text("Playmat border color", cx, yy, { size = 12, color = c.onSurfaceVariant })
  yy = yy + 20
  local borderArgb = (game.playmatBorderColor and color.colorFromHex(game.playmatBorderColor, tableSettings.defaultPlaymatBorderColor))
    or tableSettings.defaultPlaymatBorderColor
  local pickedBorder, bh = colorpicker.field("gs:playmatBorderColor", cx, yy, cw, borderArgb)
  if pickedBorder ~= borderArgb then game.playmatBorderColor = "#" .. color.hexFromColor(pickedBorder) end
  yy = yy + bh + 4
  clearLabel = "Clear playmat border color"
  if ui.button(clearLabel, cx - 12, yy, ui.buttonWidth(clearLabel), nil,
    { variant = "text", disabled = game.playmatBorderColor == nil, id = "gs:playmatBorderColor:clear" }) then
    game.playmatBorderColor = nil
  end
  yy = yy + ui.BUTTON_H + common.SECTION_GAP

  -- Tag groups.
  hh = common.sectionHeader("gs:groups", "Tag Groups", cx, yy, cw, {
    count = #game.tagGroups,
    info = "Drag to reorder groups or the tags within them -- this also reorders their filter buttons "
      .. "and the tag sections on each card." })
  yy = yy + hh + 4
  local gro = widgets.reorder("gs:groups")
  for i, group in ipairs(game.tagGroups) do
    if i > 1 then ui.divider(cx + 40, yy, cw - 40) end
    yy = yy + self:drawTagGroup(gro, i, group, cx, yy, cw)
  end
  from, to = gro:finish(cx, cw)
  if from then widgets.moveItem(game.tagGroups, from, to) end
  if self.pendingRemoveGroup then util.removeValue(game.tagGroups, self.pendingRemoveGroup) end
  yy = yy + 8
  local fw = math.min(360, cw - 40 - 48)
  local text, _, submitted = ui.textField("gs:newgroup", cx + 40, yy, fw, self.newGroupName, { label = "New tag group", h = 40 })
  self.newGroupName = text
  local addGroup = ui.iconButton("add", cx + 40 + fw + 4, yy, { id = "gs:addgroup", tooltip = "Add Tag Group" })
  if submitted or addGroup then self:addGroup() end
  yy = yy + 40 + common.PAD
  ui.endScroll("gs:scroll", yy + off - y)
end

return T
