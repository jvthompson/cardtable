-- Server Administration (admins only): accounts, server settings, games
-- and running rooms.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local widgets = require("src.ui.kit.widgets")
local json = require("lib.json")
local fs = require("src.data.fs")
local fileDialog = require("src.platform.file_dialog")
local SC = require("src.net.server_client")
local AFM = require("src.net.admin_file_manager")
local AGM = require("src.net.admin_game_manager")
local common = require("src.ui.screens.server.common")
local util = require("src.core.util")

local A = {}
A.__index = A

local TABS = { "Users", "Server", "Games", "Files" }

local function formatBytes(n)
  if n >= 1024 * 1024 then return string.format("%.1f MB", n / (1024 * 1024)) end
  return string.format("%d KB", math.floor(n / 1024 + 0.5))
end

function A.new(sc)
  local self = setmetatable({ title = "Server Administration", sc = sc, tab = 1, search = "", users = nil }, A)
  self:refreshUsers()
  self:refreshSettings()
  return self
end

function A:refreshUsers()
  self.sc:request("adminUsers", json.object(), function(r)
    if r.ok then self.users = r.users else overlays.toast(r.message or "Couldn't load users.") end
  end)
end

function A:refreshSettings()
  self.sc:request("adminSettingsGet", json.object(), function(r)
    if not r.ok then return end
    self.settings = r.settings
    self.gameErrors = r.gameErrors or {}
    -- The form edits text; numbers are parsed on save.
    local s = r.settings
    self.form = {
      serverName = s.serverName, motd = s.motd, registrationOpen = s.registrationOpen, mode = s.mode,
      startingTokens = tostring(s.startingTokens), packCost = tostring(s.packCost),
      starterDeckCost = tostring(s.starterDeckCost or 3),
      allowanceAmount = tostring(s.allowanceAmount), allowancePeriod = s.allowancePeriod,
      roomIdleTimeoutMin = tostring(s.roomIdleTimeoutMin), maxRooms = tostring(s.maxRooms), chatHistory = tostring(s.chatHistory),
      maxUploadMB = tostring(s.maxUploadMB),
    }
  end)
end

---------------------------------------------------------------------------
-- Users
---------------------------------------------------------------------------

function A:updateUser(id, fields, onDone)
  fields.id = id
  self.sc:request("adminUserUpdate", fields, function(r)
    if r.ok then
      self.users = r.users
      if onDone then onDone() end
    else
      overlays.alert("Couldn't Update User", r.message or "Something went wrong.")
    end
  end)
end

function A:editUser(u)
  local sc = self.sc
  local st = { name = u.name, email = u.email, isAdmin = u.isAdmin, disabled = u.disabled, tokens = tostring(u.tokens),
    grant = "", password = "" }
  local isSelf = u.id == sc.self.id
  overlays.dialog({
    title = u.name,
    width = 460,
    content = function(d, x, y, w)
      local c = theme.c
      local bg = c.surfaceContainerHigh
      local yy = y + 8
      st.name = ui.textField("au:name", x, yy, w, st.name, { label = "Player name", labelBackground = bg, maxLength = 24 })
      yy = yy + 48 + 12
      st.email = ui.textField("au:email", x, yy, w, st.email, { label = "Email address", labelBackground = bg })
      yy = yy + 48 + 16
      st.isAdmin = ui.switchRow("au:admin", "Server admin", x, yy, w, st.isAdmin)
      yy = yy + 40
      st.disabled = ui.switchRow("au:disabled", "Account disabled", x, yy, w, st.disabled, { disabled = isSelf })
      yy = yy + 48
      ui.text("Tokens", x, yy, { weight = "medium" })
      yy = yy + 28
      local half = (w - 12) / 2
      local digits = function(t) return t:match("^%d+$") ~= nil end
      st.tokens = ui.textField("au:tokens", x, yy, half, st.tokens, { label = "Balance", labelBackground = bg, filter = digits })
      st.grant = ui.textField("au:grant", x + half + 12, yy, half, st.grant, { label = "Grant (adds)", labelBackground = bg,
        filter = function(t) return t:match("^%-?%d*$") ~= nil end })
      yy = yy + 48 + 16
      ui.text("Reset password", x, yy, { weight = "medium" })
      yy = yy + 28
      st.password = ui.textField("au:pw", x, yy, w, st.password, { label = "New password (leave blank to keep)", password = true,
        labelBackground = bg })
      yy = yy + 48 + 8
      ui.text("Tell the player their new password; they can change it from their profile.", x, yy, { size = 12, w = w,
        color = c.onSurfaceVariant })
      yy = yy + 28
      if #sc.games > 0 then
        ui.text("Clear collection", x, yy, { weight = "medium" })
        yy = yy + 28
        local gameOpts = {}
        for _, g in ipairs(sc.games) do gameOpts[#gameOpts + 1] = { value = g.id, label = g.name } end
        st.clearGameId = st.clearGameId or gameOpts[1].value
        local cbw = ui.buttonWidth("Clear")
        local dw = w - cbw - 12
        st.clearGameId = ui.dropdown("au:cleargame", x, yy, dw, gameOpts, st.clearGameId, { labelBackground = bg })
        if ui.button("Clear", x + dw + 12, yy, cbw, 48, { variant = "outlined", color = theme.fixed.red, id = "au:clear" }) then
          local game
          for _, g in ipairs(sc.games) do
            if g.id == st.clearGameId then game = g end
          end
          if game then
            overlays.confirm("Clear Collection", 'Remove every card ' .. u.name .. ' owns in "' .. game.name
              .. '"? Decks that use those cards are kept but will be missing them. This can\'t be undone.',
              "Clear Collection", function()
                sc:request("adminClearCollection", json.object({ "id", u.id, "gameId", game.id }), function(r)
                  if r.ok then
                    overlays.toast('Cleared ' .. u.name .. '\'s collection for "' .. game.name .. '".')
                  else
                    overlays.alert("Couldn't Clear Collection", r.message or "Something went wrong.")
                  end
                end)
              end, { danger = true })
          end
        end
        yy = yy + 48 + 16
      end
      if not isSelf then
        local bx = x - 12
        if u.online and ui.button("Disconnect", bx, yy, nil, 40, { variant = "text", icon = "logout", id = "au:kick" }) then
          sc:request("adminKick", json.object({ "id", u.id }), function() self:refreshUsers() end)
          d:close()
        end
        bx = bx + (u.online and ui.buttonWidth("Disconnect", { icon = "logout" }) + 8 or 0)
        if ui.button("Delete Account", bx, yy, nil, 40, { variant = "text", icon = "delete_outline", id = "au:del",
          color = theme.fixed.red }) then
          overlays.confirm("Delete Account", 'Delete "' .. u.name .. '"? Their decks and collection are deleted too. This can\'t be undone.',
            "Delete", function()
              sc:request("adminUserDelete", json.object({ "id", u.id }), function(r)
                if r.ok then self.users = r.users else overlays.alert("Couldn't Delete", r.message or "Something went wrong.") end
              end)
              d:close()
            end, { danger = true })
        end
        yy = yy + 40
      end
      return yy - y
    end,
    actions = {
      { label = "Cancel", variant = "text" },
      { label = "Save", variant = "filled", onClick = function()
        local f = json.object()
        local name = util.trim(st.name)
        local email = util.trim(st.email)
        if name ~= u.name then f.name = name end
        if email:lower() ~= u.email:lower() then f.email = email end
        if st.isAdmin ~= u.isAdmin then f.isAdmin = st.isAdmin end
        if st.disabled ~= u.disabled then f.disabled = st.disabled end
        local bal = tonumber(st.tokens)
        if bal and bal ~= u.tokens then f.tokensSet = bal end
        local grant = tonumber(st.grant)
        if grant and grant ~= 0 then f.tokensAdd = grant end
        if st.password ~= "" then
          local pwErr = SC.passwordError(st.password)
          if pwErr then
            overlays.toast(pwErr)
            return true
          end
          -- Hashed with the email the account will have after this save.
          f.newPasswordHash = SC.passwordHash(f.email or u.email, st.password)
        end
        self:updateUser(u.id, f, function() overlays.toast("Saved " .. name .. ".") end)
      end },
    },
  })
end

function A:drawUsers(x, y, w, h)
  local c = theme.c
  local sc = self.sc
  self.search = ui.textField("au:search", x, y, math.min(360, w), self.search, { label = "Search users", labelBackground = c.surface })
  if ui.iconButton("refresh", x + w - 40, y + 4, { tooltip = "Refresh", id = "au:refresh" }) then self:refreshUsers() end
  local yy = y + 64
  if not self.users then
    ui.spinner(x + w / 2, yy + 40, 14)
    return
  end
  local q = self.search:lower()
  local list = {}
  for _, u in ipairs(self.users) do
    if q == "" or u.name:lower():find(q, 1, true) or u.email:lower():find(q, 1, true) then list[#list + 1] = u end
  end
  -- Header.
  local cols = { { "Player", 0.34 }, { "Email", 0.34 }, { "Tokens", 0.12 }, { "Status", 0.2 } }
  local cx = x + 16
  for _, col in ipairs(cols) do
    ui.text(col[1], cx, yy, { size = 12, weight = "bold", color = c.onSurfaceVariant })
    cx = cx + (w - 32) * col[2]
  end
  yy = yy + 24
  ui.divider(x, yy, w)
  local off = ui.beginScroll("au:list", x, yy, w, y + h - yy)
  local ry = yy - off
  for _, u in ipairs(list) do
    local r = ui.region("au:row:" .. u.id, x, ry, w, 52, { cursor = "hand" })
    if r.hovered then ui.rect("fill", x, ry, w, 52, 0, theme.alpha(c.onSurface, 0.05)) end
    local colX = x + 16
    common.userRow(sc, u, colX, ry + 10, (w - 32) * 0.34 - 12, { size = 32, h = 32, bold = u.id == sc.self.id })
    colX = colX + (w - 32) * 0.34
    ui.text(u.email, colX, ry, { h = 52, valign = "middle", w = (w - 32) * 0.34 - 12, ellipsis = true })
    colX = colX + (w - 32) * 0.34
    ui.text(tostring(u.tokens), colX, ry, { h = 52, valign = "middle" })
    colX = colX + (w - 32) * 0.12
    local tags = {}
    if u.isAdmin then tags[#tags + 1] = "Admin" end
    if u.disabled then tags[#tags + 1] = "Disabled" end
    if u.online then tags[#tags + 1] = "Online" end
    ui.text(table.concat(tags, " · "), colX, ry, { h = 52, valign = "middle", size = 13, w = (w - 32) * 0.2,
      color = u.disabled and theme.fixed.red or c.onSurfaceVariant })
    if r.clicked then self:editUser(u) end
    ry = ry + 52
    ui.divider(x, ry, w, theme.alpha(c.outlineVariant, 0.5))
  end
  ui.endScroll("au:list", ry + off - yy)
end

---------------------------------------------------------------------------
-- Server settings
---------------------------------------------------------------------------

function A:saveSettings()
  local f = self.form
  local function num(s, default) return tonumber(s) or default end
  local s = self.settings
  local payload = json.object({
    "serverName", f.serverName, "motd", f.motd, "registrationOpen", f.registrationOpen, "mode", f.mode,
    "startingTokens", num(f.startingTokens, s.startingTokens), "packCost", num(f.packCost, s.packCost),
    "starterDeckCost", num(f.starterDeckCost, s.starterDeckCost or 3),
    "allowanceAmount", num(f.allowanceAmount, s.allowanceAmount), "allowancePeriod", f.allowancePeriod,
    "roomIdleTimeoutMin", num(f.roomIdleTimeoutMin, s.roomIdleTimeoutMin), "maxRooms", num(f.maxRooms, s.maxRooms),
    "chatHistory", num(f.chatHistory, s.chatHistory), "maxUploadMB", num(f.maxUploadMB, s.maxUploadMB),
  })
  self.sc:request("adminSettingsSet", json.object({ "settings", payload }), function(r)
    if r.ok then
      overlays.toast("Server settings saved.")
      self:refreshSettings()
    else
      overlays.alert("Couldn't Save Settings", r.message or "Something went wrong.")
    end
  end)
end

local function sectionLabel(text, x, y)
  ui.text(text, x, y, { size = 12, weight = "bold", color = theme.c.primary })
  return 28
end

function A:drawServer(x, y, w, h)
  local c = theme.c
  local f = self.form
  if not f then
    ui.spinner(x + w / 2, y + 40, 14)
    return
  end
  local colW = math.min(640, w)
  local cx = x + (w - colW) / 2
  local bg = c.surface
  local digits = function(t) return t:match("^%d+$") ~= nil end
  local off = ui.beginScroll("as:scroll", x, y, w, h)
  local yy = y - off
  yy = yy + sectionLabel("GENERAL", cx, yy)
  f.serverName = ui.textField("as:name", cx, yy, colW, f.serverName, { label = "Server name", labelBackground = bg, maxLength = 60 })
  yy = yy + 48 + 12
  f.motd = ui.textField("as:motd", cx, yy, colW, f.motd, { label = "Message of the day", labelBackground = bg, maxLength = 200 })
  yy = yy + 48 + 12
  f.registrationOpen = ui.switchRow("as:reg", "Allow new accounts", cx, yy, colW, f.registrationOpen)
  yy = yy + 48
  yy = yy + sectionLabel("CARDS", cx, yy)
  f.mode = ui.segmented("as:mode", cx, yy, colW, { { value = "free", label = "Free Play" }, { value = "collection", label = "Collection" } }, f.mode)
  yy = yy + 40 + 8
  local modeHelp = f.mode == "collection"
    and "Players build decks only from cards they own, and open packs with tokens. Games started now don't allow the Pack Generator, though the Card Library stays available during play."
    or "Players can use every card in every game. Collections are kept, in case you switch back."
  ui.text(modeHelp, cx, yy, { w = colW, size = 12, color = c.onSurfaceVariant })
  yy = yy + ui.textHeight(modeHelp, colW, 12) + 16
  local quarter = (colW - 36) / 4
  f.startingTokens = ui.textField("as:start", cx, yy, quarter, f.startingTokens, { label = "Starting tokens", labelBackground = bg, filter = digits })
  f.packCost = ui.textField("as:cost", cx + quarter + 12, yy, quarter, f.packCost, { label = "Tokens per pack", labelBackground = bg, filter = digits })
  f.starterDeckCost = ui.textField("as:starter", cx + 2 * (quarter + 12), yy, quarter, f.starterDeckCost,
    { label = "Tokens per starter", labelBackground = bg, filter = digits })
  f.allowanceAmount = ui.textField("as:allow", cx + 3 * (quarter + 12), yy, quarter, f.allowanceAmount,
    { label = "Allowance", labelBackground = bg, filter = digits })
  yy = yy + 48 + 12
  ui.text("Allowance is given", cx, yy + 10, { color = c.onSurfaceVariant })
  local lw = ui.textWidth("Allowance is given", 14) + 16
  f.allowancePeriod = ui.segmented("as:period", cx + lw, yy, colW - lw, {
    { value = "none", label = "Never" }, { value = "daily", label = "Daily" }, { value = "weekly", label = "Weekly" },
  }, f.allowancePeriod)
  yy = yy + 40 + 8
  local allowHelp = "New accounts get the starting tokens. A starter deck (a built-in deck marked isStarter) gives the player its cards and a copy of the deck. The allowance is added once per day or week, the next time a player signs in (or while they're online)."
  ui.text(allowHelp, cx, yy, { w = colW, size = 12, color = c.onSurfaceVariant })
  yy = yy + ui.textHeight(allowHelp, colW, 12) + 20
  yy = yy + sectionLabel("LIMITS", cx, yy)
  f.roomIdleTimeoutMin = ui.textField("as:idle", cx, yy, quarter, f.roomIdleTimeoutMin, { label = "Idle game timeout (min)", labelBackground = bg, filter = digits })
  f.maxRooms = ui.textField("as:rooms", cx + quarter + 12, yy, quarter, f.maxRooms, { label = "Max games (0 = no limit)", labelBackground = bg, filter = digits })
  f.chatHistory = ui.textField("as:chat", cx + 2 * (quarter + 12), yy, quarter, f.chatHistory, { label = "Chat history", labelBackground = bg, filter = digits })
  f.maxUploadMB = ui.textField("as:upload", cx + 3 * (quarter + 12), yy, quarter, f.maxUploadMB, { label = "Max upload (MB)", labelBackground = bg, filter = digits })
  yy = yy + 48 + 8
  ui.text("A game closes after nobody has been at the table for the idle timeout (0 = never).", cx, yy, { w = colW, size = 12,
    color = c.onSurfaceVariant })
  yy = yy + 36
  if ui.button("Save Settings", cx, yy, nil, 44, { icon = "save", id = "as:save" }) then self:saveSettings() end
  yy = yy + 44 + 24
  yy = yy + sectionLabel("SHUTDOWN", cx, yy)
  yy = yy + self:drawShutdown(cx, yy, colW)
  ui.endScroll("as:scroll", yy + off - y)
end

-- Shut Down button, or the countdown once a shutdown is running. Returns
-- the height used.
function A:drawShutdown(x, y, w)
  local c = theme.c
  local sc = self.sc
  local help
  if sc.shutdownAt then
    local left = math.max(0, math.ceil(sc.shutdownAt - love.timer.getTime()))
    help = string.format("Shutting down in %d:%02d. New players can't connect, and the server closes early once "
      .. "everyone else has left.", math.floor(left / 60), left % 60)
  else
    if ui.button("Shut Down Server", x, y, nil, 44, { variant = "outlined", icon = "power_settings_new",
      color = theme.fixed.red, id = "as:shutdown", disabled = self.shuttingDown }) then
      overlays.confirm("Shut Down Server", "Everyone online is warned and has 5 minutes before the server shuts down "
        .. "(sooner if they all leave). Nobody new can connect in the meantime.", "Shut Down", function()
        self.shuttingDown = true
        sc:request("adminShutdown", json.object(), function(r)
          self.shuttingDown = false
          if not r.ok then overlays.alert("Couldn't Shut Down", r.message or "Something went wrong.") end
        end)
      end, { danger = true })
    end
    y = y + 44 + 8
    help = "The server can be started again from the machine it runs on."
  end
  ui.text(help, x, y, { w = w, size = 12, color = c.onSurfaceVariant })
  return (sc.shutdownAt and 0 or 52) + ui.textHeight(help, w, 12) + 24
end

---------------------------------------------------------------------------
-- Games and rooms
---------------------------------------------------------------------------

function A:uploadGame()
  if self.installingGame then return end
  fileDialog.openFile({ title = "Choose a game .zip file", filters = { { name = "Zip archive", extensions = { "zip" } } } },
    function(zipPath)
      if not zipPath then return end
      self.installingGame, self.installBytes, self.installTotal = true, 0, 0
      AGM.installFromZip(self.sc, zipPath, function(bytes, total)
        self.installBytes, self.installTotal = bytes, total
      end, function(err, gameId)
        self.installingGame = false
        if err then
          overlays.alert("Couldn't Add Game", err)
        else
          overlays.toast('Added game "' .. gameId .. '".')
        end
      end)
    end)
end

function A:removeGame(g)
  overlays.confirm("Remove Game", 'Permanently delete "' .. g.name .. '" and all of its files from the server? This can\'t be undone.',
    "Remove", function()
      AGM.remove(self.sc, g.id, function(r)
        if not r.ok then overlays.alert("Couldn't Remove Game", r.message or "Something went wrong.") end
      end)
    end, { danger = true })
end

function A:drawGames(x, y, w, h)
  local c = theme.c
  local sc = self.sc
  local colW = math.min(720, w)
  local cx = x + (w - colW) / 2
  local off = ui.beginScroll("ag:scroll", x, y, w, h)
  local yy = y - off
  ui.text("Games on this server", cx, yy, { size = 18 })
  local rescanLabel = "Rescan Games Folder"
  local rescanW = ui.buttonWidth(rescanLabel, { icon = "refresh" })
  local uploadLabel = self.installingGame and "Uploading..." or "Upload New Game"
  local uploadW = ui.buttonWidth(uploadLabel, { icon = "upload_file" })
  local rescanX = cx + colW - rescanW
  local uploadX = rescanX - 12 - uploadW
  if ui.button(uploadLabel, uploadX, yy - 6, uploadW, 40, { variant = "outlined", icon = "upload_file", id = "ag:upload",
    disabled = self.installingGame }) then
    self:uploadGame()
  end
  if ui.button(rescanLabel, rescanX, yy - 6, rescanW, 40, { variant = "outlined", icon = "refresh", id = "ag:rescan", disabled = self.scanning }) then
    self.scanning = true
    sc:request("adminRescanGames", json.object(), function(r)
      self.scanning = false
      if r.ok then
        sc.games = r.games
        self.gameErrors = r.gameErrors or {}
        overlays.toast("Found " .. #r.games .. " game(s).")
      else
        overlays.alert("Couldn't Rescan", r.message or "Something went wrong.")
      end
    end)
  end
  yy = yy + 40
  if self.installingGame then
    local pct = self.installTotal and self.installTotal > 0
      and string.format(" (%d%%)", math.floor(self.installBytes / self.installTotal * 100 + 0.5)) or ""
    ui.text("Uploading game" .. pct .. "...", cx, yy, { size = 12, color = c.onSurfaceVariant })
    yy = yy + 20
  end
  ui.text("Add a game by copying its folder (with gamedef.json and its images) into the server's data/games folder and rescanning, "
    .. "or by uploading a .zip above.", cx, yy, { w = colW, size = 12, color = c.onSurfaceVariant })
  yy = yy + 32
  local rowH = 40
  for _, g in ipairs(sc.games) do
    local rowW = g.removable and (colW - 48) or colW
    ui.text(g.name, cx, yy, { weight = "medium", w = rowW * 0.6, ellipsis = true, h = rowH, valign = "middle" })
    ui.text(g.cardCount .. " cards  ·  " .. #(g.sets or {}) .. " sets  ·  " .. g.id, cx + rowW * 0.6, yy,
      { size = 12, w = rowW * 0.4, align = "right", ellipsis = true, color = c.onSurfaceVariant, h = rowH, valign = "middle" })
    if g.removable then
      if ui.iconButton("delete_outline", cx + colW - 40, yy, { tooltip = "Remove Game", id = "ag:removegame:" .. g.id }) then
        self:removeGame(g)
      end
    end
    yy = yy + rowH
  end
  for _, e in ipairs(self.gameErrors or {}) do
    ui.text(e, cx, yy, { w = colW, size = 12, color = theme.fixed.red })
    yy = yy + ui.textHeight(e, colW, 12) + 4
  end
  yy = yy + 24
  ui.text("Running games", cx, yy, { size = 18 })
  yy = yy + 36
  if #sc.rooms == 0 then
    ui.text("None.", cx, yy, { color = c.onSurfaceVariant })
    yy = yy + 24
  end
  for _, room in ipairs(sc.rooms) do
    local names = {}
    for _, s in ipairs(room.seats) do names[#names + 1] = s.name end
    ui.text(room.name .. "  (" .. room.gameName .. ")", cx, yy, { weight = "medium", w = colW - 120, ellipsis = true })
    ui.text((room.state == "playing" and "In progress: " or "Waiting: ") .. table.concat(names, ", "), cx, yy + 20,
      { size = 12, w = colW - 120, ellipsis = true, color = c.onSurfaceVariant })
    if ui.button("End", cx + colW - 80, yy, 80, 40, { variant = "text", color = theme.fixed.red, id = "ag:end:" .. room.id }) then
      overlays.confirm("End Game", 'End "' .. room.name .. '" for everyone in it?', "End Game", function()
        sc:request("adminCloseRoom", json.object({ "roomId", room.id }))
      end, { danger = true })
    end
    yy = yy + 52
  end
  ui.endScroll("ag:scroll", yy + off - y + 24)
end

---------------------------------------------------------------------------
-- Files
---------------------------------------------------------------------------

function A:refreshFiles()
  local gameId = self.filesGameId
  if not gameId then return end
  self.filesEntries = nil
  AFM.list(self.sc, gameId, self.filesPath, function(r)
    if gameId ~= self.filesGameId then return end -- the game picker moved on while this was in flight
    if r.ok then
      self.filesEntries = r.entries
    else
      self.filesEntries = {}
      overlays.toast(r.message or "Couldn't list files.")
    end
  end)
end

function A:navigateFiles(path)
  self.filesPath = path
  self:refreshFiles()
end

local function remoteDirname(path)
  return path:match("^(.*)/[^/]+$") or ""
end

-- Uploads `plan` ({ {localPath=, destPath=}, ... }) one file at a time,
-- showing a small progress dialog in place of the file/folder picker.
function A:runUploadQueue(plan)
  local sc, gameId = self.sc, self.filesGameId
  local st = { total = #plan, index = 0, bytes = 0, fileTotal = 0, name = "", errors = {} }
  local dialog = overlays.dialog({
    title = "Uploading Files", width = 420, dismissible = false,
    content = function(_, x, y, w)
      ui.progressBar(x, y + 4, w, 4, st.fileTotal > 0 and st.bytes / st.fileTotal or nil)
      local status = string.format('Uploading "%s" (%d of %d)...', st.name, st.index, st.total)
      ui.text(status, x, y + 20, { w = w, ellipsis = true, size = 12, color = theme.c.onSurfaceVariant })
      return 20 + ui.textHeight(status, w, 12)
    end,
    actions = {},
  })
  local function advance()
    st.index = st.index + 1
    local item = plan[st.index]
    if not item then
      dialog:close()
      self.uploadBusy = false
      if #st.errors > 0 then
        overlays.alert("Some Uploads Failed", table.concat(st.errors, "\n"))
      else
        overlays.toast("Uploaded " .. st.total .. (st.total == 1 and " file." or " files."))
      end
      if gameId == self.filesGameId then self:refreshFiles() end
      return
    end
    st.name, st.bytes, st.fileTotal = item.destPath, 0, 0
    AFM.upload(sc, gameId, item.destPath, item.localPath, function(bytes, total)
      st.bytes, st.fileTotal = bytes, total
    end, function(err)
      if err then st.errors[#st.errors + 1] = item.destPath .. ": " .. err end
      advance()
    end)
  end
  advance()
end

-- Lists every directory `plan` will write into, checks each for files that
-- would be overwritten, and asks for one consolidated confirmation covering
-- the whole batch before any upload starts. Proceeds straight to the
-- upload queue when nothing would be overwritten.
function A:beginUpload(plan)
  if #plan == 0 then return end
  self.uploadBusy = true
  local sc, gameId = self.sc, self.filesGameId
  local dirs, seen = {}, {}
  for _, item in ipairs(plan) do
    local dir = remoteDirname(item.destPath)
    if not seen[dir] then
      seen[dir] = true
      dirs[#dirs + 1] = dir
    end
  end

  local function confirmAndRun(conflicts)
    if #conflicts == 0 then
      self:runUploadQueue(plan)
      return
    end
    local count = #conflicts
    overlays.dialog({
      title = "Overwrite Existing Files?", width = 460,
      content = function(_, x, y, w)
        local c = theme.c
        local hint = count .. " file" .. (count == 1 and "" or "s") .. " already " ..
          (count == 1 and "exists" or "exist") .. " on the server and will be overwritten:"
        ui.text(hint, x, y, { w = w, size = 12, color = c.onSurfaceVariant })
        local listTop = y + ui.textHeight(hint, w, 12) + 12
        local listH = math.min(240, count * 28)
        local off = ui.beginScroll("af:conflicts", x, listTop, w, listH)
        local ry = listTop - off
        for _, p in ipairs(conflicts) do
          ui.text(p, x, ry, { w = w, ellipsis = true, size = 12 })
          ry = ry + 28
        end
        ui.endScroll("af:conflicts", count * 28)
        return (listTop - y) + listH
      end,
      actions = {
        { label = "Cancel", variant = "text", onClick = function() self.uploadBusy = false end },
        { label = "Overwrite " .. count .. " File" .. (count == 1 and "" or "s"), variant = "filled",
          onClick = function() self:runUploadQueue(plan) end },
      },
    })
  end

  local existing, pending = {}, #dirs
  if pending == 0 then
    confirmAndRun({})
    return
  end
  for _, dir in ipairs(dirs) do
    AFM.list(sc, gameId, dir, function(r)
      if r.ok then
        for _, e in ipairs(r.entries) do
          if not e.isDir then existing[dir == "" and e.name or (dir .. "/" .. e.name)] = true end
        end
      end
      pending = pending - 1
      if pending == 0 then
        local conflicts = {}
        for _, item in ipairs(plan) do
          if existing[item.destPath] then conflicts[#conflicts + 1] = item.destPath end
        end
        confirmAndRun(conflicts)
      end
    end)
  end
end

function A:uploadFiles()
  if self.uploadBusy then return end
  local destDir = self.filesPath
  fileDialog.openFile({ title = "Choose files to upload", multiple = true }, function(localPaths)
    if not localPaths then return end
    local plan = {}
    for _, localPath in ipairs(localPaths) do
      local name = fs.basename(localPath)
      plan[#plan + 1] = { localPath = localPath, destPath = destDir == "" and name or (destDir .. "/" .. name) }
    end
    self:beginUpload(plan)
  end)
end

function A:uploadFolder()
  if self.uploadBusy then return end
  local destDir = self.filesPath
  fileDialog.pickFolder({ title = "Choose a folder to upload" }, function(folderPath)
    if not folderPath then return end
    local base = destDir == "" and fs.basename(folderPath) or (destDir .. "/" .. fs.basename(folderPath))
    local plan = {}
    for _, e in ipairs(fs.listFilesRecursive(folderPath)) do
      plan[#plan + 1] = { localPath = e.path, destPath = base .. "/" .. e.rel }
    end
    if #plan == 0 then
      overlays.toast("That folder has no files to upload.")
      return
    end
    self:beginUpload(plan)
  end)
end

function A:deleteFile(e, full)
  local label = e.isDir and "Folder" or "File"
  local warning = (not e.isDir and self.filesPath == "" and e.name == "gamedef.json")
    and "This is the game's definition file -- deleting it will break this game until replaced. " or ""
  overlays.confirm("Delete " .. label, warning .. 'Delete "' .. e.name .. '"? This can\'t be undone.', "Delete",
    function()
      AFM.delete(self.sc, self.filesGameId, full, function(r)
        if r.ok then
          self:refreshFiles()
        else
          overlays.alert("Couldn't Delete", r.message or "Something went wrong.")
        end
      end)
    end, { danger = true })
end

-- Clickable "Game Name / sub / folder" trail; returns the x past the last crumb.
function A:drawFileCrumbs(cx, cy, gameName)
  local c = theme.c
  local function crumb(label, path)
    local w = ui.textWidth(label, 14)
    local r = ui.region("af:crumb:" .. path, cx, cy, w, 24, { cursor = "hand" })
    ui.text(label, cx, cy, { color = r.hovered and c.primary or c.onSurfaceVariant })
    if r.clicked and path ~= self.filesPath then self:navigateFiles(path) end
    cx = cx + w
  end
  crumb(gameName, "")
  if self.filesPath ~= "" then
    local built = ""
    for seg in self.filesPath:gmatch("[^/]+") do
      ui.text(" / ", cx, cy, { color = c.onSurfaceVariant })
      cx = cx + ui.textWidth(" / ", 14)
      built = built == "" and seg or (built .. "/" .. seg)
      crumb(seg, built)
    end
  end
end

function A:drawFiles(x, y, w, h)
  local c = theme.c
  local sc = self.sc
  if #sc.games == 0 then
    ui.text("No games on this server.", x, y, { color = c.onSurfaceVariant })
    return
  end
  if not self.filesGameId then
    self.filesGameId, self.filesPath = sc.games[1].id, ""
    self:refreshFiles()
  end
  local colW = math.min(720, w)
  local cx = x + (w - colW) / 2
  local off = ui.beginScroll("af:scroll", x, y, w, h)
  local yy = y - off

  local gameOpts = {}
  local gameName
  for _, g in ipairs(sc.games) do
    gameOpts[#gameOpts + 1] = { value = g.id, label = g.name }
    if g.id == self.filesGameId then gameName = g.name end
  end
  local dw = math.min(320, colW)
  local prevGameId = self.filesGameId
  self.filesGameId = ui.dropdown("af:game", cx, yy, dw, gameOpts, self.filesGameId, { label = "Game", labelBackground = c.surface })
  if self.filesGameId ~= prevGameId then
    self.filesPath = ""
    self:refreshFiles()
  end
  local busy = self.uploadBusy or false
  local filesLabel, folderLabel = "Upload Files", "Upload Folder"
  local filesW = ui.buttonWidth(filesLabel, { icon = "upload_file" })
  local folderW = ui.buttonWidth(folderLabel, { icon = "upload_file" })
  local folderX = cx + colW - folderW
  local filesX = folderX - 12 - filesW
  if ui.button(filesLabel, filesX, yy, filesW, 48, { variant = "outlined", icon = "upload_file", id = "af:uploadfiles", disabled = busy }) then
    self:uploadFiles()
  end
  if ui.button(folderLabel, folderX, yy, folderW, 48, { variant = "outlined", icon = "upload_file", id = "af:uploadfolder", disabled = busy }) then
    self:uploadFolder()
  end
  yy = yy + 48 + 16

  if ui.iconButton("arrow_upward", cx, yy, { tooltip = "Up one level", id = "af:up", disabled = self.filesPath == "" }) then
    self:navigateFiles(self.filesPath:match("^(.*)/[^/]+$") or "")
  end
  if ui.iconButton("refresh", cx + 44, yy, { tooltip = "Refresh", id = "af:refresh" }) then self:refreshFiles() end
  self:drawFileCrumbs(cx + 96, yy + 10, gameName or "")
  yy = yy + 40 + 12
  ui.divider(cx, yy, colW)
  yy = yy + 8

  if not self.filesEntries then
    ui.spinner(cx + colW / 2, yy + 40, 14)
    ui.endScroll("af:scroll", yy + 80 + off - y)
    return
  end
  if #self.filesEntries == 0 then
    ui.text("Empty.", cx, yy, { color = c.onSurfaceVariant })
    yy = yy + 24
  end
  local rowH, delW = 44, 48
  local navW = colW - delW
  for i, e in ipairs(self.filesEntries) do
    local full = self.filesPath == "" and e.name or (self.filesPath .. "/" .. e.name)
    local r = ui.region("af:row:" .. i, cx, yy, navW, rowH, { cursor = "hand" })
    if r.hovered then ui.rect("fill", cx, yy, navW, rowH, 0, theme.alpha(c.onSurface, 0.05)) end
    ui.icon(e.isDir and "folder" or "insert_drive_file", cx + 8, yy + (rowH - 20) / 2, 20, c.onSurfaceVariant)
    ui.text(e.name, cx + 40, yy, { h = rowH, valign = "middle", w = navW - (e.isDir and 48 or 140), ellipsis = true })
    if not e.isDir then
      ui.text(formatBytes(e.size), cx + navW - 100, yy, { h = rowH, valign = "middle", w = 92, align = "right",
        size = 12, color = c.onSurfaceVariant })
    end
    if r.clicked and e.isDir then self:navigateFiles(full) end
    if ui.iconButton("delete_outline", cx + navW + 4, yy + (rowH - 40) / 2, { tooltip = "Delete", id = "af:del:" .. i }) then
      self:deleteFile(e, full)
    end
    yy = yy + rowH
  end
  yy = yy + 16
  local hint = "Only image/json files are downloadable by game clients; other file types will sit in the folder unused."
  ui.text(hint, cx, yy, { w = colW, size = 12, color = c.onSurfaceVariant })
  yy = yy + ui.textHeight(hint, colW, 12) + 16
  ui.endScroll("af:scroll", yy + off - y)
end

function A:draw(x, y, w, h)
  local pad = 24
  local tab, th = widgets.tabBar("admin:tabs", x, y, w, TABS, self.tab)
  self.tab = tab
  local by = y + th + pad
  local bx, bw, bh = x + pad, w - 2 * pad, y + h - by - pad
  if self.tab == 1 then
    self:drawUsers(bx, by, bw, bh)
  elseif self.tab == 2 then
    self:drawServer(bx, by, bw, bh)
  elseif self.tab == 3 then
    self:drawGames(bx, by, bw, bh)
  else
    self:drawFiles(bx, by, bw, bh)
  end
end

return A
