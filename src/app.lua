-- Application shell: owns the screen stack, the custom title bar
-- (lib/ui/widgets/app_title_bar.dart), overlays and input routing.
--
-- Screens are objects with optional fields/methods:
--   title, showBack (default true), onBack()
--   draw(x, y, w, h)      -- inside the UI frame, content area below the bar
--   update(dt), keypressed(key, scancode, isrepeat), keyreleased(key)
--   enter(), leave(), resume(), filedropped(file), quit()
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local window = require("src.platform.window")
local imageCache = require("src.data.image_cache")
local profile = require("src.data.profile")
local settings = require("src.data.settings")
local discord = require("src.platform.discord")

local App = {}

local stack = {}
local titleButtons = {} -- last frame's title-bar button rects (for the drag area)

function App.top() return stack[#stack] end

function App.push(screen)
  stack[#stack + 1] = screen
  ui.blur()
  if screen.enter then screen:enter() end
end

function App.pop()
  local s = table.remove(stack)
  if s and s.leave then s:leave() end
  ui.blur()
  local top = App.top()
  if top and top.resume then top:resume() end
end

function App.replace(screen)
  local s = table.remove(stack)
  if s and s.leave then s:leave() end
  App.push(screen)
end

-- Clears everything above Home; `message` shows Home's orange banner.
function App.popToHome(message)
  while #stack > 1 do
    local s = table.remove(stack)
    if s.leave then s:leave() end
  end
  overlays.closeMenus()
  local home = App.top()
  if home then
    home.message = message
    if home.resume then home:resume() end
  end
end

---------------------------------------------------------------------------
-- Player profile shared by screens
---------------------------------------------------------------------------

App.profile = { name = "Player", color = 0xFF455A64, avatarPath = nil }

function App.loadProfile()
  local name = profile.getName()
  if name and name ~= "" then App.profile.name = name end
  App.profile.color = profile.getColor() or App.profile.color
  App.profile.avatarPath = profile.getAvatarPath()
end

function App.playerName()
  local n = (App.profile.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return n == "" and "Player" or n
end

---------------------------------------------------------------------------
-- Discord invites (port of discord_join_prompt_dialog.dart)
---------------------------------------------------------------------------

-- A friend accepted our game invite (or clicked Join on a host's presence)
-- -- possibly cold-launching the app. The secret is "host:port".
function App.showDiscordJoinPrompt(secret)
  local host, port = discord.parseJoinSecret(secret)
  if not host then return end
  overlays.confirm("Discord Game Invite", "Join the CardTable game at " .. host .. ":" .. port .. "?", "Join", function()
    App.push(require("src.ui.screens.multiplayer").Join.new({ host = host, port = port, autoConnect = true }))
  end, { cancelLabel = "Dismiss" })
end

---------------------------------------------------------------------------
-- UI scale
---------------------------------------------------------------------------

-- The user's UI scale setting multiplies the display's DPI scale.
App.uiScaleOptions = { 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2 }

function App.uiScaleSetting()
  local v = tonumber(settings.get(settings.keys.uiScale, 1)) or 1
  return math.max(0.5, math.min(3, v))
end

function App.setUiScaleSetting(v)
  if v == 1 then settings.remove(settings.keys.uiScale) else settings.set(settings.keys.uiScale, v) end
end

-- Logical minimum window size (the layouts are designed for at least this).
local MIN_W, MIN_H = 960, 600
local appliedScale

-- Effective scale: DPI x setting, capped so a maximized window still has a
-- usable logical size on this monitor.
function App.effectiveScale()
  local s = window.dpiScale() * App.uiScaleSetting()
  local dw, dh = window.desktopSize()
  if dw and dw > 0 then s = math.min(s, dw / MIN_W, dh / (MIN_H + 40)) end
  return math.max(0.5, s)
end

local function applyScale(force)
  local s = App.effectiveScale()
  if s == appliedScale and not force then return end
  appliedScale = s
  theme.setScale(s)
  window.setScale(s)
  local dw, dh = window.desktopSize()
  window.setMinimumSize(math.min(math.ceil(MIN_W * s), dw or 1e9), math.min(math.ceil(MIN_H * s), dh or 1e9))
end
App.applyScale = applyScale

---------------------------------------------------------------------------
-- Title bar
---------------------------------------------------------------------------

local TITLE_H = window.titleBarHeight

local function drawTitleBar(w)
  local fg = theme.fixed.titleBarForeground
  ui.rect("fill", 0, 0, w, TITLE_H, 0, theme.fixed.titleBar)
  local screen = App.top()
  local x = 16
  titleButtons = {}
  if screen and screen.showBack ~= false and #stack > 1 then
    titleButtons[#titleButtons + 1] = { x = 4, w = 48 }
    if ui.iconButton("arrow_back", 8, 8, { tooltip = "Back", color = fg, id = "title:back" }) then
      if screen.onBack then screen:onBack() else App.pop() end
    end
    x = 56
  end
  ui.text(screen and screen.title or "CardTable", x, 0, { size = 14, weight = "medium", h = TITLE_H, valign = "middle", color = theme.fixed.white })
  local titleEnd = x + ui.textWidth(screen and screen.title or "CardTable", 14, "medium") + 8
  local bx = w - 8 - 40
  if ui.iconButton("close", bx, 8, { tooltip = "Close CardTable", color = fg, id = "title:close" }) then love.event.quit() end
  bx = bx - 48
  local maxed = love.window.isMaximized()
  if ui.iconButton(maxed and "filter_none" or "crop_square", bx, 8, { tooltip = maxed and "Restore" or "Maximize", color = fg, id = "title:max" }) then
    window.toggleMaximize()
  end
  bx = bx - 48
  if ui.iconButton(theme.isDark and "light_mode" or "dark_mode", bx, 8, {
    tooltip = theme.isDark and "Switch to light mode" or "Switch to dark mode", color = fg, id = "title:theme" }) then
    theme.setDark(not theme.isDark)
    profile.setDarkMode(theme.isDark)
  end
  titleButtons.titleEnd = titleEnd
  titleButtons.buttonsStart = bx - 4
end

window.setDragArea(function(x)
  return x >= (titleButtons.titleEnd or 0) and x < (titleButtons.buttonsStart or 0)
end)

---------------------------------------------------------------------------
-- LÖVE callbacks
---------------------------------------------------------------------------

-- Developer hooks (used to check screens without clicking through them):
--   --eval "<lua>"     run code once after startup (App is in scope)
--   --shot <file.png>  save a screenshot to the save directory after
--                      --frames N (default 30) frames, then quit
local dev = {}

function App.load(args)
  love.keyboard.setKeyRepeat(true)
  -- Window/taskbar icon (the exe's own icon is set by tools/build.ps1).
  pcall(function() love.window.setIcon(love.image.newImageData("assets/icon.png")) end)
  theme.setDark(profile.getDarkMode())
  App.loadProfile()
  window.install()
  applyScale(true)
  love.window.maximize()
  App.push(require("src.ui.screens.home").new())
  args = args or {}
  local noDiscord = false
  for _, a in ipairs(args) do
    if a == "--no-discord" then noDiscord = true end
  end
  local forceUpdateCheck = false
  for _, a in ipairs(args) do
    if a == "--update-check" then forceUpdateCheck = true end
  end
  require("src.platform.updater").check(forceUpdateCheck)
  if not noDiscord then
    discord.onJoinSecret = App.showDiscordJoinPrompt
    discord.init()
  end
  for i, a in ipairs(args) do
    if a == "--eval" then dev.eval = args[i + 1] end
    if a == "--shot" then dev.shot = args[i + 1] end
    if a == "--frames" then dev.frames = tonumber(args[i + 1]) end
    if a == "--script" then dev.script = args[i + 1] end
    if a == "--dark" then theme.setDark(true) end
    if a == "--light" then theme.setDark(false) end
  end
  dev.frame = 0
end

-- --script <file.lua>: the file returns function(api) run as a coroutine,
-- one resume per frame. api: wait(frames), move(x, y), press(x, y, b),
-- release(x, y, b), click(x, y, b), drag(x1, y1, x2, y2, steps), key(k),
-- keyDown(k)/keyUp(k) (faked for love.keyboard.isDown), shot(name),
-- app (App), quit().
local fakeDown = {}
local realIsDown = love.keyboard.isDown
local function installFakeKeys()
  love.keyboard.isDown = function(...)
    for _, k in ipairs({ ... }) do
      if fakeDown[k] then return true end
    end
    return realIsDown(...)
  end
end

local function makeScriptApi()
  local api = { app = App }
  local mx, my = 0, 0
  function api.wait(n) for _ = 1, (n or 1) do coroutine.yield() end end
  -- Script coordinates are logical; the App.mouse* hooks take physical ones.
  local function S() return theme.scale end
  function api.move(x, y) mx, my = x, y; App.mousemoved(x * S(), y * S(), 0, 0); api.wait(1) end
  function api.press(x, y, b) api.move(x, y); App.mousepressed(x * S(), y * S(), b or 1, 1); api.wait(1) end
  function api.release(x, y, b) mx, my = x or mx, y or my; App.mousereleased(mx * S(), my * S(), b or 1); api.wait(1) end
  function api.click(x, y, b) api.press(x, y, b); api.release(x, y, b); api.wait(1) end
  function api.doubleClick(x, y)
    api.move(x, y)
    local px, py = x * S(), y * S()
    App.mousepressed(px, py, 1, 1); App.mousereleased(px, py, 1); api.wait(1)
    App.mousepressed(px, py, 1, 2); App.mousereleased(px, py, 1); api.wait(2)
  end
  function api.drag(x1, y1, x2, y2, steps)
    steps = steps or 10
    api.press(x1, y1)
    for i = 1, steps do api.move(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps) end
    api.release(x2, y2)
    api.wait(2)
  end
  function api.key(k) App.keypressed(k, k, false); App.keyreleased(k, k); api.wait(1) end
  function api.keyDown(k) fakeDown[k] = true; App.keypressed(k, k, false); api.wait(1) end
  function api.keyUp(k) fakeDown[k] = nil; App.keyreleased(k, k); api.wait(1) end
  function api.text(t) App.textinput(t); api.wait(1) end
  function api.shot(name) love.graphics.captureScreenshot(name); api.wait(2) end
  function api.quit() love.event.quit() coroutine.yield() end
  function api.log(...) print(...) end
  return api
end

local function devTick()
  dev.frame = dev.frame + 1
  if dev.script and dev.frame == 3 then
    installFakeKeys()
    local chunk = assert(love.filesystem.load(dev.script) or loadfile(dev.script))
    local fn = chunk()
    local api = makeScriptApi()
    dev.co = coroutine.create(function() fn(api) end)
  end
  if dev.co and coroutine.status(dev.co) ~= "dead" then
    local ok, err = coroutine.resume(dev.co)
    if not ok then
      print("script error: " .. tostring(err))
      love.event.quit(1)
    end
  end
  if dev.eval and dev.frame == 3 then
    local fn = assert(load(dev.eval, "=eval", "t", setmetatable({ App = App }, { __index = _G })))
    fn()
  end
  if dev.shot and dev.frame == (dev.frames or 30) then
    love.graphics.captureScreenshot(dev.shot)
  end
  if dev.shot and dev.frame == (dev.frames or 30) + 2 then love.event.quit() end
end

function App.update(dt)
  devTick()
  window.update()
  applyScale()
  imageCache.update()
  -- Network objects (host server, client) keep running across screens.
  require("src.net.protocol").updateAll(dt)
  require("src.net.netinfo").update()
  require("src.net.upnp").update()
  discord.update(dt)
  require("src.platform.updater").update()
  for _, s in ipairs(stack) do
    if s.backgroundUpdate then s:backgroundUpdate(dt) end
  end
  local s = App.top()
  if s and s.update then s:update(dt) end
end

function App.draw()
  local scale = theme.scale
  local pw, ph = love.graphics.getDimensions()
  local w, h = pw / scale, ph / scale
  love.graphics.scale(scale)
  local s = App.top()
  -- Like Flutter's Theme(data: AppTheme.light) around the game table: the
  -- screen and its dialogs draw light regardless of the app's dark mode.

  if s and s.forceLightTheme then theme.c = theme.light end
  ui.beginFrame(w, h)
  ui.rect("fill", 0, 0, w, h, 0, theme.c.surface)
  local top = window.framed and 0 or TITLE_H
  overlays.contentTop = top
  if s and s.draw then
    ui.pushClip(0, top, w, h - top)
    s:draw(0, top, w, h - top)
    ui.popClip()
  end
  if not window.framed then drawTitleBar(w) end
  overlays.draw()
  ui.endFrame()
  -- (Re-derive rather than restore: the title bar may have toggled dark mode.)
  theme.c = theme.isDark and theme.dark or theme.light
end

function App.keypressed(key, scancode, isrepeat)
  if key == "f6" and not isrepeat then
    window.toggleFrame()
    applyScale(true) -- setMode reset the minimum size
    return
  end
  -- Escape closes menus/dialogs even while a field inside them has focus.
  if key == "escape" and overlays.anyOpen() then
    overlays.keypressed(key)
    return
  end
  if ui.onKeyPressed(key, scancode, isrepeat) then return end
  if overlays.anyOpen() then
    overlays.keypressed(key)
    return
  end
  local s = App.top()
  if s and s.keypressed then s:keypressed(key, scancode, isrepeat) end
end

function App.keyreleased(key, scancode)
  local s = App.top()
  if s and s.keyreleased then s:keyreleased(key, scancode) end
end

function App.textinput(t)
  if ui.onTextInput(t) then return end
  local s = App.top()
  if s and s.textinput then s:textinput(t) end
end

-- Mouse positions arrive in physical pixels; the UI works in logical units.
function App.mousepressed(x, y, button, presses)
  local s = theme.scale
  ui.onMousePressed(x / s, y / s, button, presses)
end
function App.mousereleased(x, y, button)
  local s = theme.scale
  ui.onMouseReleased(x / s, y / s, button)
end
function App.mousemoved(x, y)
  local s = theme.scale
  ui.onMouseMoved(x / s, y / s)
end
function App.wheelmoved(x, y) ui.onWheel(x, y) end
function App.resize() end

function App.filedropped(file)
  local s = App.top()
  if s and s.filedropped then s:filedropped(file) end
end

function App.directorydropped(path)
  local s = App.top()
  if s and s.directorydropped then s:directorydropped(path) end
end

function App.focus() end

function App.quit()
  for i = #stack, 1, -1 do
    local s = stack[i]
    if s.quit and s:quit() then return true end
  end
  require("src.net.protocol").stopAll()
  imageCache.shutdown()
  discord.dispose()
  return false
end

return App
