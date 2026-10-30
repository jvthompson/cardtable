-- Multiplayer screens: ports of host_setup_screen.dart,
-- assign_seats_screen.dart, game_select_screen.dart, host_game_screen.dart,
-- join_screen.dart and client_game_screen.dart.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local saveNameDialog = require("src.ui.kit.save_name_dialog")
local models = require("src.core.models")
local util = require("src.core.util")
local uuid = require("src.core.uuid")
local seats = require("src.core.seat_utils")
local color = require("src.core.color")
local P = require("src.net.protocol")
local HostServer = require("src.net.host_server")
local GameClient = require("src.net.game_client")
local netinfo = require("src.net.netinfo")
local discord = require("src.platform.discord")
local Session = require("src.game.session")
local HostEngine = require("src.game.host_engine")
local controller = require("src.game.controller")
local sound = require("src.game.sound")
local profile = require("src.data.profile")
local saves = require("src.data.save_files")
local decks = require("src.data.deck_library")
local paths = require("src.data.paths")
local loader = require("src.data.game_loader")
local resolver = require("src.data.image_resolver")
local imageCache = require("src.data.image_cache")
local TableScreen = require("src.ui.table.table_screen")
local GamePicker = require("src.ui.screens.game_picker")

local M = {}

local function app() return require("src.app") end

local function colorDot(x, y, argb)
  ui.setColor({ color.toRgba(argb) })
  love.graphics.circle("fill", x + 6, y + 6, 6)
end

-- Registers avatar bytes with the image cache; returns playerId -> key.
local keyByBytes = {} -- avatar bytes (interned strings) -> cache key
local function avatarKeys(bytesById)
  local out = {}
  for id, bytes in pairs(bytesById or {}) do
    local key = keyByBytes[bytes]
    if not key then
      key = "avatar:" .. id .. ":" .. love.data.encode("string", "hex", love.data.hash("md5", bytes))
      imageCache.putBytes(key, bytes)
      keyByBytes[bytes] = key
    end
    out[id] = key
  end
  return out
end
M.avatarKeys = avatarKeys

local function centeredColumn(x, y, w, h, colW, contentH)
  local cx = math.floor(x + (w - colW) / 2)
  local cy = math.floor(y + math.max(24, (h - contentH) / 2))
  return cx, cy
end

---------------------------------------------------------------------------
-- Host Setup (lobby)
---------------------------------------------------------------------------

local HostSetup = {}
HostSetup.__index = HostSetup
M.HostSetup = HostSetup

function HostSetup.new(maxPlayers)
  local self = setmetatable({ title = "Host Game", maxPlayers = maxPlayers, mode = "manual" }, HostSetup)
  local A = app()
  self.hostPlayerId = uuid.v4()
  self.invitedIds = {}
  self.server = HostServer.new()
  -- Identifies this hosted session as a Discord activity party; kept on the
  -- server so HostGame keeps advertising the same party.
  self.server.partyId = uuid.v4()
  local port, err = self.server:start(models.PlayerInfo.new({
    id = self.hostPlayerId, name = A.playerName(), role = "host", color = A.profile.color,
  }), maxPlayers, profile.readAvatarBytes())
  if not port then
    self.startError = tostring(err)
  else
    self.port = port
    self.addresses = netinfo.localIPv4Addresses()
    self.publicIPLoading = true
    netinfo.fetchPublicIPv4(function(ip)
      self.publicIP = ip
      self.publicIPLoading = false
      self.server.publicIP = ip
      self:publishHostingPresence()
    end)
  end
  return self
end

-- Rich Presence with party/join secret so a Discord invite (or "Ask to
-- Join" on the host's profile) can connect a friend; needs the public IP.
function HostSetup:publishHostingPresence()
  if not self.port or not self.publicIP then return end
  local n = #self.server:roster()
  discord.setPlaying("a game", n, self.maxPlayers, {
    partyId = self.server.partyId, currentSize = n, maxSize = self.maxPlayers,
    joinSecret = self.publicIP .. ":" .. self.port,
  })
end

function HostSetup:openInviteMode()
  if self.friends or self.discordConnecting then return end
  self.discordConnecting = true
  self.discordError = nil
  discord.ensureAuthorizedAndConnected(function(ok)
    self.discordConnecting = false
    if not ok then
      self.discordError = "Couldn't connect to Discord -- try again."
      return
    end
    self.friends = discord.fetchInvitableFriends()
  end)
end

function HostSetup:sendInvite(friend)
  if not self.publicIP or not self.port then return end
  local key = tostring(friend.userId)
  self.invitedIds[key] = "sending"
  discord.sendGameInvite(friend.userId, function(sent)
    if sent then
      self.invitedIds[key] = true
    else
      self.invitedIds[key] = nil
      overlays.toast("Couldn't send an invite to " .. friend.displayName .. " -- try again.")
    end
  end)
end

function HostSetup:onBack()
  self.server:stop()
  discord.setIdle()
  app().pop()
end

function HostSetup:update()
  if self.navigated or not self.port then return end
  local n = #self.server:roster()
  if n ~= self.lastRosterSize then
    self.lastRosterSize = n
    self:publishHostingPresence()
  end
  if #self.server:roster() >= self.maxPlayers then
    self.navigated = true
    local server, hostId = self.server, self.hostPlayerId
    if self.maxPlayers > 2 then
      app().replace(M.AssignSeats.new(server, hostId))
    else
      app().replace(M.HostGameSelect.new(server, hostId))
    end
  end
end

function HostSetup:draw(x, y, w, h)
  local c = theme.c
  local colW = math.min(420, w - 48)
  if self.startError then
    ui.text("Failed to start hosting: " .. self.startError, x + 24, y, { w = w - 48, h = h, align = "center", valign = "middle", color = theme.fixed.red })
    return
  end
  local roster = self.server:roster()
  local panelH = (self.mode == "discord" and self.friends) and (60 + #self.friends * 52) or 0
  local cx, yy = centeredColumn(x, y, w, h, colW, 460 + #roster * 28 + panelH)
  local mode = ui.segmented("hs:mode", cx, yy, colW, {
    { value = "manual", label = "Manual IP" },
    { value = "discord", label = "Invite via Discord" },
  }, self.mode)
  if mode ~= self.mode then
    self.mode = mode
    if mode == "discord" then self:openInviteMode() end
  end
  yy = yy + 56
  if self.mode == "manual" then
    ui.text("Same network (LAN):", cx, yy, { weight = "bold" })
    yy = yy + 26
    if #self.addresses == 0 then
      ui.text("No network interfaces found -- try 127.0.0.1 for same-machine testing.", cx, yy, { w = colW })
      yy = yy + 40
    else
      for _, a in ipairs(self.addresses) do
        ui.text(a .. " : " .. self.port, cx, yy, { size = 16 })
        yy = yy + 24
      end
    end
    yy = yy + 16
    ui.text("Over the internet:", cx, yy, { weight = "bold" })
    yy = yy + 26
    if self.publicIPLoading then
      ui.text("Looking up public IP...", cx, yy)
      yy = yy + 24
    elseif not self.publicIP then
      ui.text("Couldn't determine your public IP -- check your internet connection.", cx, yy, { w = colW })
      yy = yy + 40
    else
      ui.text(self.publicIP .. " : " .. self.port, cx, yy, { size = 16 })
      yy = yy + 24
      local upnpMsg
      if self.server.upnpMapped == nil then
        upnpMsg = "Setting up automatic port-forwarding (UPnP)..."
      elseif self.server.upnpMapped then
        upnpMsg = "Port automatically forwarded on your router (UPnP)."
      else
        upnpMsg = "Couldn't automatically forward this port (UPnP unavailable) -- forward it to this PC on your router."
      end
      ui.text(upnpMsg, cx, yy, { size = 12, color = c.onSurfaceVariant, w = colW })
      yy = yy + 36
    end
  else
    yy = self:drawDiscordPanel(cx, yy, colW)
  end
  yy = yy + 24
  ui.text("Players:", cx, yy, { weight = "bold" })
  yy = yy + 28
  for _, p in ipairs(roster) do
    colorDot(cx, yy + 4, p.color)
    ui.text(p.name, cx + 20, yy)
    yy = yy + 28
  end
  yy = yy + 24
  local waiting = self.maxPlayers - #roster
  if waiting > 0 then
    ui.spinner(cx + colW / 2, yy + 18, 16)
    yy = yy + 52
    ui.text("Waiting for " .. waiting .. " more player" .. (waiting == 1 and "" or "s") .. "...", cx, yy, { w = colW, align = "center" })
  end
end

function HostSetup:drawDiscordPanel(cx, yy, colW)
  local c = theme.c
  if not discord.isEnabled() then
    ui.text("Discord isn't available (the Discord SDK couldn't be loaded). Use Manual IP instead.", cx, yy, { w = colW, color = c.onSurfaceVariant })
    return yy + 40
  end
  if self.discordConnecting then
    ui.spinner(cx + colW / 2, yy + 18, 16)
    ui.text("Connecting to Discord...", cx, yy + 48, { w = colW, align = "center" })
    return yy + 76
  end
  if self.discordError then
    ui.text(self.discordError, cx, yy, { w = colW, color = theme.fixed.red })
    yy = yy + 28
    if ui.button("Retry", cx, yy, colW, nil, { variant = "outlined" }) then self:openInviteMode() end
    return yy + 52
  end
  local friends = self.friends
  if not friends then return yy end
  if #friends == 0 then
    ui.text("No Discord friends found to invite.", cx, yy, { w = colW })
    return yy + 28
  end
  ui.text("Invite a friend:", cx, yy, { weight = "bold" })
  yy = yy + 28
  local ready = self.publicIP ~= nil and self.port ~= nil
  if not ready then
    ui.text(self.publicIPLoading and "Looking up public IP..." or "Couldn't determine your public IP.", cx, yy, { size = 12 })
    yy = yy + 24
  end
  for _, f in ipairs(friends) do
    -- Initial-letter avatar (avatar URLs are HTTPS, which luasocket can't fetch).
    ui.setColor(c.primaryContainer or c.surfaceVariant)
    love.graphics.circle("fill", cx + 20, yy + 22, 20)
    ui.text((f.displayName ~= "" and f.displayName or "?"):sub(1, 1):upper(), cx, yy + 2, { w = 40, h = 40, align = "center", valign = "middle", weight = "bold" })
    ui.text(f.displayName, cx + 52, yy + 2, { w = colW - 160 })
    ui.text(discord.statusLabels[f.status] or "", cx + 52, yy + 22, { size = 12, color = c.onSurfaceVariant })
    local state = self.invitedIds[tostring(f.userId)]
    if state == true then
      ui.text("Invite sent", cx + colW - 100, yy, { w = 100, h = 44, align = "right", valign = "middle", color = c.onSurfaceVariant })
    else
      local bw = ui.buttonWidth("Invite")
      if ui.button("Invite", cx + colW - bw, yy + 4, bw, nil, { disabled = not ready or state == "sending", id = "hs:invite:" .. tostring(f.userId) }) then
        self:sendInvite(f)
      end
    end
    yy = yy + 52
  end
  return yy
end

---------------------------------------------------------------------------
-- Assign Seats (3-4 players)
---------------------------------------------------------------------------

local AssignSeats = {}
AssignSeats.__index = AssignSeats
M.AssignSeats = AssignSeats

function AssignSeats.new(server, hostPlayerId)
  return setmetatable({ title = "Assign Seats", server = server, hostPlayerId = hostPlayerId,
    order = util.shallowCopy(server:roster()) }, AssignSeats)
end

function AssignSeats:onBack()
  self.server:stop("hostLeft")
  app().pop()
end

function AssignSeats:labels()
  if #self.order == 3 then
    return { "Seat 1 -- alone at the bottom on their own screen", "Seat 2 -- top-left", "Seat 3 -- top-right" }
  elseif #self.order == 4 then
    return { "Seat 1 -- bottom-left", "Seat 2 -- bottom-right", "Seat 3 -- top-left", "Seat 4 -- top-right" }
  end
  return util.map(self.order, function(_, i) return "Seat " .. i end)
end

function AssignSeats:draw(x, y, w, h)
  local c = theme.c
  local colW = math.min(480, w - 48)
  local cx, yy = centeredColumn(x, y, w, h, colW, 160 + 24 + #self.order * 60 + 24 + 48)
  -- Table preview: top row / shared table / bottom row.
  local n = #self.order
  local top = n == 4 and { self.order[3], self.order[4] } or { unpack(self.order, 2) }
  local bottom = n == 4 and { self.order[1], self.order[2] } or { self.order[1] }
  ui.rect("line", cx + 0.5, yy + 0.5, colW - 1, 159, 8, c.outlineVariant)
  local function row(list, ry)
    local widths = util.map(list, function(p) return ui.textWidth(p.name) + 24 end)
    local total = 0
    for _, wv in ipairs(widths) do total = total + wv end
    local rx = cx + (colW - total) / 2
    for i, p in ipairs(list) do
      colorDot(rx + widths[i] / 2 - 18, ry, p.color)
      ui.text(p.name, rx, ry + 16, { w = widths[i], align = "center" })
      rx = rx + widths[i]
    end
  end
  row(top, yy + 16)
  ui.text("(shared table)", cx, yy + 64, { w = colW, align = "center", color = c.onSurfaceVariant })
  row(bottom, yy + 106)
  yy = yy + 160 + 24
  local labels = self:labels()
  for i = 1, n do
    ui.text(labels[i], cx, yy, { w = colW - 220, h = 48, valign = "middle" })
    local options = util.map(self.order, function(p) return { value = p.id, label = p.name } end)
    local picked = ui.dropdown("seat:" .. i, cx + colW - 200, yy, 200, options, self.order[i].id)
    if picked ~= self.order[i].id then
      for j, p in ipairs(self.order) do
        if p.id == picked then self.order[i], self.order[j] = self.order[j], self.order[i] break end
      end
    end
    yy = yy + 60
  end
  yy = yy + 24
  if ui.button("Start", cx, yy, colW, 48) then
    self.server:setSeatOrder(util.map(self.order, function(p) return p.id end))
    app().replace(M.HostGameSelect.new(self.server, self.hostPlayerId))
  end
end

---------------------------------------------------------------------------
-- Host: choose a game (or load a save)
---------------------------------------------------------------------------

local HostGameSelect = {}
HostGameSelect.__index = HostGameSelect
M.HostGameSelect = HostGameSelect

function HostGameSelect.new(server, hostPlayerId)
  local self = setmetatable({ title = "Choose a Game", server = server, hostPlayerId = hostPlayerId }, HostGameSelect)
  self.picker = GamePicker.new(function(game) self:chooseGame(game) end)
  return self
end

function HostGameSelect:onBack()
  self.server:stop("hostLeft")
  app().pop()
end

-- Shared zones with a deckName load that deck from the library by name.
local function resolveSharedDeckConfigs(game)
  local out = {}
  local any = false
  for _, z in ipairs(game.zones) do
    if z.shared and not z.standardDeck and z.deckName then any = true end
  end
  if not any then return out end
  local byName = {}
  for _, e in ipairs(decks.loadAllDecksForGame(paths.decksDir(), game).entries) do byName[e.displayName] = e.deck end
  for _, z in ipairs(game.zones) do
    if z.shared and not z.standardDeck and z.deckName and byName[z.deckName] then out[z.id] = byName[z.deckName] end
  end
  return out
end
M.resolveSharedDeckConfigs = resolveSharedDeckConfigs

function HostGameSelect:chooseGame(game)
  app().push(M.HostGame.new({ server = self.server, hostPlayerId = self.hostPlayerId, game = game,
    deckConfigsByPlayerId = {}, sharedDeckConfigsByZoneId = resolveSharedDeckConfigs(game) }))
end

function HostGameSelect:update(dt) self.picker:update(dt) end

function HostGameSelect:draw(x, y, w, h)
  local label = "Load a Saved Game..."
  local bw = ui.buttonWidth(label, { icon = "folder_open" })
  if ui.button(label, x + w - 16 - bw, y + 16, bw, nil, { variant = "outlined", icon = "folder_open" }) then
    app().push(require("src.ui.screens.load_saved_game").new(self.server:roster(), function(game, state)
      app().push(M.HostGame.new({ server = self.server, hostPlayerId = self.hostPlayerId, game = game, loadedState = state }))
    end))
  end
  self.picker:draw(x, y + 56, w, h - 56)
end

---------------------------------------------------------------------------
-- Host game
---------------------------------------------------------------------------

local HostGame = {}
HostGame.__index = HostGame
M.HostGame = HostGame

function HostGame.new(opts)
  local self = setmetatable({ title = opts.game.name, showBack = false, forceLightTheme = true,
    server = opts.server, hostPlayerId = opts.hostPlayerId, game = opts.game }, HostGame)
  local game = opts.game
  self.server:broadcast("gameData", models.GameDefinition.toJson(game))
  if opts.loadedState then
    local log = opts.loadedState.log
    local now = love.timer.getTime()
    self.session = Session.new({ game = game, localPlayerId = self.hostPlayerId, initialState = opts.loadedState,
      clockStart = (#log > 0) and (now - log[#log].elapsedMs / 1000) or now })
  else
    self.session = Session.dealFromZones({ game = game, players = self.server:roster(), localPlayerId = self.hostPlayerId,
      deckConfigsByPlayerId = opts.deckConfigsByPlayerId, sharedDeckConfigsByZoneId = opts.sharedDeckConfigsByZoneId })
  end
  self.engine = HostEngine.new(self.session, self.server, self.hostPlayerId)
  self.engine:start()
  local players = self.session.state.players
  local seat = 0
  for i, p in ipairs(players) do if p.id == self.hostPlayerId then seat = i - 1 end end
  self.table = TableScreen.new({
    session = self.session,
    controller = controller.Host.new(self.session, self.engine),
    game = game,
    isMirrored = not game.sameOrientationForAll and seats.isFarMirrorSeat(seat, #players),
    localAvatarPath = app().profile.avatarPath,
    leaveButtonLabel = "End Game",
    leaveConfirmationMessage = "End the game for everyone? Every connected player will be disconnected -- you can start a new session any time.",
    onLeaveGame = function() self:endGame() end,
    onKickPlayer = function(id) self.server:kick(id) end,
    onSaveGame = game.folderPath and function() self:saveGame() end or nil,
    canLoadScenario = true,
  })
  self.presenceListener = function() self:publishPresence() end
  self.session:addListener(self.presenceListener)
  if not self.server.publicIP then
    netinfo.fetchPublicIPv4(function(ip)
      self.server.publicIP = ip
      self:publishPresence()
    end)
  end
  self:publishPresence()
  return self
end

function HostGame:publishPresence()
  local s = self.session
  local connected = 0
  for _, p in ipairs(s.state.players) do
    if p.connected ~= false then connected = connected + 1 end
  end
  local total, ip, port = #s.state.players, self.server.publicIP, self.server.port
  discord.setPlaying(s.game.name, connected, total, (ip and port) and {
    partyId = self.server.partyId or self.hostPlayerId, currentSize = connected, maxSize = total, joinSecret = ip .. ":" .. port,
  } or nil)
end

function HostGame:leave()
  self.session:removeListener(self.presenceListener)
  discord.setIdle()
end

function HostGame:endGame()
  self.engine:dispose()
  self.server:stop("hostLeft")
  app().popToHome("You ended the game.")
end

function HostGame:quit()
  self.server:stop("hostLeft")
end

function HostGame:saveGame()
  local game, folder = self.game, self.game.folderPath
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
      local ok, err = saves.writeSaveGame(folder, name, models.SavedGame.new(models.isoNow(), state))
      overlays.toast(ok and ('Saved "' .. name .. '"') or ("Could not save: " .. tostring(err)))
    end,
  })
end

function HostGame:update(dt)
  self.table.avatarKeys = avatarKeys(self.server:avatarsByPlayerId())
  self.table:update(dt)
end

function HostGame:draw(x, y, w, h) self.table:draw(x, y, w, h) end
function HostGame:keypressed(...) self.table:keypressed(...) end

---------------------------------------------------------------------------
-- Join
---------------------------------------------------------------------------

local Join = {}
Join.__index = Join
M.Join = Join

-- opts (optional): host, port, autoConnect -- used by an accepted Discord
-- invite, which carries "host:port" as its join secret.
function Join.new(opts)
  opts = opts or {}
  local self = setmetatable({ title = opts.autoConnect and "Joining..." or "Join Game",
    ip = opts.host or "", port = tostring(opts.port or P.defaultGamePort) }, Join)
  if opts.autoConnect then self:connect() end
  return self
end

function Join:onBack()
  if self.client then self.client:disconnect() end
  app().pop()
end

function Join:connect()
  local host = util.trim(self.ip)
  if host == "" then host = "127.0.0.1" end
  local port = tonumber(util.trim(self.port)) or P.defaultGamePort
  local hostKey = host .. ":" .. port
  local A = app()
  self.client = GameClient.new()
  self.client.onStatus = function(status)
    if status == "server" and not self.navigated then
      -- The address is a CardTable server: sign in and go to its lobby.
      self.navigated = true
      profile.addRecentServer(host, port)
      local sc = require("src.net.server_client").adopt(self.client.conn, host, port, self.client.serverInfo)
      app().replace(require("src.ui.screens.server.login").new(sc))
      return
    end
    if status == "connected" and not self.navigated and self.client.assignedPlayerId then
      self.navigated = true
      profile.saveReconnect(hostKey, self.client.assignedPlayerId)
      profile.addRecentServer(host, port)
      app().replace(M.ClientGame.new(self.client, self.client.assignedPlayerId))
    end
  end
  self.client:connect(host, port, A.playerName(), A.profile.color, profile.readAvatarBytes(), profile.getReconnectPlayerIdFor(hostKey))
end

-- Arrow at the right end of the address field opening the recently joined
-- servers; picking one fills in both address and port.
function Join:drawRecentServers(recent, x, y, w)
  local c = theme.c
  if ui.iconButton("arrow_drop_down", x + w - 40, y + 4, { id = "join:recent", tooltip = "Recent servers" }) then
    self.recentOpen = not self.recentOpen
  end
  if not self.recentOpen then return end
  local itemH = 40
  local px, py, pw, ph = x, y + 50, w, #recent * itemH + 16
  ui.overlay(function()
    ui.cover(-1e9, -1e9, 2e9, 2e9) -- swallow clicks outside to close
    ui.shadow(px, py, pw, ph, 4, 2)
    ui.rect("fill", px, py, pw, ph, 4, c.surfaceContainer)
    local yy = py + 8
    for i, e in ipairs(recent) do
      local r = ui.region("join:recent:" .. i, px, yy, pw - 40, itemH, { cursor = "hand" })
      if r.hovered then ui.rect("fill", px, yy, pw, itemH, 0, theme.alpha(c.onSurface, 0.08)) end
      ui.text(e.host .. " : " .. e.port, px + 12, yy, { w = pw - 56, h = itemH, valign = "middle", ellipsis = true, color = c.onSurface })
      if ui.iconButton("close", px + pw - 40, yy + 4, { size = 32, id = "join:recent:rm:" .. i, tooltip = "Remove" }) then
        profile.removeRecentServer(e.host, e.port)
        if #recent == 1 then self.recentOpen = false end
      elseif r.clicked then
        self.ip, self.port = e.host, tostring(e.port)
        self.recentOpen = false
      end
      yy = yy + itemH
    end
    if (ui.mousePressed(1) and not ui.hover(px, py, pw, ph)) or ui.mousePressed(2) then
      self.recentOpen = false
    end
  end)
end

function Join:draw(x, y, w, h)
  local colW = math.min(360, w - 48)
  local cx, yy = centeredColumn(x, y, w, h, colW, 48 + 12 + 48 + 24 + 48)
  local client = self.client
  if not client or client.status == "idle" then
    local submitted
    local recent = profile.getRecentServers()
    self.ip, _, submitted = ui.textField("join:ip", cx, yy, colW, self.ip, { label = "Host or server IP address",
      hint = "e.g. 192.168.1.42 -- blank = 127.0.0.1", autofocus = true, trailingW = #recent > 0 and 36 or nil })
    if #recent > 0 then self:drawRecentServers(recent, cx, yy, colW) end
    yy = yy + 60
    local s2
    self.port, _, s2 = ui.textField("join:port", cx, yy, colW, self.port, { label = "Port", filter = function(t) return t:match("^%d+$") ~= nil end })
    yy = yy + 72
    if ui.button("Connect", cx, yy, colW, 48) or submitted or s2 then self:connect() end
    return
  end
  local status = client.status
  if status == "connecting" then
    ui.spinner(cx + colW / 2, yy + 20, 16)
    ui.text("Connecting...", cx, yy + 52, { w = colW, align = "center" })
  elseif status == "connected" then
    ui.text((client.reconnected and "Reconnected to " or "Connected to ") .. (client.opponentName or "host") .. "!", cx, yy,
      { w = colW, align = "center", weight = "bold", color = theme.fixed.green })
  elseif status == "failed" then
    local msg = "Failed to connect: " .. tostring(client.errorMessage)
    ui.text(msg, cx, yy, { w = colW, align = "center", color = theme.fixed.red })
    local bw = ui.buttonWidth("Try again")
    if ui.button("Try again", cx + (colW - bw) / 2, yy + ui.textHeight(msg, colW) + 16, bw, nil, { variant = "outlined" }) then
      self.client = nil
    end
  else
    local reason = client.disconnectReason
    local msg = reason == "seatUnavailable"
      and "This game is already in progress and your seat couldn't be found. Make sure you're reconnecting to the same host."
      or reason == "versionMismatch" and "That CardTable server needs a different version of CardTable."
      or reason == "serverRequiresUpdate" and "That CardTable server needs a newer version of CardTable."
      or reason == "serverShuttingDown" and "That CardTable server is shutting down and isn't accepting connections."
      or "Disconnected from host."
    ui.text(msg, cx, yy, { w = colW, align = "center", color = theme.fixed.red })
  end
end

---------------------------------------------------------------------------
-- Client game
---------------------------------------------------------------------------

local ClientGame = {}
ClientGame.__index = ClientGame
M.ClientGame = ClientGame

local DISCONNECT_MESSAGES = {
  kicked = "You were removed from the game by the host.",
  hostLeft = "The host ended the game.",
  seatUnavailable = "This game is already in progress and your seat couldn't be found. Make sure you're reconnecting to the same host.",
}

-- opts (optional; used for games on a CardTable server, where `client` is
-- server_client:gameChannel()):
--   localGame        the server's game as cached locally (for card images)
--   onExit(message)  called instead of going home (back to the server lobby)
--   spectator, collectionMode, deckStore   passed to TableScreen
--   avatarKeys()     -> {playerId -> image cache key}, polled every frame
--   leaveMessage     Leave Game confirmation text
--   disconnectMessage()  text when the connection drops
function ClientGame.new(client, localPlayerId, opts)
  local self = setmetatable({ title = "Game", showBack = false, forceLightTheme = true, client = client,
    localPlayerId = localPlayerId, roster = {}, maxPlayers = 2, avatarBytes = {}, opts = opts or {} }, ClientGame)
  client.onMessage = function(m) self:handleMessage(m) end
  client.onStatus = function(status)
    if status == "disconnected" then
      sound.play("error")
      local o = self.opts
      self:returnHome(o.disconnectMessage and o.disconnectMessage()
        or DISCONNECT_MESSAGES[client.disconnectReason or ""] or "Disconnected from host.")
    end
  end
  -- (Not ipairs: any of these may be nil, e.g. servers send no roster update.)
  for _, key in ipairs({ "lastGameData", "lastLobbyRosterUpdate", "lastFullState" }) do
    if client[key] then self:handleMessage(client[key]) end
  end
  return self
end

function ClientGame:returnHome(message)
  if self.navigatedHome then return end
  self.navigatedHome = true
  self.client:disconnect()
  if self.opts.onExit then
    self.opts.onExit(message)
  else
    app().popToHome(message)
  end
end

function ClientGame:quit() self.client:disconnect() end

function ClientGame:publishPresence()
  local s = self.session
  if not s then return end
  local connected = 0
  for _, p in ipairs(s.state.players) do
    if p.connected ~= false then connected = connected + 1 end
  end
  discord.setPlaying(s.game.name, connected, #s.state.players)
end

function ClientGame:leave() discord.setIdle() end

function ClientGame:resolveLocalImages(remote)
  if self.opts.localGame then return resolver.mergeLocalImagePaths(remote, self.opts.localGame) end
  local ok, games = pcall(loader.loadGamesFromDirectory, paths.gamesDir())
  if not ok then return remote end
  for _, g in ipairs(games) do
    if g.id == remote.id then return resolver.mergeLocalImagePaths(remote, g) end
  end
  return remote
end

function ClientGame:handleMessage(m)
  local p = m.payload
  if m.type == "lobbyRosterUpdate" then
    self.roster = util.map(p.players or {}, models.PlayerInfo.fromJson)
    self.maxPlayers = p.maxPlayers or self.maxPlayers
    local bytes = {}
    for id, b64 in pairs(p.avatars or {}) do
      local ok, b = pcall(love.data.decode, "string", "base64", b64)
      if ok then bytes[id] = b end
    end
    self.avatarBytes = bytes
    if self.table then self.table.avatarKeys = avatarKeys(bytes) end
  elseif m.type == "gameData" then
    local ok, game = pcall(models.GameDefinition.fromJson, p)
    if not ok then return end
    game = self:resolveLocalImages(game)
    self.game = game
    self.title = game.name
    if self.session then
      -- Same game resent (e.g. after a reconnect): refresh definitions.
      self.session.game = game
      self.session.definitionsById = {}
      for _, c in ipairs(game.cards) do self.session.definitionsById[c.id] = c end
    end
  elseif m.type == "cardDragPreview" then
    if self.session then
      self.session.cardDragPreviews[p.playerId] = { playerId = p.playerId, instanceIds = p.instanceIds or {}, fx = p.fx, fy = p.fy }
    end
  elseif m.type == "cardDragPreviewEnd" then
    if self.session then self.session.cardDragPreviews[p.playerId] = nil end
  elseif m.type == "arrowDragPreview" then
    if self.session then
      self.session.arrowDragPreviews[p.playerId] = { playerId = p.playerId, fx = p.fx, fy = p.fy, fx2 = p.fx2, fy2 = p.fy2 }
    end
  elseif m.type == "arrowDragPreviewEnd" then
    if self.session then self.session.arrowDragPreviews[p.playerId] = nil end
  elseif m.type == "fullState" then
    local ok, state = pcall(models.TableState.fromJson, p)
    if not ok then return end
    if not self.session then
      if not self.game then return end
      self.session = Session.new({ game = self.game, localPlayerId = self.localPlayerId, initialState = state })
      self.table = TableScreen.new({
        session = self.session,
        controller = controller.Client.new(function(t, payload) self.client:send(t, payload) end),
        game = self.game,
        isMirrored = false,
        localAvatarPath = app().profile.avatarPath,
        avatarKeys = avatarKeys(self.avatarBytes),
        sc = self.opts.sc,
        leaveButtonLabel = "Leave Game",
        leaveConfirmationMessage = self.opts.leaveMessage
          or "Leave the game? If the host is still hosting, you can rejoin in the same seat later.",
        onLeaveGame = function() self:returnHome("You left the game.") end,
        spectator = self.opts.spectator,
        collectionMode = self.opts.collectionMode,
        deckStore = self.opts.deckStore,
        -- Only set for dedicated-server games (see server/common.lua:gameScreen);
        -- a peer-hosted client never has this and keeps Load Scenario hidden,
        -- same as before.
        canLoadScenario = self.opts.isRoomOwner,
      })
      self.session:addListener(function() self:publishPresence() end)
      self:publishPresence()
    else
      self.session:applyRemoteState(state)
    end
  end
end

function ClientGame:isMirrored()
  if self.game.sameOrientationForAll then return false end
  local players = self.session.state.players
  local n = #players
  if n < 2 then return true end
  for i, pl in ipairs(players) do
    if pl.id == self.localPlayerId then return seats.isFarMirrorSeat(i - 1, n) end
  end
  return true
end

function ClientGame:update(dt)
  if self.table then
    if self.opts.avatarKeys then self.table.avatarKeys = self.opts.avatarKeys() end
    self.table.isMirrored = self:isMirrored()
    self.table:update(dt)
  end
end

function ClientGame:draw(x, y, w, h)
  if not self.table then
    local cx, cy = x + w / 2, y + h / 2
    ui.spinner(cx, cy - 30, 18)
    ui.text(self.opts.onExit and "Loading the game..." or "Waiting for host to start the game...", x, cy, { w = w, align = "center" })
    if #self.roster > 1 then
      ui.text(#self.roster .. "/" .. self.maxPlayers .. " players joined", x, cy + 28, { w = w, align = "center" })
    end
    return
  end
  self.table:draw(x, y, w, h)
end

function ClientGame:keypressed(...) if self.table then self.table:keypressed(...) end end

return M
