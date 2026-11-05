-- Port of lib/ui/home_screen.dart, since extended with an inline Join
-- panel (host/port fields right on Home, with a one-tap reconnect to the
-- last server) and a two-column layout that falls back to a Join/Host
-- segmented toggle once the window gets narrow.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local widgets = require("src.ui.kit.widgets")
local colorpicker = require("src.ui.kit.colorpicker")
local fileDialog = require("src.platform.file_dialog")
local imageCache = require("src.data.image_cache")
local profile = require("src.data.profile")
local version = require("src.version")
local updater = require("src.platform.updater")

local Home = {}
Home.__index = Home

-- Below this content width there isn't room for both columns side by side.
local WIDE_BREAKPOINT = 760

local LOGO_MAX_W = 220
local logoImages = {} -- isDark -> Image, loaded once per variant (false = load failed, don't retry)

local function getLogo()
  local isDark = theme.isDark
  if logoImages[isDark] == nil then
    local path = isDark and "assets/logo.png" or "assets/logo_light.png"
    local ok, img = pcall(love.graphics.newImage, path)
    logoImages[isDark] = ok and img or false
  end
  return logoImages[isDark] or nil
end

function Home.new(message)
  return setmetatable({
    title = "CardTable", showBack = false, message = message,
    tab = "join", joinIp = "", joinPort = tostring(require("src.net.protocol").defaultGamePort),
  }, Home)
end

local function app() return require("src.app") end

-- Edit Player Settings dialog (home_screen.dart _promptEditPlayerSettings).
function Home.openEditPlayerSettings()
  local A = app()
  local st = {
    name = A.profile.name,
    color = A.profile.color,
    avatarPath = A.profile.avatarPath, -- what the dialog shows
    avatarChanged = false,
    newSource = nil,
  }
  overlays.dialog({
    title = "Edit Player Settings",
    width = 400,
    content = function(d, x, y, w)
      local yy = y
      local size = 200
      local ax = x + (w - size) / 2
      local r = ui.region("eps:avatar", ax, yy, size, size, { cursor = "hand", tooltip = "Choose an image" })
      widgets.avatar(ax, yy, size, st.color, st.avatarPath and { path = st.avatarPath } or nil)
      if r.hovered then ui.rect("fill", ax, yy, size, size, 0, { 1, 1, 1, 0.08 }) end
      if r.clicked then
        fileDialog.openFile({ title = "Choose an avatar image", filters = fileDialog.imageFilters }, function(path)
          if path then
            st.avatarPath = path
            st.avatarChanged = true
            st.newSource = path
          end
        end)
      end
      yy = yy + size + 4
      if st.avatarPath then
        local bw = ui.buttonWidth("Remove Image", { icon = "delete_outline" })
        if ui.button("Remove Image", x + (w - bw) / 2, yy, bw, nil, { variant = "text", icon = "delete_outline" }) then
          st.avatarPath = nil
          st.avatarChanged = true
          st.newSource = nil
        end
        yy = yy + 44
      end
      yy = yy + 16
      st.name = ui.textField("eps:name", x, yy, w, st.name, { label = "Your name", autofocus = true, labelBackground = theme.c.surfaceContainerHigh })
      yy = yy + 48 + 16
      local newColor, ch = colorpicker.field("eps:color", x, yy, w, st.color,
        { label = "Player Color", labelBackground = theme.c.surfaceContainerHigh })
      st.color = newColor
      yy = yy + ch
      return yy - y
    end,
    actions = {
      { label = "Cancel", variant = "text" },
      { label = "Save", variant = "filled", onClick = function()
        local name = st.name:gsub("^%s+", ""):gsub("%s+$", "")
        A.profile.name = name
        A.profile.color = st.color
        profile.setName(name)
        profile.setColor(st.color)
        if st.avatarChanged then
          if st.newSource then
            local saved, err = profile.saveAvatar(st.newSource)
            if saved then
              imageCache.invalidate(saved)
              A.profile.avatarPath = saved
              profile.setAvatarPath(saved)
            else
              overlays.toast("Could not use that image: " .. tostring(err))
            end
          else
            profile.deleteAvatar()
            if A.profile.avatarPath then imageCache.invalidate(A.profile.avatarPath) end
            A.profile.avatarPath = nil
            profile.setAvatarPath(nil)
          end
        end
      end },
    },
  })
end

---------------------------------------------------------------------------
-- Updates (ports of update_confirm_dialog.dart / update_progress_dialog.dart)
---------------------------------------------------------------------------

function Home.confirmUpdate()
  local tag = updater.state.tag
  if not tag then return end
  overlays.confirm("Update Available", "Version " .. tag .. " is available. Would you like to update now?", "Update",
    function() Home.runUpdate() end, { cancelLabel = "Later" })
end

local PHASE_LABELS = {
  extracting = "Extracting update...",
  verifying = "Verifying update...",
  launchingInstaller = "Installing — CardTable will restart shortly...",
}

-- Download -> extract -> verify -> launch helper, then quit so the helper
-- can swap the files. Nothing touches the install folder until the helper
-- runs, so a failure leaves the current install intact.
function Home.runUpdate()
  local st = { phase = "downloading", progress = 0 }
  local d = overlays.dialog({
    title = "Updating CardTable",
    width = 420,
    dismissible = false,
    content = function(_, x, y, w)
      if st.error then
        ui.text(st.error, x, y, { w = w })
        return ui.textHeight(st.error, w)
      end
      ui.progressBar(x, y + 4, w, 4, st.progress)
      local label = PHASE_LABELS[st.phase]
        or ("Downloading update" .. (st.progress and (" (" .. math.floor(st.progress * 100 + 0.5) .. "%)") or "") .. "...")
      ui.text(label, x, y + 24, { w = w })
      return 48
    end,
    actions = {},
  })
  updater.apply(function(phase, progress)
    st.phase, st.progress = phase, progress
  end, function(err)
    if err then
      st.error = tostring(err)
      d.title = "Update Failed"
      d.dismissible = true
      d.actions = { { label = "Close", variant = "text" } }
      return
    end
    -- Let the final frame render, then exit so the helper can proceed.
    st.quitAt = love.timer.getTime() + 0.3
  end)
  Home.pendingUpdateQuit = st
end

function Home:update()
  local st = Home.pendingUpdateQuit
  if st and st.quitAt and love.timer.getTime() >= st.quitAt then
    Home.pendingUpdateQuit = nil
    love.event.quit()
  end
end

---------------------------------------------------------------------------
-- Join (inline on Home): host/port fields, a recent-servers dropdown and
-- a one-tap reconnect to the last server. Shared by the wide Join card
-- and the narrow Join tab -- only the surrounding chrome differs.
---------------------------------------------------------------------------

function Home:connect(host, port)
  local P = require("src.net.protocol")
  app().push(require("src.ui.screens.multiplayer").Join.new({ host = host, port = tonumber(port) or P.defaultGamePort, autoConnect = true }))
end

-- Arrow at the right end of the address field opening the recently joined
-- servers; picking one fills in both fields.
function Home:drawRecentServersPopup(recent, x, y, w)
  local c = theme.c
  if ui.iconButton("arrow_drop_down", x + w - 40, y + 4, { id = "home:join:recent", tooltip = "Recent servers" }) then
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
      local r = ui.region("home:join:recent:" .. i, px, yy, pw - 40, itemH, { cursor = "hand" })
      if r.hovered then ui.rect("fill", px, yy, pw, itemH, 0, theme.alpha(c.onSurface, 0.08)) end
      ui.text(e.host .. " : " .. e.port, px + 12, yy, { w = pw - 56, h = itemH, valign = "middle", ellipsis = true, color = c.onSurface })
      if ui.iconButton("close", px + pw - 40, yy + 4, { size = 32, id = "home:join:recent:rm:" .. i, tooltip = "Remove" }) then
        profile.removeRecentServer(e.host, e.port)
        if #recent == 1 then self.recentOpen = false end
      elseif r.clicked then
        self.joinIp, self.joinPort = e.host, tostring(e.port)
        self.recentOpen = false
      end
      yy = yy + itemH
    end
    if (ui.mousePressed(1) and not ui.hover(px, py, pw, ph)) or ui.mousePressed(2) then
      self.recentOpen = false
    end
  end)
end

-- Fixed height Home:drawJoinFields uses, so callers can lay out around it
-- without re-deriving the same sum: a 76px reconnect banner + its "or join
-- another" divider when there's a recent server, then the ip/port fields
-- and the Connect button.
local RECONNECT_BANNER_H = 76

function Home.joinFieldsHeight(hasRecent)
  return (hasRecent and (RECONNECT_BANNER_H + 16 + 16 + 16) or 0) + 60 + 72 + 48
end

function Home:drawJoinFields(cx, yy, w, recent)
  local c = theme.c
  if #recent > 0 then
    local last = recent[1]
    local bh = RECONNECT_BANNER_H
    local r = ui.region("home:reconnect", cx, yy, w, bh, { cursor = "hand" })
    ui.rect("fill", cx, yy, w, bh, 14, c.primaryContainer)
    if r.hovered then ui.rect("fill", cx, yy, w, bh, 14, theme.alpha(c.onPrimaryContainer, 0.08)) end
    ui.icon("history", cx + 14, yy + 8, 20, c.onPrimaryContainer)
    ui.text("LAST PLAYED", cx + 46, yy + 10, { size = 10.5, weight = "bold", color = theme.alpha(c.onPrimaryContainer, 0.7) })
    ui.text(last.host .. " : " .. last.port, cx, yy + 26, { size = 14.5, weight = "medium", w = w, align = "center",
      ellipsis = true, color = c.onPrimaryContainer })
    ui.text("CLICK TO RECONNECT", cx, yy + 52, { size = 10.5, weight = "bold", w = w, align = "center",
      color = theme.alpha(c.onPrimaryContainer, 0.7) })
    if r.clicked then
      self:connect(last.host, last.port)
    end
    yy = yy + bh + 16
    ui.text("OR JOIN ANOTHER SERVER", cx, yy, { size = 10.5, weight = "bold", w = w, align = "center", color = c.onSurfaceVariant })
    yy = yy + 16 + 16
  end
  local submitted
  self.joinIp, _, submitted = ui.textField("home:join:ip", cx, yy, w, self.joinIp, { label = "Host or server IP address",
    hint = "e.g. 192.168.1.42 -- blank = 127.0.0.1", trailingW = #recent > 0 and 36 or nil })
  if #recent > 0 then self:drawRecentServersPopup(recent, cx, yy, w) end
  yy = yy + 60
  local s2
  self.joinPort, _, s2 = ui.textField("home:join:port", cx, yy, w, self.joinPort, { label = "Port",
    filter = function(t) return t:match("^%d+$") ~= nil end })
  yy = yy + 72
  if ui.button("Connect", cx, yy, w, 48, { id = "home:connect" }) or submitted or s2 then
    self:connect(self.joinIp, self.joinPort)
  end
end

---------------------------------------------------------------------------
-- Two-column (wide) layout: profile + Host Game on the left, the Join
-- card on the right.
---------------------------------------------------------------------------

-- The left column's own content sets the content block's height: it's
-- taller than the join card in both the with/without-recent-server cases.
local LEFT_COL_H = 16 + 160 + 12 + 30 + 24 + 48 + 16 + 40 + 40

function Home:drawWide(x, yy, w, leftW, gap, rightW, recent)
  local A = app()
  local c = theme.c
  local totalW = leftW + gap + rightW
  local lx = math.floor(x + (w - totalW) / 2)
  local rx = lx + leftW + gap

  -- Left: profile, Host Game, secondary actions.
  local ly = yy + 16
  local avSize = 160
  local ax = lx + (leftW - avSize) / 2
  local r = ui.region("home:profile", lx, ly, leftW, avSize + 12 + 30, { cursor = "hand" })
  if r.hovered then ui.rect("fill", lx, ly, leftW, avSize + 12 + 30, 12, theme.alpha(c.onSurface, 0.05)) end
  widgets.avatar(ax, ly, avSize, A.profile.color, A.profile.avatarPath and { path = A.profile.avatarPath } or nil)
  ui.text(A.playerName(), lx, ly + avSize + 12, { size = 18, w = leftW, align = "center", ellipsis = true })
  if r.clicked then Home.openEditPlayerSettings() end
  ly = ly + avSize + 12 + 30 + 24

  if ui.button("Host Game", lx, ly, leftW, 48, { variant = "outlined" }) then
    A.push(require("src.ui.screens.player_count").host())
  end
  ly = ly + 48 + 16
  if ui.button("Practice Offline", lx, ly, leftW, 40, { variant = "text" }) then
    A.push(require("src.ui.screens.player_count").practice())
  end
  ly = ly + 40
  if ui.button("Deck Editor", lx, ly, leftW, 40, { variant = "text" }) then
    A.push(require("src.ui.screens.deck_editor").GameSelect.new())
  end

  -- Right: the Join a Game card -- the hero action.
  local cardPad = 24
  local cardH = cardPad * 2 + 28 + 16 + Home.joinFieldsHeight(#recent > 0)
  widgets.card(rx, yy, rightW, cardH, { radius = 20, border = true })
  local jy = yy + cardPad
  ui.icon("sports_esports", rx + cardPad, jy, 22, c.primary)
  ui.text("Join a Game", rx + cardPad + 30, jy, { size = 18, color = c.onSurface })
  jy = jy + 28 + 16
  self:drawJoinFields(rx + cardPad, jy, rightW - cardPad * 2, recent)
end

---------------------------------------------------------------------------
-- Single-column (narrow) layout: a Join/Host segmented toggle in place of
-- the two columns.
---------------------------------------------------------------------------

function Home:drawNarrow(x, yy, w, colW, recent)
  local A = app()
  local c = theme.c
  local cx = math.floor(x + (w - colW) / 2)

  local avSize = 64
  local ax = cx + (colW - avSize) / 2
  local r = ui.region("home:profile", cx, yy, colW, avSize + 10 + 20, { cursor = "hand" })
  if r.hovered then ui.rect("fill", cx, yy, colW, avSize + 10 + 20, 12, theme.alpha(c.onSurface, 0.05)) end
  widgets.avatar(ax, yy, avSize, A.profile.color, A.profile.avatarPath and { path = A.profile.avatarPath } or nil)
  ui.text(A.playerName(), cx, yy + avSize + 10, { size = 16, w = colW, align = "center", ellipsis = true })
  if r.clicked then Home.openEditPlayerSettings() end
  yy = yy + avSize + 10 + 20 + 20

  self.tab = ui.segmented("home:tab", cx, yy, colW, {
    { value = "join", label = "Join" }, { value = "host", label = "Host" },
  }, self.tab)
  yy = yy + 40 + 16

  if self.tab == "host" then
    ui.icon("sports_esports", cx + colW / 2 - 15, yy, 30, c.primary)
    yy = yy + 30 + 12
    if ui.button("Host Game", cx, yy, colW, 48) then
      A.push(require("src.ui.screens.player_count").host())
    end
    yy = yy + 48 + 12
    local helper = "Starts a game and shows your address so others can connect."
    ui.text(helper, cx, yy, { w = colW, size = 12.5, align = "center", color = c.onSurfaceVariant })
  else
    self:drawJoinFields(cx, yy, colW, recent)
  end
  yy = yy + Home.joinFieldsHeight(#recent > 0) + 24 -- same block height either tab, so the rows below don't jump

  if ui.button("Practice Offline", cx, yy, colW, 40, { variant = "text" }) then
    A.push(require("src.ui.screens.player_count").practice())
  end
  yy = yy + 40
  if ui.button("Deck Editor", cx, yy, colW, 40, { variant = "text" }) then
    A.push(require("src.ui.screens.deck_editor").GameSelect.new())
  end
end

---------------------------------------------------------------------------
-- Corner utility icons: Settings and the Game Definition Editor, demoted
-- from full-width rows since most players never need either.
---------------------------------------------------------------------------

function Home:drawCornerTools(x, y, w, h)
  local A = app()
  local by = y + h - 16 - 40
  local bx = x + w - 16 - 40
  if ui.iconButton("settings", bx, by, { tooltip = "Settings", id = "home:settings" }) then
    require("src.ui.screens.settings_dialog").open()
  end
  bx = bx - 44
  if ui.iconButton("build", bx, by, { tooltip = "Game Definition Editor", id = "home:gamedef" }) then
    A.push(require("src.ui.screens.gamedef_editor").Entry.new())
  end
  bx = bx - 44
  if ui.iconButton("local_cafe", bx, by, { tooltip = "Support the Author", id = "home:support" }) then
    require("src.ui.screens.support_dialog").open()
  end
end

function Home:draw(x, y, w, h)
  local c = theme.c
  local wide = w >= WIDE_BREAKPOINT
  local leftW, gap, rightW = 260, 56, 400
  local narrowColW = math.min(340, w - 48)
  local bannerW = wide and (leftW + gap + rightW) or narrowColW

  local recent = profile.getRecentServers()

  -- Logo, centered above everything else.
  local logo = getLogo()
  local logoW, logoH, logoAspect = 0, 0, 0
  if logo then
    local lw, lh = logo:getDimensions()
    logoAspect = lh / lw
    logoW = math.min(LOGO_MAX_W, bannerW)
    logoH = logoW * logoAspect
  end
  local logoBlockH = logo and (logoH + 24) or 0

  -- Measure the column first so it can be vertically centered.
  local bannerH = 0
  local upd = updater.state
  local updateText = upd.available and ("Update available: " .. upd.tag .. " — click to install") or nil
  if updateText then bannerH = bannerH + ui.textHeight(updateText, bannerW - 24, 14) + 24 + 24 end
  if self.message then bannerH = bannerH + ui.textHeight(self.message, bannerW - 24, 14) + 24 + 24 end

  local contentH
  if wide then
    contentH = LEFT_COL_H
  else
    contentH = (64 + 10 + 20) + 20 + 40 + 16 + Home.joinFieldsHeight(#recent > 0) + 24 + 40 + 40
  end
  local total = logoBlockH + bannerH + contentH
  local bx0 = math.floor(x + (w - bannerW) / 2)
  local yy = math.floor(y + math.max(16, (h - total) / 2))

  if logo then
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(logo, x + (w - logoW) / 2, yy, 0, logoW / logo:getWidth(), logoW / logo:getWidth())
    yy = yy + logoH + 24
  end

  if updateText then
    yy = yy + widgets.banner(updateText, bx0, yy, bannerW, "info", function() Home.confirmUpdate() end) + 24
  end
  if self.message then
    yy = yy + widgets.banner(self.message, bx0, yy, bannerW, "warning") + 24
  end

  if wide then
    self:drawWide(x, yy, w, leftW, gap, rightW, recent)
  else
    self:drawNarrow(x, yy, w, narrowColW, recent)
  end

  self:drawCornerTools(x, y, w, h)
  ui.text("Build " .. version.build, x + 8, y + h - 8 - 16, { size = 12, color = c.disabled })
end

return Home
