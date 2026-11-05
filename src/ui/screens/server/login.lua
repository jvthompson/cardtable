-- Sign in to / create an account on a CardTable server. If the player chose
-- "Remember me", the saved sign-in (token) is tried first so they go
-- straight to the lobby; otherwise they enter their email and password.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local widgets = require("src.ui.kit.widgets")
local colorpicker = require("src.ui.kit.colorpicker")
local json = require("lib.json")
local fs = require("src.data.fs")
local profile = require("src.data.profile")
local fileDialog = require("src.platform.file_dialog")
local SC = require("src.net.server_client")
local util = require("src.core.util")

local L = {}
L.__index = L

local function app() return require("src.app") end

local trim = util.trim

function L.new(sc)
  local A = app()
  local saved = SC.savedSession(sc.key)
  if saved and not saved.remember then
    -- Saved before Remember me existed: don't sign in without asking.
    SC.clearSession(sc.key)
    saved = nil
  end
  local self = setmetatable({
    title = sc.info.name or "CardTable Server", sc = sc,
    mode = "signIn", email = saved and saved.email or "", password = "", confirm = "",
    remember = saved ~= nil,
    name = A.playerName(), color = A.profile.color, avatarPath = A.profile.avatarPath,
  }, L)
  sc:on("disconnected", function() app().popToHome(sc:disconnectMessage()) end)
  if saved and saved.token then
    self.busy = "Signing in..."
    sc:request("resume", json.object({ "token", saved.token }), function(r)
      self.busy = nil
      if r.ok then
        self:signedIn(r, saved.email, true)
      else
        SC.forgetSession(sc.key)
        if r.error ~= "disconnected" then self.error = r.message end
      end
    end)
  end
  return self
end

function L:onBack()
  self.sc:disconnect()
  app().pop()
end

function L:signedIn(r, email, remember)
  local sc = self.sc
  sc.token = r.token
  sc.self = r.user
  if remember then
    SC.saveSession(sc.key, r.token, email or r.user.email)
  else
    SC.clearSession(sc.key)
  end
  app().replace(require("src.ui.screens.server.lobby").new(sc))
end

function L:submitSignIn()
  local email = trim(self.email)
  if email == "" or self.password == "" then
    self.error = "Enter your email address and password."
    return
  end
  self.error, self.busy = nil, "Signing in..."
  self.sc:request("login", json.object({ "email", email, "passwordHash", SC.passwordHash(email, self.password) }), function(r)
    self.busy = nil
    if r.ok then self:signedIn(r, email, self.remember) else self.error = r.message end
  end)
end

function L:submitCreate()
  local email = trim(self.email)
  if not email:find("^[^@%s]+@[^@%s]+$") then
    self.error = "Enter a valid email address."
    return
  end
  local pwErr = SC.passwordError(self.password)
  if pwErr then
    self.error = pwErr
    return
  end
  if self.password ~= self.confirm then
    self.error = "The passwords don't match."
    return
  end
  local name = trim(self.name)
  if name == "" then
    self.error = "Enter a player name."
    return
  end
  local payload = json.object({ "email", email, "passwordHash", SC.passwordHash(email, self.password), "name", name, "color", self.color })
  if self.avatarPath then
    local bytes = fs.readFile(self.avatarPath)
    local png = bytes and profile.resizeAvatarBytes(bytes)
    if not png then
      self.error = "Could not use that image."
      return
    end
    payload.avatar = love.data.encode("string", "base64", png)
  end
  self.error, self.busy = nil, "Creating your account..."
  self.sc:request("register", payload, function(r)
    self.busy = nil
    if r.ok then self:signedIn(r, email, self.remember) else self.error = r.message end
  end)
end

function L:draw(x, y, w, h)
  local c = theme.c
  local sc = self.sc
  local colW = math.min(400, w - 48)
  local cx = math.floor(x + (w - colW) / 2)
  local off = ui.beginScroll("login:scroll", x, y, w, h)
  local yy = y + 32 - off
  ui.text(sc.info.name or "CardTable Server", cx, yy, { size = 24, w = colW, align = "center" })
  yy = yy + 36
  if sc.info.motd and sc.info.motd ~= "" then
    ui.text(sc.info.motd, cx, yy, { w = colW, align = "center", color = c.onSurfaceVariant })
    yy = yy + ui.textHeight(sc.info.motd, colW) + 8
  end
  ui.text(sc.key, cx, yy, { size = 12, w = colW, align = "center", color = c.onSurfaceVariant })
  yy = yy + 32

  local canCreate = sc.info.registrationOpen ~= false
  if canCreate then
    local mode = ui.segmented("login:mode", cx, yy, colW, {
      { value = "signIn", label = "Sign In" }, { value = "create", label = "Create Account" },
    }, self.mode, { disabled = self.busy ~= nil })
    if mode ~= self.mode then
      self.mode, self.error = mode, nil
    end
    yy = yy + 40 + 24
  else
    self.mode = "signIn"
  end

  local bg = c.surface
  local submitted, s2, s3
  self.email, _, submitted = ui.textField("login:email", cx, yy, colW, self.email,
    { label = "Email address", autofocus = self.email == "", labelBackground = bg, disabled = self.busy ~= nil })
  yy = yy + 48 + 16
  self.password, _, s2 = ui.textField("login:password", cx, yy, colW, self.password,
    { label = "Password", password = true, autofocus = self.email ~= "", labelBackground = bg, disabled = self.busy ~= nil })
  yy = yy + 48 + 16

  local function rememberBox()
    self.remember = ui.checkbox("login:remember", cx, yy, self.remember,
      { label = "Remember me", disabled = self.busy ~= nil, tooltip = "Sign in automatically next time" })
    yy = yy + 18 + 24
  end

  if self.mode == "signIn" then
    rememberBox()
    if self.error then
      ui.text(self.error, cx, yy, { w = colW, color = theme.fixed.red })
      yy = yy + ui.textHeight(self.error, colW) + 12
    end
    if ui.button(self.busy or "Sign In", cx, yy, colW, 48, { disabled = self.busy ~= nil, id = "login:go" })
      or ((submitted or s2) and not self.busy) then
      self:submitSignIn()
    end
    yy = yy + 48 + 16
    ui.text("Forgot your password? Ask a server admin to reset it.", cx, yy, { w = colW, align = "center", size = 12, color = c.onSurfaceVariant })
    yy = yy + 32
  else
    self.confirm, _, s3 = ui.textField("login:confirm", cx, yy, colW, self.confirm,
      { label = "Confirm password", password = true, labelBackground = bg, disabled = self.busy ~= nil })
    yy = yy + 48 + 28
    ui.text("Your player profile on this server", cx, yy, { weight = "medium" })
    yy = yy + 28
    local size = 96
    local r = ui.region("login:avatar", cx, yy, size, size, { cursor = "hand", tooltip = "Choose an image" })
    widgets.avatar(cx, yy, size, self.color, self.avatarPath and { path = self.avatarPath } or nil)
    if r.hovered then ui.rect("fill", cx, yy, size, size, 0, { 1, 1, 1, 0.08 }) end
    local function pick()
      fileDialog.openFile({ title = "Choose an avatar image", filters = fileDialog.imageFilters }, function(path)
        if path then self.avatarPath = path end
      end)
    end
    if r.clicked then pick() end
    local bx = cx + size + 16
    self.name = ui.textField("login:name", bx, yy, colW - size - 16, self.name,
      { label = "Player name", labelBackground = bg, maxLength = 24, disabled = self.busy ~= nil })
    if ui.button("Choose Image...", bx - 12, yy + 56, nil, 40, { variant = "text", icon = "image", id = "login:pick" }) then pick() end
    if self.avatarPath and ui.iconButton("delete_outline", cx + colW - 40, yy + 56, { tooltip = "Remove Image", id = "login:rmimg" }) then
      self.avatarPath = nil
    end
    yy = yy + size + 20
    local newColor, ch = colorpicker.field("login:color", cx, yy, colW, self.color, { label = "Player Color", labelBackground = bg })
    self.color = newColor
    yy = yy + ch + 16
    rememberBox()
    if self.error then
      ui.text(self.error, cx, yy, { w = colW, color = theme.fixed.red })
      yy = yy + ui.textHeight(self.error, colW) + 12
    end
    if ui.button(self.busy or "Create Account", cx, yy, colW, 48, { disabled = self.busy ~= nil, id = "login:create" })
      or (s3 and not self.busy) then
      self:submitCreate()
    end
    yy = yy + 48 + 16
    local note = "Player names are unique on this server. Your password is never sent as plain text, but this connection "
      .. "isn't encrypted -- use a password you don't use anywhere else."
    ui.text(note, cx, yy, { w = colW, size = 12, color = c.onSurfaceVariant })
    yy = yy + ui.textHeight(note, colW, 12) + 24
  end
  ui.endScroll("login:scroll", yy + off - y)
end

return L
