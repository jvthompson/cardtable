-- Port of practice_game_screen.dart: a local, offline game where you can act
-- as every seat (click an avatar to switch).
local overlays = require("src.ui.kit.overlays")
local saveNameDialog = require("src.ui.kit.save_name_dialog")
local models = require("src.core.models")
local util = require("src.core.util")
local Session = require("src.game.session")
local controller = require("src.game.controller")
local saves = require("src.data.save_files")
local TableScreen = require("src.ui.table.table_screen")
local discord = require("src.platform.discord")

local S = {}
S.__index = S

local function app() return require("src.app") end

-- opts: game, players, deckConfigsByPlayerId, loadedState (resume a save)
function S.new(opts)
  local self = setmetatable({ title = opts.game.name, showBack = false, forceLightTheme = true }, S)
  local game = opts.game
  if opts.loadedState then
    local log = opts.loadedState.log
    local now = love.timer.getTime()
    self.session = Session.new({
      game = game, localPlayerId = opts.players[1].id, initialState = opts.loadedState, isLocalPractice = true,
      -- Resume the log clock where the save left off.
      clockStart = (#log > 0) and (now - log[#log].elapsedMs / 1000) or now,
    })
  else
    self.session = Session.localPractice({ game = game, players = opts.players, deckConfigsByPlayerId = opts.deckConfigsByPlayerId })
  end
  self.table = TableScreen.new({
    session = self.session,
    controller = controller.Host.new(self.session),
    game = game,
    isMirrored = false,
    localAvatarPath = app().profile.avatarPath,
    leaveButtonLabel = "Leave Game",
    leaveConfirmationMessage = "Leave this practice game and return to the home screen?",
    onLeaveGame = function() app().popToHome() end,
    onSaveGame = game.folderPath and function() self:saveGame() end or nil,
    canLoadScenario = true,
  })
  self.presenceListener = function() self:publishPresence() end
  self.session:addListener(self.presenceListener)
  self:publishPresence()
  return self
end

function S:publishPresence()
  local s = self.session
  local connected = 0
  for _, p in ipairs(s.state.players) do
    if p.connected ~= false then connected = connected + 1 end
  end
  discord.setPlaying(s.game.name, connected, #s.state.players)
end

function S:leave()
  self.session:removeListener(self.presenceListener)
  discord.setIdle()
end

function S:saveGame()
  local game = self.session.game
  local folder = game.folderPath
  saveNameDialog.open({
    title = "Save Game", fieldLabel = "Save Name", emptyNameMessage = "Enter a name.",
    existing = util.map(saves.listSaveGames(folder), function(e) return { name = e.displayName, trailing = e.playerCount .. " player(s)" } end),
    existingHint = "Existing saves -- tap to reuse a name",
    emptyListText = "No saved games yet for " .. game.name .. ".",
    exists = function(name) return saves.saveExists(folder, name) end,
    overwriteTitle = "Overwrite Save?",
    overwriteMessage = function(name) return 'A save named "' .. name .. '" already exists for ' .. game.name .. ". Overwrite it?" end,
    onSave = function(name)
      local state = util.copyWith(self.session.state, { searches = {} })
      local ok, err = saves.writeSaveGame(folder, name, models.SavedGame.new(models.isoNow(os.time() + (love.timer.getTime() % 1)), state))
      overlays.toast(ok and ('Saved "' .. name .. '"') or ("Could not save: " .. tostring(err)))
    end,
  })
end

function S:update(dt) self.table:update(dt) end
function S:draw(x, y, w, h) self.table:draw(x, y, w, h) end
function S:keypressed(...) self.table:keypressed(...) end

return S
