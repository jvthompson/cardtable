-- Ports of game_definition_editor_entry_screen.dart and
-- game_definition_editor_screen.dart: pick (or create) a game definition,
-- then edit it across four tabs -- General / Zones / Sets / Cards -- and
-- save it back to its folder's gamedef.json.
--
-- The editor's GameDefinition is loaded WITHOUT resolving image paths (see
-- gamedef_ops.loadGameDefFile), so saving writes the bare file names back
-- unchanged. Like the Flutter editor there is no unsaved-changes prompt,
-- and the game's id stays whatever its folder / file gave it.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local widgets = require("src.ui.kit.widgets")
local util = require("src.core.util")
local fs = require("src.data.fs")
local ops = require("src.data.gamedef_ops")
local paths = require("src.data.paths")
local resolver = require("src.data.image_resolver")
local fileDialog = require("src.platform.file_dialog")
local GamePicker = require("src.ui.screens.game_picker")

local function app() return require("src.app") end

local M = {}

---------------------------------------------------------------------------
-- Shared new / open flows
---------------------------------------------------------------------------

-- Prompts for a new game id and writes a stub gamedef.json under
-- <games library>/<id>/. onCreated(folderPath, game).
function M.newGameDefinition(onCreated)
  local root = paths.gamesDir()
  local st = { id = "" }
  local function submit()
    local id = util.trim(st.id)
    local err = ops.validateGameId(id)
    if not err and fs.exists(fs.join(root, id)) then err = "A game with this ID already exists." end
    if err then
      st.error = err
      return true
    end
    local ok, folderPath, game = pcall(ops.createGameDefinition, root, id)
    if not ok then
      st.error = "Could not create it: " .. tostring(folderPath)
      return true
    end
    onCreated(folderPath, game)
    return false
  end
  return overlays.dialog({
    title = "New Game Definition",
    width = 400,
    content = function(d, x, y, w)
      local text, changed, submitted = ui.textField("newgame:id", x, y + 8, w, st.id, {
        label = "Game ID", autofocus = true, error = st.error, labelBackground = theme.c.surfaceContainerHigh })
      st.id = text
      if changed then st.error = nil end
      if submitted and not submit() then d:close() end
      return 8 + ui.textFieldHeight({ error = st.error })
    end,
    actions = {
      { label = "Cancel", variant = "text" },
      { label = "Create", variant = "filled", onClick = function() return submit() end },
    },
  })
end

-- Opens a gamedef.json picked anywhere on disk. onOpened(folderPath, game).
function M.openExistingGameDefinition(onOpened)
  fileDialog.openFile({ title = "Open Game Definition",
    filters = { { name = "Game Definition", extensions = { "json" } } } }, function(path)
    if not path then return end
    local folder = fs.dirname(path)
    local ok, game = pcall(ops.loadGameDefFile, path, folder)
    if not ok then
      overlays.toast("That file is not a valid game definition.")
      return
    end
    onOpened(folder, game)
  end)
end

---------------------------------------------------------------------------
-- Editor
---------------------------------------------------------------------------

local Editor = {}
Editor.__index = Editor
M.Editor = Editor

local TAB_LABELS = { "General", "Zones", "Sets", "Cards" }

function Editor.new(folderPath, game)
  local self = setmetatable({ title = "Game Definition Editor", tab = 1 }, Editor)
  self:load(folderPath, game)
  return self
end

function Editor:load(folderPath, game)
  self.folderPath = folderPath
  self.game = game
  self.tabs = {
    require("src.ui.screens.gamedef.settings_tab").new(self),
    require("src.ui.screens.gamedef.zones_tab").new(self),
    require("src.ui.screens.gamedef.sets_tab").new(self),
    require("src.ui.screens.gamedef.card_view_tab").new(self),
  }
  self.scenarioTab = nil
  resolver.clearCache()
end

-- "Scenarios" is only in the tab bar while the game opts into it.
function Editor:tabLabels()
  if not self.game.hasScenarios then return TAB_LABELS end
  local labels = {}
  for i, l in ipairs(TAB_LABELS) do labels[i] = l end
  labels[#labels + 1] = "Scenarios"
  return labels
end

-- Lazily built so a game that never turns on scenarios never pays for it.
function Editor:scenarioTabOrNil()
  if not self.game.hasScenarios then return nil end
  if not self.scenarioTab then self.scenarioTab = require("src.ui.screens.gamedef.scenario_tab").new(self) end
  return self.scenarioTab
end

-- The tab instance self.tab currently points to. Falls back to (and
-- reclamps self.tab onto) Cards if hasScenarios was turned off while the
-- Scenarios tab was selected -- e.g. opening a different game definition
-- without hasScenarios while tab 5 was still active.
function Editor:activeTab()
  if self.tab == 5 then
    local scenarioTab = self:scenarioTabOrNil()
    if scenarioTab then return scenarioTab end
    self.tab = 4
  end
  return self.tabs[self.tab]
end

-- Warns first when cards without a set would be dropped from the file
-- (see gamedef_ops.cardsOutsideSets).
function Editor:save()
  local lost = ops.cardsOutsideSets(self.game)
  if #lost == 0 then
    self:write()
    return
  end
  local names = {}
  for i = 1, math.min(5, #lost) do names[i] = '"' .. lost[i].cardTitle .. '"' end
  local more = #lost > 5 and (" and " .. (#lost - 5) .. " more") or ""
  local plural = #lost == 1 and "card isn't" or "cards aren't"
  overlays.confirm("Cards Without a Set",
    #lost .. " " .. plural .. " in any set (" .. table.concat(names, ", ") .. more .. "). "
      .. "This game uses sets, so cards outside one are not saved and will be lost. "
      .. "Assign them a set on the Cards tab to keep them.",
    "Save Anyway", function() self:write() end, { width = 480, danger = true })
end

function Editor:write()
  local ok, written, err = pcall(ops.writeGameDefinition, self.folderPath, self.game)
  resolver.clearCache()
  if ok and written then
    overlays.toast("Saved to " .. self.folderPath)
  else
    overlays.toast("Could not save: " .. tostring(ok and err or written))
  end
end

-- The duplicate-card checks, under the toolbar's Tools button.
function Editor:openToolsMenu()
  local dialogs = require("src.ui.screens.gamedef.dialogs")
  local mx, my = ui.mouse()
  overlays.menu(mx - 280, my + 16, {
    { label = "Check for Duplicate Card IDs...", icon = "copy_all", onSelect = function() dialogs.showDuplicateCardIds(self) end },
    { label = "Merge Duplicate Card Images...", icon = "merge_type", onSelect = function() dialogs.showMergeDuplicateImages(self) end },
  }, { width = 300 })
end

function Editor:update(dt)
  for _, t in ipairs(self.tabs) do
    if t.update then t:update(dt) end
  end
  if self.scenarioTab and self.scenarioTab.update then self.scenarioTab:update(dt) end
end

function Editor:keypressed(key)
  local t = self:activeTab()
  if t.keypressed then t:keypressed(key) end
end

function Editor:draw(x, y, w, h)
  local name = self.game.name
  local busy = self.tabs[3].busy
  local tbH = widgets.editorToolbar(x, y, w, name == "" and "Game Definition Editor" or name, {
    { icon = "note_add", tooltip = "New Game Definition...", id = "gde:new", disabled = busy, onClick = function()
      M.newGameDefinition(function(folder, game) self:load(folder, game) end)
    end },
    { icon = "folder_open", tooltip = "Open Existing...", id = "gde:open", disabled = busy, onClick = function()
      M.openExistingGameDefinition(function(folder, game) self:load(folder, game) end)
    end },
    { icon = "build", tooltip = "Tools", id = "gde:tools", disabled = busy, onClick = function() self:openToolsMenu() end },
    { icon = "save", tooltip = "Save", id = "gde:save", disabled = busy, onClick = function() self:save() end },
  })
  local tabY = y + tbH + 1
  local newTab, tabH = widgets.tabBar("gde:tabs", x, tabY, w, self:tabLabels(), self.tab)
  if newTab ~= self.tab then
    self.tab = newTab
    ui.blur()
  end
  local by = tabY + tabH
  ui.pushClip(x, by, w, y + h - by)
  self:activeTab():draw(x, by, w, y + h - by)
  ui.popClip()
end

---------------------------------------------------------------------------
-- Entry screen
---------------------------------------------------------------------------

local Entry = {}
Entry.__index = Entry
M.Entry = Entry

function Entry.new()
  local self = setmetatable({ title = "Game Definition Editor" }, Entry)
  self.root = paths.gamesDir()
  self:refresh()
  return self
end

-- Scans on a later update so the progress bar gets a frame first.
function Entry:refresh()
  self.busy = true
  self.pendingScan = 2
end

function Entry:resume()
  self.root = paths.gamesDir()
  self:refresh()
end

function Entry:update()
  if not self.pendingScan then return end
  self.pendingScan = self.pendingScan - 1
  if self.pendingScan > 0 then return end
  self.pendingScan = nil
  resolver.clearCache()
  local ok, entries = pcall(ops.scanGameLibrary, self.root)
  self.error = nil
  if ok then
    self.entries = entries
    if #entries == 0 then self.error = "No games found in this folder." end
  else
    self.entries = {}
    self.error = "Could not read that folder: " .. tostring(entries)
  end
  self.busy = false
end

function Entry:changeRoot()
  fileDialog.pickFolder({ title = "Choose your game library folder", initialDir = self.root }, function(chosen)
    if not chosen then return end
    GamePicker.maybeMoveLibraryFolder(self.root, chosen, "game", function()
      paths.setGamesDir(chosen)
      self.root = chosen
      self:refresh()
    end)
  end)
end

local function openEditor(folderPath, game) app().push(Editor.new(folderPath, game)) end

function Entry:draw(x, y, w, h)
  local c = theme.c
  local pad = 24
  x, y, w, h = x + pad, y + pad, w - 2 * pad, h - 2 * pad
  local yy = y
  ui.text(self.root, x, yy, { size = 12, color = c.primary, w = w - 96, h = 40, valign = "middle", ellipsis = true })
  if ui.iconButton("refresh", x + w - 88, yy, { tooltip = "Refresh", disabled = self.busy, id = "gdx:refresh" }) then self:refresh() end
  if ui.iconButton("folder_open", x + w - 44, yy, { tooltip = "Change Folder...", disabled = self.busy, id = "gdx:folder" }) then
    self:changeRoot()
  end
  yy = yy + 40
  if self.busy then
    ui.progressBar(x, yy + 4, w, 2)
  end
  yy = yy + 10 + 12

  -- Bottom buttons: New (filled), a divider, Open Existing (outlined).
  local btnH = 48
  local bottomH = 8 + btnH + 20 + 1 + 8 + btnH
  local gridH = y + h - bottomH - yy
  local entries = self.entries
  if entries == nil then
    ui.spinner(x + w / 2, yy + gridH / 2, 12)
  elseif #entries == 0 then
    ui.text(self.error or "No games found in this folder.", x, yy, { w = w, h = gridH, align = "center", valign = "middle",
      color = c.onSurfaceVariant })
  else
    local games = {}
    for i, e in ipairs(entries) do games[i] = e.game end
    GamePicker.drawGrid("gdx:grid", games, x, yy, w, gridH, pad, function(g)
      openEditor(g.folderPath, g)
    end)
  end
  local by = y + h - bottomH + 8
  if ui.button("New Game Definition...", x, by, w, btnH, { id = "gdx:new" }) then
    M.newGameDefinition(openEditor)
  end
  by = by + btnH + 20
  ui.divider(x, by, w)
  by = by + 1 + 8
  if ui.button("Open Existing...", x, by, w, btnH, { variant = "outlined", id = "gdx:open" }) then
    M.openExistingGameDefinition(openEditor)
  end
end

return M
