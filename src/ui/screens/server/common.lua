-- Helpers shared by the CardTable server screens: game downloads with a
-- progress dialog, entering rooms/games, and getting back to the lobby.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local widgets = require("src.ui.kit.widgets")
local json = require("lib.json")
local assetSync = require("src.net.asset_sync")
local deckStore = require("src.data.deck_store")
local SC = require("src.net.server_client")
local loader = require("src.data.game_loader")
local GamePicker = require("src.ui.screens.game_picker")

local M = {}

local function app() return require("src.app") end

local function formatBytes(n)
  if n >= 1024 * 1024 then return string.format("%.1f MB", n / (1024 * 1024)) end
  return string.format("%d KB", math.floor(n / 1024 + 0.5))
end

-- Makes sure a server game is downloaded and current, showing a progress
-- dialog while files download. onReady(game) runs once it is loaded.
function M.withGame(sc, gameId, onReady)
  local info = sc:gameById(gameId)
  local st = { done = 0, total = 0, bytes = 0, reused = 0, checking = true }
  local dialog
  local function close() if dialog then dialog:close() dialog = nil end end
  assetSync.ensureGame(sc, gameId, function(game, err)
    close()
    if not game then
      overlays.alert("Couldn't Load Game", err or "The game could not be downloaded.")
      return
    end
    onReady(game)
  end, function(done, total, bytes, reused)
    st.checking, st.done, st.total, st.bytes, st.reused = false, done, total, bytes, reused or 0
    if not dialog then
      dialog = overlays.dialog({
        title = "Downloading " .. (info and info.name or "game"),
        width = 420, dismissible = false,
        content = function(_, x, y, w)
          ui.progressBar(x, y + 4, w, 4, st.total > 0 and st.done / st.total or 0)
          local status = st.done .. " of " .. st.total .. " files (" .. formatBytes(st.bytes) .. " downloaded"
          if st.reused > 0 then status = status .. ", " .. st.reused .. " already on this computer" end
          ui.text(status .. ")", x, y + 20, { w = w, ellipsis = true })
          ui.text("Game files are kept on this computer, so this only happens when the server's copy changes.", x, y + 44,
            { w = w, size = 12, color = theme.c.onSurfaceVariant })
          return 44 + ui.textHeight("Game files are kept on this computer, so this only happens when the server's copy changes.", w, 12)
        end,
        actions = {},
      })
    end
  end)
end

---------------------------------------------------------------------------
-- Game selection
---------------------------------------------------------------------------

-- A one-off "choose a game" screen: the tile grid Create Game, Trade and
-- (when nothing's picked yet) the lobby's Choose Game button all show.
-- onPick(gameInfo); the caller is responsible for popping this screen.
-- opts.excludeStandardDeck leaves out the Standard 52-Card Deck.
local GameChoice = {}
GameChoice.__index = GameChoice

function M.pickGame(sc, title, subtitle, onPick, opts)
  return setmetatable({ title = title, sc = sc, subtitle = subtitle, onPick = onPick, opts = opts }, GameChoice)
end

-- The server's games as logo tiles (as the local game pickers show them);
-- onPick(gameInfo). opts.excludeStandardDeck leaves out the Standard
-- 52-Card Deck. Logos come from the game's downloaded copy, if any.
local function drawGameList(sc, id, x, y, w, h, subtitle, onPick, opts)
  local c = theme.c
  local pad = 24
  x, y, w, h = x + pad, y + pad, w - 2 * pad, h - 2 * pad
  local yy = y
  ui.text("Choose a game", x, yy, { size = 22 })
  yy = yy + 32
  ui.text(subtitle, x, yy, { w = w, color = c.onSurfaceVariant })
  yy = yy + ui.textHeight(subtitle, w) + 20
  local tiles = {}
  for _, g in ipairs(sc.games) do
    if not (opts and opts.excludeStandardDeck and g.id == loader.standardDeckId) then
      local n, sets = g.cardCount or 0, #(g.sets or {})
      local caption = n .. (n == 1 and " card" or " cards")
      if sets > 0 then caption = caption .. "  ·  " .. sets .. (sets == 1 and " set" or " sets") end
      tiles[#tiles + 1] = { id = g.id, name = g.name, caption = caption,
        folderPath = assetSync.gameFolder(sc, g.id), info = g }
    end
  end
  if #tiles == 0 then
    ui.text("This server doesn't have any games yet.", x, yy, { w = w, color = c.onSurfaceVariant })
    return
  end
  GamePicker.drawGrid(id, tiles, x, yy, w, y + h - yy, pad, function(t) onPick(t.info) end)
end

function GameChoice:draw(x, y, w, h)
  drawGameList(self.sc, "gc:games", x, y, w, h, self.subtitle, self.onPick, self.opts)
end

-- Remembers `gameId` as the game selected for Shop/Deck Editor/Collection/
-- Create Game on this server: for this session (sc.selectedGameId, and
-- sc.selectedGame once it's loaded) and across reconnects (settings, keyed
-- by server). Loading is memoized by assetSync, so this doesn't repeat the
-- download/load when Shop/Deck Editor/Collection ask for the same game.
function M.selectGame(sc, gameId)
  sc.selectedGameId = gameId
  SC.saveLastGameId(sc.key, gameId)
  M.withGame(sc, gameId, function(game) sc.selectedGame = game end)
end

-- onInfo(gameInfo) with the game currently selected on this server, asking
-- (and remembering the answer) first if nothing's selected yet. opts is
-- forwarded to the fallback picker -- pass { excludeStandardDeck = true }
-- from callers (Shop, Deck Editor, Collection) that can't do anything with
-- the Standard 52-Card Deck, so a fresh "nothing selected yet" prompt
-- can't land them on it either (the lobby header hides those buttons once
-- it *is* the selection, but that's reached a different way: picked
-- directly through the header's own Choose Game button).
function M.withSelectedGame(sc, title, onInfo, opts)
  local info = sc.selectedGameId and sc:gameById(sc.selectedGameId)
  if info then
    onInfo(info)
    return
  end
  if #sc.games == 0 then
    overlays.alert("No Games", "This server doesn't have any games yet. An admin can add game folders to the server's games directory.")
    return
  end
  app().push(M.pickGame(sc, title, "Pick the game you want to play, shop, and manage decks for.", function(g)
    app().pop()
    M.selectGame(sc, g.id)
    onInfo(g)
  end, opts))
end

-- Pops every screen above the server lobby (then toasts `message`).
function M.returnToLobby(message)
  local A = app()
  while A.top() and not A.top().isServerLobby do
    local before = A.top()
    A.pop()
    if A.top() == before then break end
  end
  if message then overlays.toast(message) end
end

-- The table for a running room (playing or spectating).
function M.gameScreen(sc, game, spectating)
  local MP = require("src.ui.screens.multiplayer")
  local room = sc:currentRoom()
  local ch = sc:gameChannel()
  -- Spectators watch under the same id the server filters for them.
  return MP.ClientGame.new(ch, spectating and ("spectator:" .. sc.self.id) or sc.self.id, {
    localGame = game,
    sc = sc,
    spectator = spectating,
    -- The dedicated server is always the authority (no client runs its own
    -- host_engine), so gate Load Scenario on the room's creator instead of
    -- any notion of "the host".
    isRoomOwner = not spectating and room and room.ownerId == sc.self.id or false,
    collectionMode = room and room.collectionMode,
    deckStore = deckStore.serverStore(sc),
    avatarKeys = function() return sc:avatarKeysByUserId() end,
    leaveMessage = spectating and "Stop watching this game?"
      or "Leave the game? Your seat is kept, so you can rejoin from the lobby while the game is running.",
    disconnectMessage = function() return sc:disconnectMessage() end,
    onExit = function(message)
      if sc.roomId then sc:request("roomLeave", json.object()) end
      sc.roomId, sc.spectating = nil, false
      sc:closeChannel()
      if sc.status ~= "connected" then
        app().popToHome(message)
      else
        M.returnToLobby(spectating and nil or message)
      end
    end,
  })
end

-- Joins (mode "join") or watches (mode "spectate") a room, downloading
-- its game first. Running games open the table; waiting ones the room.
function M.enterRoom(sc, room, mode)
  M.withGame(sc, room.gameId, function(game)
    -- The channel must exist before the request: a running game sends
    -- gameData + fullState right after the reply.
    sc:closeChannel()
    sc:gameChannel()
    sc:request(mode == "spectate" and "roomSpectate" or "roomJoin", json.object({ "roomId", room.id }), function(r)
      if not r.ok then
        sc:closeChannel()
        overlays.alert(mode == "spectate" and "Couldn't Watch Game" or "Couldn't Join Game", r.message or "Something went wrong.")
        return
      end
      sc.roomId, sc.spectating = r.room.id, mode == "spectate"
      sc.roomChat = r.chat or {}
      M.openRoomScreen(sc, game, r.room)
    end)
  end)
end

function M.openRoomScreen(sc, game, room)
  if room.state == "playing" then
    app().push(M.gameScreen(sc, game, sc.spectating))
  else
    app().push(require("src.ui.screens.server.room").new(sc, game))
  end
end

-- Small avatar + name row used by the lobby and the room.
function M.userRow(sc, user, x, y, w, opts)
  opts = opts or {}
  local size = opts.size or 28
  local key = sc:avatarKey(user.avatarHash)
  widgets.avatar(x, y + ((opts.h or size) - size) / 2, size, user.color or 0xFF455A64, key and { key = key } or nil, false)
  ui.text(user.name, x + size + 10, y, { w = w - size - 10, h = opts.h or size, valign = "middle", ellipsis = true,
    weight = opts.bold and "bold" or nil, color = opts.color })
end

function M.timeLabel(at)
  return os.date("%H:%M", at)
end

return M
