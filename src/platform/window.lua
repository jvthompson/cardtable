-- Frameless window chrome. Uses SDL's window hit-test so the custom title
-- bar drags the window (with native snapping and double-click maximize) and
-- the edges resize it while not maximized. The callback runs inside SDL's
-- event pump, which main.lua calls from JIT-disabled code (see love.run).
local ffi = require("ffi")

local W = {}

W.titleBarHeight = 56
W.resizeBorder = 6
W.framed = false -- F6 toggles the native OS frame

local sdl
local callback
local dragArea = function() return false end

pcall(ffi.cdef, [[
  typedef struct SDL_Window SDL_Window;
  typedef struct { int x, y; } SDL_Point_CF;
  typedef int (*SDL_HitTest_CF)(SDL_Window*, const SDL_Point_CF*, void*);
  SDL_Window* SDL_GL_GetCurrentWindow(void);
  int SDL_SetWindowHitTest(SDL_Window* window, SDL_HitTest_CF cb, void* data);
  void SDL_SetWindowResizable(SDL_Window* window, int resizable);
  int SDL_GetWindowDisplayIndex(SDL_Window* window);
  int SDL_GetDisplayDPI(int displayIndex, float* ddpi, float* hdpi, float* vdpi);
  void SDL_SetWindowMinimumSize(SDL_Window* window, int min_w, int min_h);
  int SDL_SetHint(const char* name, const char* value);
]])

local HT = { NORMAL = 0, DRAGGABLE = 1, TOPLEFT = 2, TOP = 3, TOPRIGHT = 4, RIGHT = 5, BOTTOMRIGHT = 6, BOTTOM = 7, BOTTOMLEFT = 8, LEFT = 9 }

-- Snapshot refreshed every frame by W.update(); the callback only reads
-- these plain Lua values.
-- `scale` is the UI scale (logical -> physical pixels), set by the app.
local cached = { w = 1280, h = 720, maximized = false, scale = 1 }

local function sdlLib()
  if sdl == nil then
    local ok, lib = pcall(ffi.load, "SDL2")
    sdl = ok and lib or false
  end
  return sdl or nil
end

local function sdlWindow()
  local lib = sdlLib()
  if not lib then return nil end
  local win = lib.SDL_GL_GetCurrentWindow()
  if win == nil then return nil end
  return win
end

-- Display scale of the monitor the window is on (1 = 96 DPI). conf.lua
-- makes the process DPI-aware on Windows so the window gets real pixels;
-- without that this reports 1 and Windows stretches the window instead.
local dpiCheckAt, dpiValue = -1, 1
function W.dpiScale()
  local now = love.timer.getTime()
  if now < dpiCheckAt then return dpiValue end
  dpiCheckAt = now + 0.5
  local win = sdlWindow()
  if win then
    local idx = sdl.SDL_GetWindowDisplayIndex(win)
    local h = ffi.new("float[1]")
    if idx >= 0 and sdl.SDL_GetDisplayDPI(idx, nil, h, nil) == 0 and h[0] > 0 then
      dpiValue = math.floor(h[0] / 96 * 100 + 0.5) / 100
    end
  end
  return dpiValue
end

-- Physical size of the desktop the window is on.
function W.desktopSize()
  local win = sdlWindow()
  local idx = win and sdl.SDL_GetWindowDisplayIndex(win) or 0
  return love.window.getDesktopDimensions(math.max(0, idx) + 1)
end

function W.setMinimumSize(w, h)
  local win = sdlWindow()
  if win then sdl.SDL_SetWindowMinimumSize(win, w, h) end
end

function W.setScale(s) cached.scale = s end

function W.update()
  cached.w, cached.h = love.graphics.getDimensions()
  cached.maximized = love.window.isMaximized()
end

local function hitTest(_, point, _)
  local x, y = point.x, point.y
  if not W.framed and not cached.maximized then
    local w, h = cached.w, cached.h
    local b = W.resizeBorder * cached.scale
    local left, right, top, bottom = x < b, x >= w - b, y < b, y >= h - b
    if top and left then return HT.TOPLEFT end
    if top and right then return HT.TOPRIGHT end
    if bottom and left then return HT.BOTTOMLEFT end
    if bottom and right then return HT.BOTTOMRIGHT end
    if top then return HT.TOP end
    if bottom then return HT.BOTTOM end
    if left then return HT.LEFT end
    if right then return HT.RIGHT end
  end
  local s = cached.scale
  if not W.framed and y < W.titleBarHeight * s and dragArea(x / s, y / s) then return HT.DRAGGABLE end
  return HT.NORMAL
end

function W.install()
  local ok = pcall(function()
    assert(sdlLib())
    -- By default SDL swallows the mouse-down that refocuses the window
    -- (clicking in from outside only activates it; the click itself is
    -- dropped), so a button click right after refocus needs a second
    -- click to register. This makes the refocusing click a real click too.
    sdl.SDL_SetHint("SDL_MOUSE_FOCUS_CLICKTHROUGH", "1")
    if not callback then callback = ffi.cast("SDL_HitTest_CF", hitTest) end
    local win = sdl.SDL_GL_GetCurrentWindow()
    if win ~= nil then
      -- LÖVE creates borderless windows non-resizable (even with
      -- t.window.resizable), which also blocks maximizing on Windows.
      sdl.SDL_SetWindowResizable(win, 1)
      sdl.SDL_SetWindowHitTest(win, callback, nil)
    end
  end)
  W.hitTestInstalled = ok
  return ok
end

-- fn(x, y) -> true where the title bar is empty (draggable) space.
function W.setDragArea(fn) dragArea = fn end

function W.toggleMaximize()
  if love.window.isMaximized() then love.window.restore() else love.window.maximize() end
end

-- F6: switch between the custom title bar and the native frame. Like the
-- Flutter app, this is not true fullscreen.
function W.toggleFrame()
  W.framed = not W.framed
  local w, h, flags = love.window.getMode()
  local wasMax = love.window.isMaximized()
  flags.borderless = not W.framed
  love.window.setMode(w, h, flags)
  -- Re-enable resizing (and the hit-test) before maximizing; a
  -- non-resizable window ignores maximize.
  W.install()
  if wasMax then love.window.maximize() end
end

return W
