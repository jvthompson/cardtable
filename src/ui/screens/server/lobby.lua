-- The server lobby: games (rooms) to join or watch, chat, who's online,
-- and the way into the server's Deck Editor, Card Shop, Collection and
-- Administration.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local widgets = require("src.ui.kit.widgets")
local colorpicker = require("src.ui.kit.colorpicker")
local json = require("lib.json")
local fs = require("src.data.fs")
local profile = require("src.data.profile")
local fileDialog = require("src.platform.file_dialog")
local SC = require("src.net.server_client")
local common = require("src.ui.screens.server.common")
local loader = require("src.data.game_loader")
local util = require("src.core.util")

local Lobby = {}
Lobby.__index = Lobby

local function app() return require("src.app") end

local CLOSE_REASONS = {
  closedByOwner = "The game was ended by its creator.",
  idle = "The game was closed after everyone left.",
  error = "The game could not be started.",
  empty = nil,
}

function Lobby.new(sc)
  local self = setmetatable({ title = sc.info.name or "CardTable Server", sc = sc, isServerLobby = true,
    chatText = "", seenChat = 0 }, Lobby)
  self:loadSelectedGame()
  sc:on("lobbyState", function() self:loadSelectedGame() end)
  sc:on("disconnected", function() app().popToHome(sc:disconnectMessage()) end)
  sc:on("roomClosed", function(_, reason, mine)
    if mine then
      sc:closeChannel()
      common.returnToLobby(CLOSE_REASONS[reason] or "The game was closed.")
    end
  end)
  sc:on("tradeInvite", function(p) self:onTradeInvite(p) end)
  sc:on("tradeClosed", function(p) self:onTradeClosed(p) end)
  sc:on("trade", function() self:onTradeUpdate() end)
  return self
end

function Lobby:onBack()
  overlays.confirm("Leave Server", "Disconnect from " .. (self.sc.info.name or "this server") .. "?", "Disconnect", function()
    self.sc:disconnect()
    app().popToHome()
  end)
end

function Lobby:quit() self.sc:disconnect() end

-- Signs out: the server drops the session token, and Remember me is turned
-- off so the next sign-in asks for the password again.
function Lobby:logOut()
  local sc = self.sc
  SC.clearSession(sc.key)
  -- The server closes the connection after replying; that's expected here.
  sc:on("disconnected", function() end)
  local function done()
    sc:disconnect()
    app().popToHome()
    overlays.toast("Logged out of " .. (sc.info.name or "the server") .. ".")
  end
  sc:request("logout", json.object({ "token", sc.token }), done)
end

---------------------------------------------------------------------------
-- Dialogs
---------------------------------------------------------------------------

-- The game currently selected for Shop/Deck Editor/Collection/Create Game
-- on this server, restored from what was last picked here (if any and
-- still valid) once the server's game list arrives.
function Lobby:loadSelectedGame()
  local sc = self.sc
  if sc.selectedGameId or #sc.games == 0 then return end
  local remembered = SC.lastGameId(sc.key)
  if remembered and sc:gameById(remembered) then common.selectGame(sc, remembered) end
end

-- The header's Choose Game button: always lets the player pick (or
-- switch) the selected game.
function Lobby:chooseGame()
  local sc = self.sc
  if #sc.games == 0 then
    overlays.alert("No Games", "This server doesn't have any games yet. An admin can add game folders to the server's games directory.")
    return
  end
  app().push(common.pickGame(sc, "Choose a Game", "Pick the game you want to play, shop, and manage decks for.", function(g)
    app().pop()
    common.selectGame(sc, g.id)
  end))
end

function Lobby:openCreateGame()
  common.withSelectedGame(self.sc, "Create Game", function(info) self:openCreateGameDialog(info) end)
end

-- Create Game, step 2: name and player count for the chosen game.
function Lobby:openCreateGameDialog(game)
  local sc = self.sc
  local st = { gameId = game.id, name = "", players = 2 }
  local playerOptions = {}
  for n = 1, 8 do playerOptions[#playerOptions + 1] = { value = n, label = n == 1 and "1 player" or (n .. " players") } end
  overlays.dialog({
    title = "Create Game -- " .. game.name,
    width = 440,
    content = function(_, x, y, w)
      local bg = theme.c.surfaceContainerHigh
      local yy = y + 8
      st.name = ui.textField("cg:name", x, yy, w, st.name, { label = "Name (optional)", hint = sc.self.name .. "'s game",
        labelBackground = bg, maxLength = 40 })
      yy = yy + 48 + 16
      st.players = ui.dropdown("cg:players", x, yy, w, playerOptions, st.players, { label = "Players" })
      yy = yy + 48 + 12
      local note = sc:isCollectionMode() and "Collection mode: players load decks built from cards they own."
        or "Players can join until the game starts. After that, others can watch."
      ui.text(note, x, yy, { w = w, size = 12, color = theme.c.onSurfaceVariant })
      return yy + ui.textHeight(note, w, 12) - y
    end,
    actions = {
      { label = "Cancel", variant = "text" },
      { label = "Create", variant = "filled", onClick = function() self:createGame(st) end },
    },
  })
end

function Lobby:createGame(st)
  local sc = self.sc
  common.withGame(sc, st.gameId, function(game)
    sc:closeChannel()
    sc:gameChannel()
    sc:request("roomCreate", json.object({ "gameId", st.gameId, "name", st.name, "maxPlayers", st.players }), function(r)
      if not r.ok then
        sc:closeChannel()
        overlays.alert("Couldn't Create Game", r.message or "Something went wrong.")
        return
      end
      sc.roomId, sc.spectating, sc.roomChat = r.room.id, false, {}
      common.openRoomScreen(sc, game, r.room)
    end)
  end)
end

---------------------------------------------------------------------------
-- Trading
---------------------------------------------------------------------------

-- Step 1: pick which game to trade in, reusing the Create Game game-tile
-- picker; step 2 sends the invite and shows a "waiting for a response"
-- dialog until the other player responds (or the request is cancelled).
function Lobby:askToTrade(u)
  local sc = self.sc
  if #sc.games == 0 then
    overlays.alert("No Games", "This server doesn't have any games yet.")
    return
  end
  app().push(common.pickGame(sc, "Ask to Trade", "Pick the game to trade in.", function(g)
    app().pop()
    self:sendTradeRequest(u, g)
  end))
end

function Lobby:sendTradeRequest(u, g)
  local sc = self.sc
  sc:request("tradeRequest", json.object({ "targetId", u.id, "gameId", g.id }), function(r)
    if not r.ok then
      overlays.alert("Couldn't Send Trade Request", r.message or "Something went wrong.")
      return
    end
    self.waitingTradeId = r.tradeId
    self.waitingTradeDialog = overlays.dialog({
      title = "Trade Request Sent",
      width = 380,
      dismissible = false,
      content = function(_, x, y, w)
        ui.spinner(x + w / 2, y + 14, 14)
        local msg = "Waiting for " .. u.name .. " to respond..."
        ui.text(msg, x, y + 44, { w = w, align = "center", color = theme.c.onSurfaceVariant })
        return 44 + ui.textHeight(msg, w)
      end,
      actions = { { label = "Cancel", variant = "text", onClick = function()
        sc:request("tradeLeave", json.object({ "tradeId", self.waitingTradeId }))
        self.waitingTradeId, self.waitingTradeDialog = nil, nil
      end } },
    })
  end)
end

-- Someone else asked to trade with us.
function Lobby:onTradeInvite(p)
  local sc = self.sc
  local function respond(accept)
    sc:request("tradeRespond", json.object({ "tradeId", p.tradeId, "accept", accept }))
    self.tradeInviteId, self.tradeInviteDialog = nil, nil
  end
  self.tradeInviteId = p.tradeId
  self.tradeInviteDialog = overlays.dialog({
    title = "Trade Request",
    message = p.fromName .. " wants to trade with you.",
    width = 420,
    dismissible = false,
    actions = {
      { label = "Decline", variant = "text", onClick = function() respond(false) end },
      { label = "Accept", variant = "filled", onClick = function() respond(true) end },
    },
  })
end

-- The trade we were waiting on (or playing) ended: declined, expired, left,
-- or completed.
function Lobby:onTradeClosed(p)
  if self.waitingTradeId == p.tradeId then
    if self.waitingTradeDialog then self.waitingTradeDialog:close() end
    self.waitingTradeId, self.waitingTradeDialog = nil, nil
    local messages = { declined = "They declined your trade request.", expired = "They didn't respond in time." }
    overlays.toast(messages[p.reason] or "The trade request was cancelled.")
  end
  if self.tradeInviteId == p.tradeId then
    if self.tradeInviteDialog then self.tradeInviteDialog:close() end
    self.tradeInviteId, self.tradeInviteDialog = nil, nil
  end
  -- Whether the Trade screen is showing is read straight off the screen
  -- stack rather than a separately-tracked flag: a flag set only by the
  -- "trade" push and cleared only by a "tradeClosed" push would get stuck
  -- whenever a screen transition happens some other way (e.g. the server
  -- only pushes "tradeClosed" to the *other* player when someone leaves).
  local top = app().top()
  if top and top.isTradeScreen then
    local messages = { completed = "Trade complete.", left = "The other player left the trade." }
    common.returnToLobby(messages[p.reason] or "The trade ended.")
  end
end

-- A trade we're part of just started (or was already open and changed) --
-- make sure the Trade screen is showing.
function Lobby:onTradeUpdate()
  local top = app().top()
  if top and top.isTradeScreen then return end
  if self.waitingTradeDialog then self.waitingTradeDialog:close() end
  self.waitingTradeId, self.waitingTradeDialog = nil, nil
  local sc = self.sc
  common.withGame(sc, sc.trade.gameId, function(game)
    app().push(require("src.ui.screens.server.trade").new(sc, game))
  end)
end

function Lobby:openProfile()
  local sc = self.sc
  local me = sc.self
  local st = { name = me.name, color = me.color, avatarChanged = false, current = "", password = "", confirm = "" }
  overlays.dialog({
    title = "Your Profile on " .. (sc.info.name or "this server"),
    width = 440,
    content = function(_, x, y, w)
      local bg = theme.c.surfaceContainerHigh
      local yy = y
      local size = 120
      local ax = x + (w - size) / 2
      local r = ui.region("sp:avatar", ax, yy, size, size, { cursor = "hand", tooltip = "Choose an image" })
      local source
      if st.avatarChanged then
        source = st.avatarPath and { path = st.avatarPath } or nil
      else
        local key = sc:avatarKey(me.avatarHash)
        source = key and { key = key } or nil
      end
      widgets.avatar(ax, yy, size, st.color, source)
      if r.hovered then ui.rect("fill", ax, yy, size, size, 0, { 1, 1, 1, 0.08 }) end
      if r.clicked then
        fileDialog.openFile({ title = "Choose an avatar image", filters = fileDialog.imageFilters }, function(path)
          if path then st.avatarPath, st.avatarChanged = path, true end
        end)
      end
      yy = yy + size + 4
      if source then
        local bw = ui.buttonWidth("Remove Image", { icon = "delete_outline" })
        if ui.button("Remove Image", x + (w - bw) / 2, yy, bw, nil, { variant = "text", icon = "delete_outline", id = "sp:rm" }) then
          st.avatarPath, st.avatarChanged = nil, true
        end
        yy = yy + 44
      end
      yy = yy + 12
      st.name = ui.textField("sp:name", x, yy, w, st.name, { label = "Player name", labelBackground = bg, maxLength = 24 })
      yy = yy + 48 + 16
      local col, ch = colorpicker.field("sp:color", x, yy, w, st.color, { label = "Player Color", labelBackground = bg })
      st.color = col
      yy = yy + ch + 20
      ui.text("Change password (optional)", x, yy, { weight = "medium" })
      yy = yy + 28
      st.current = ui.textField("sp:cur", x, yy, w, st.current, { label = "Current password", password = true, labelBackground = bg })
      yy = yy + 48 + 12
      st.password = ui.textField("sp:new", x, yy, w, st.password, { label = "New password", password = true, labelBackground = bg })
      yy = yy + 48 + 12
      st.confirm = ui.textField("sp:conf", x, yy, w, st.confirm, { label = "Confirm new password", password = true, labelBackground = bg })
      yy = yy + 48
      if st.error then
        yy = yy + 12
        ui.text(st.error, x, yy, { w = w, color = theme.fixed.red })
        yy = yy + ui.textHeight(st.error, w)
      end
      return yy - y
    end,
    actions = {
      { label = "Log Out", variant = "text", onClick = function()
        overlays.confirm("Log Out", "Log out of " .. (sc.info.name or "this server")
          .. "? You'll need to enter your password the next time you sign in.", "Log Out", function() self:logOut() end)
      end },
      { label = "Cancel", variant = "text" },
      { label = "Save", variant = "filled", onClick = function()
        local payload = json.object()
        local name = util.trim(st.name)
        if name ~= me.name then payload.name = name end
        if st.color ~= me.color then payload.color = st.color end
        if st.avatarChanged then
          payload.avatar = ""
          if st.avatarPath then
            local bytes = fs.readFile(st.avatarPath)
            local png = bytes and profile.resizeAvatarBytes(bytes)
            if not png then
              st.error = "Could not use that image."
              return true
            end
            payload.avatar = love.data.encode("string", "base64", png)
          end
        end
        if st.password ~= "" or st.current ~= "" then
          local pwErr = SC.passwordError(st.password, "new password")
          if pwErr then
            st.error = pwErr
            return true
          end
          if st.password ~= st.confirm then
            st.error = "The new passwords don't match."
            return true
          end
          payload.oldPasswordHash = SC.passwordHash(me.email, st.current)
          payload.passwordHash = SC.passwordHash(me.email, st.password)
        end
        st.error = nil
        sc:request("profileUpdate", payload, function(r)
          if r.ok then
            sc.self = r.user
            overlays.toast("Profile updated.")
          else
            overlays.alert("Couldn't Update Profile", r.message or "Something went wrong.")
          end
        end)
      end },
    },
  })
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function seatSummary(room)
  return #room.seats .. "/" .. room.maxPlayers
end

function Lobby:mySeat(room)
  for _, s in ipairs(room.seats) do
    if s.id == self.sc.self.id then return s end
  end
end

function Lobby:drawRoom(room, x, y, w)
  local c = theme.c
  local sc = self.sc
  local h = 88
  ui.rect("fill", x, y, w, h, 12, c.surfaceContainer)
  local playing = room.state == "playing"
  local seat = self:mySeat(room)
  -- Buttons on the right.
  local bx = x + w - 16
  local function button(label, variant, id)
    local bw = ui.buttonWidth(label)
    bx = bx - bw
    local clicked = ui.button(label, bx, y + (h - 40) / 2, bw, 40, { variant = variant, id = id .. room.id })
    bx = bx - 8
    return clicked
  end
  local isOwner = room.ownerId == sc.self.id
  if (isOwner or sc:isAdmin()) and button("End", "text", "lb:end:") then
    overlays.confirm("End Game", 'End "' .. room.name .. '" for everyone in it?', "End Game", function()
      sc:request("roomClose", json.object({ "roomId", room.id }), function(r)
        if not r.ok then overlays.toast(r.message or "Couldn't end the game.") end
      end)
    end, { danger = true })
  end
  -- Seated players of a running game rejoin rather than watch.
  if not (playing and seat) and button("Watch", "outlined", "lb:watch:") then common.enterRoom(sc, room, "spectate") end
  if playing then
    if seat and button("Rejoin", "filled", "lb:rejoin:") then common.enterRoom(sc, room, "join") end
  elseif #room.seats < room.maxPlayers or seat then
    if button("Join", "filled", "lb:join:") then common.enterRoom(sc, room, "join") end
  end
  -- Text on the left.
  local tx, tw = x + 20, bx - x - 28
  local chip = playing and "In progress" or "Waiting for players"
  local chipCol = playing and theme.fixed.green or theme.fixed.blue
  ui.text(room.name, tx, y + 14, { weight = "bold", w = tw, ellipsis = true })
  local sub = room.gameName .. "  ·  " .. seatSummary(room) .. " players"
  if room.spectators > 0 then sub = sub .. "  ·  " .. room.spectators .. " watching" end
  ui.text(sub, tx, y + 36, { size = 12, w = tw, ellipsis = true, color = c.onSurfaceVariant })
  local cw = ui.textWidth(chip, 11, "medium") + 16
  ui.rect("fill", tx, y + 58, cw, 20, 10, theme.alpha(chipCol, 0.15))
  ui.text(chip, tx, y + 58, { size = 11, weight = "medium", w = cw, h = 20, align = "center", valign = "middle", color = chipCol })
  local ax = tx + cw + 12
  for _, s in ipairs(room.seats) do
    if ax + 20 > tx + tw then break end
    local user = { name = s.name, color = s.color }
    for _, u in ipairs(sc.users) do if u.id == s.id then user = u end end
    local key = sc:avatarKey(user.avatarHash)
    widgets.avatar(ax, y + 58, 20, s.color, key and { key = key } or nil, false)
    if playing and not s.connected then ui.rect("fill", ax, y + 58, 20, 20, 0, { 0, 0, 0, 0.45 }) end
    ui.region("lb:seat:" .. room.id .. s.id, ax, y + 58, 20, 20, { tooltip = s.name .. ((playing and not s.connected) and " (away)" or "") })
    ax = ax + 24
  end
  return h
end

function Lobby:drawRooms(x, y, w, h)
  local c = theme.c
  local sc = self.sc
  ui.text("Games", x, y + 8, { size = 20 })
  ui.text(tostring(#sc.rooms), x + ui.textWidth("Games", 20) + 10, y + 13, { size = 13, color = c.onSurfaceVariant })
  local label = "Create Game"
  local bw = ui.buttonWidth(label, { icon = "add" })
  if ui.button(label, x + w - bw, y, bw, 40, { icon = "add", id = "lb:create" }) then self:openCreateGame() end
  local ly = y + 56
  local lh = y + h - ly
  if #sc.rooms == 0 then
    ui.text("No games right now. Create one and others can join you.", x, ly, { w = w, h = math.min(lh, 160), align = "center",
      valign = "middle", color = c.onSurfaceVariant })
    return
  end
  local off = ui.beginScroll("lb:rooms", x, ly, w, lh)
  local ry = ly - off
  for _, room in ipairs(sc.rooms) do
    ry = ry + self:drawRoom(room, x, ry, w - 4) + 10
  end
  ui.endScroll("lb:rooms", ry + off - ly)
end

function Lobby:drawChat(x, y, w, h)
  local c = theme.c
  local sc = self.sc
  ui.rect("fill", x, y, w, h, 12, c.surfaceContainer)
  ui.text("Chat", x + 16, y + 12, { weight = "bold" })
  local inputH = 48
  local ly, lh = y + 40, h - 40 - inputH - 24
  local off = ui.beginScroll("lb:chat", x + 8, ly, w - 16, lh)
  local cy = ly - off
  local textW = w - 32
  for _, line in ipairs(sc.chat) do
    local head = common.timeLabel(line.at) .. "  " .. line.name
    ui.text(head, x + 16, cy, { size = 12, weight = "bold", color = c.onSurfaceVariant, w = textW, ellipsis = true })
    cy = cy + 18
    ui.text(line.text, x + 16, cy, { w = textW })
    cy = cy + ui.textHeight(line.text, textW) + 10
  end
  local contentH = cy + off - ly
  ui.endScroll("lb:chat", contentH)
  if #sc.chat ~= self.seenChat then
    self.seenChat = #sc.chat
    ui.scrollToEnd("lb:chat")
  end
  if #sc.chat == 0 then
    ui.text("Say hello!", x, ly, { w = w, h = lh, align = "center", valign = "middle", color = c.onSurfaceVariant })
  end
  local text, _, submitted = ui.textField("lb:chatinput", x + 12, y + h - inputH - 12, w - 24 - 44, self.chatText,
    { label = "Message", labelBackground = c.surfaceContainer, maxLength = 500 })
  self.chatText = text
  local send = ui.iconButton("send", x + w - 12 - 40, y + h - inputH - 12 + 4, { id = "lb:send", tooltip = "Send",
    disabled = text:match("^%s*$") ~= nil })
  if (submitted or send) and not text:match("^%s*$") then
    sc:send("chatSend", json.object({ "text", text }))
    self.chatText = ""
    ui.focusField("lb:chatinput")
  end
end

function Lobby:drawUsers(x, y, w, h)
  local c = theme.c
  local sc = self.sc
  ui.text("Online", x, y + 12, { weight = "bold" })
  ui.text(tostring(#sc.users), x + ui.textWidth("Online", 14, "bold") + 8, y + 12, { color = c.onSurfaceVariant })
  local ly = y + 44
  local off = ui.beginScroll("lb:users", x, ly, w, y + h - ly)
  local uy = ly - off
  for _, u in ipairs(sc.users) do
    local rowR = ui.region("lb:user:" .. u.id, x, uy, w - 8, 32, { cursor = "hand" })
    if rowR.rightClicked and u.id ~= sc.self.id and sc:isCollectionMode() and u.roomId == "" then
      local mx, my = ui.mouse()
      overlays.menu(mx, my, { { label = "Ask to Trade...", icon = "swap_horiz", onSelect = function() self:askToTrade(u) end } })
    end
    common.userRow(sc, u, x, uy, w - 8, { size = 32, h = 32, bold = u.id == sc.self.id })
    local status
    if u.roomId ~= "" then
      local room = sc:roomById(u.roomId)
      status = room and ((u.spectating and "Watching " or "In ") .. room.name) or nil
    end
    if status then
      ui.text(status, x + 42, uy + 32, { size = 11, w = w - 50, ellipsis = true, color = c.onSurfaceVariant })
      uy = uy + 14
    end
    if u.isAdmin then
      ui.region("lb:adm:" .. u.id, x + w - 26, uy + 7, 18, 18, { tooltip = "Server admin" })
      ui.icon("shield", x + w - 26, uy + 7, 18, c.primary)
    end
    uy = uy + 44
  end
  ui.endScroll("lb:users", uy + off - ly)
end

function Lobby:drawHeader(x, y, w)
  local c = theme.c
  local sc = self.sc
  local me = sc.self
  -- Right side: actions then the profile button.
  local rx = x + w
  local key = sc:avatarKey(me.avatarHash)
  local clicked
  rx, clicked = widgets.headerPill("lb:profile", rx, y, me.name, "Edit your profile", function(ix, iy)
    widgets.avatar(ix, iy, 32, me.color, key and { key = key } or nil, false)
  end)
  if clicked then self:openProfile() end
  local function action(label, icon, id)
    local bw = ui.buttonWidth(label, { icon = icon })
    rx = rx - bw - 8
    return ui.button(label, rx, y + 4, bw, 40, { variant = "text", icon = icon, id = id })
  end
  -- The selected game: name (and, once loaded, its default card back) --
  -- same treatment as the profile button, immediately to its left.
  local gameInfo = sc.selectedGameId and sc:gameById(sc.selectedGameId)
  local gameLabel = gameInfo and gameInfo.name or "Choose Game"
  local back = sc.selectedGame and sc.selectedGame.cardBacks[1]
  local hasThumb = back and back.imagePath
  rx = rx - 8
  rx, clicked = widgets.headerPill("lb:game", rx, y, gameLabel, "Choose which game to play", hasThumb and function(ix, iy)
    widgets.avatar(ix, iy, 32, 0xFF000000, { path = back.imagePath }, false)
  end or nil)
  if clicked then self:chooseGame() end
  -- The Standard 52-Card Deck can't be shopped for, edited, or collected --
  -- only Create Game can use it -- so those three buttons disappear while
  -- it's the selected game.
  local isStandardDeck = sc.selectedGameId == loader.standardDeckId
  if sc:isAdmin() and action("Admin", "shield", "lb:admin") then
    app().push(require("src.ui.screens.server.admin").new(sc))
  end
  if not isStandardDeck and sc:isCollectionMode() and action("Collection", "layers", "lb:coll") then
    common.withSelectedGame(sc, "Collection", function(info)
      app().push(require("src.ui.screens.server.collection").new(sc, info))
    end, { excludeStandardDeck = true })
  end
  if not isStandardDeck and action("Deck Editor", "build", "lb:decks") then
    common.withSelectedGame(sc, "Deck Editor", function(info)
      require("src.ui.screens.server.decks").open(sc, info)
    end, { excludeStandardDeck = true })
  end
  if not isStandardDeck and sc:isCollectionMode() and action("Card Shop", "card_giftcard", "lb:shop") then
    common.withSelectedGame(sc, "Card Shop", function(info)
      app().push(require("src.ui.screens.server.shop").new(sc, info))
    end, { excludeStandardDeck = true })
  end
  if sc:isCollectionMode() then
    local t = tostring(me.tokens or 0) .. " tokens"
    local tw = ui.textWidth(t, 13, "medium") + 40
    rx = rx - tw - 12
    ui.rect("fill", rx, y + 10, tw, 28, 14, c.secondaryContainer)
    ui.icon("toll", rx + 10, y + 15, 18, c.onSecondaryContainer)
    ui.text(t, rx + 32, y + 10, { size = 13, weight = "medium", h = 28, valign = "middle", color = c.onSecondaryContainer })
  end
  -- Left: server name and message of the day.
  local lw = rx - x - 16
  ui.text(sc.info.name or "CardTable Server", x, y + 2, { size = 22, w = lw, ellipsis = true })
  local sub = sc.info.motd ~= "" and sc.info.motd or (sc:isCollectionMode() and "Collection mode" or "Free play")
  ui.text(sub or "", x, y + 32, { size = 12, w = lw, ellipsis = true, color = c.onSurfaceVariant })
end

function Lobby:draw(x, y, w, h)
  local sc = self.sc
  if not sc.self then
    ui.spinner(x + w / 2, y + h / 2, 18)
    return
  end
  local pad = 24
  self:drawHeader(x + pad, y + 16, w - 2 * pad)
  local by = y + 16 + 48 + 20
  local bh = y + h - pad - by
  local usersW = w >= 1180 and 220 or 0
  local chatW = 340
  local roomsW = w - 2 * pad - chatW - 24 - (usersW > 0 and usersW + 24 or 0)
  ui.pushClip(x + pad, by, roomsW, bh)
  self:drawRooms(x + pad, by, roomsW, bh)
  ui.popClip()
  local chatX = x + pad + roomsW + 24
  self:drawChat(chatX, by, chatW, bh)
  if usersW > 0 then
    ui.pushClip(chatX + chatW + 24, by, usersW, bh)
    self:drawUsers(chatX + chatW + 24, by, usersW, bh)
    ui.popClip()
  end
end

return Lobby
