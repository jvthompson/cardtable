-- In-app file/folder picker, replacing the native OS dialog: the native one
-- has an unfixable Windows z-order bug when the window is maximized (a DWM
-- quirk for fullscreen-shaped borderless windows -- see src/platform/
-- file_dialog.lua), and no native implementation at all on Mac. Same `opts`
-- shape as the old dialog (title, filters, initialDir), but this one is an
-- immediate-mode overlay so it can only resolve later, when the user acts:
-- onResult(path) fires exactly once, with the chosen path or nil (cancelled).
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local fs = require("src.data.fs")
local paths = require("src.data.paths")

local M = {}

local ROW_H = 40
local LIST_H = 360
local DIALOG_W = 560

-- Starts in the game library folder when it exists (most browsing is for
-- game assets, gamedef.json files, etc.), falling back to the user's home
-- folder, then the working directory.
local function defaultDir()
  local lib = paths.gamesDir()
  if lib and fs.isDir(lib) then return lib end
  local home = fs.isWindows and os.getenv("USERPROFILE") or os.getenv("HOME")
  if home and fs.isDir(home) then return home end
  return love.filesystem.getWorkingDirectory()
end

local function extensionSet(filters)
  if not filters then return nil end
  local set = {}
  for _, f in ipairs(filters) do
    for _, ext in ipairs(f.extensions) do set["." .. ext:lower()] = true end
  end
  return set
end

-- fs.list's entries, directories first (always shown, so the user can keep
-- navigating), then files filtered by `exts` (nil = unfiltered), skipped
-- entirely in folder-pick mode.
local function listEntries(dir, exts, foldersOnly)
  local items = fs.list(dir)
  if not items then return nil end
  local dirs, files = {}, {}
  for _, e in ipairs(items) do
    if e.isDir then
      dirs[#dirs + 1] = e
    elseif not foldersOnly and (not exts or exts[fs.extension(e.name)]) then
      files[#files + 1] = e
    end
  end
  for _, f in ipairs(files) do dirs[#dirs + 1] = f end
  return dirs
end

-- opts: title, folder (bool), multiple (bool, file-pick only), filters
-- ({ {name=, extensions={...}}, ... }), initialDir. In multiple mode,
-- onResult receives an array of absolute paths (never an empty one --
-- the confirm action is disabled at zero selected) or nil if cancelled.
local function open(opts, onResult)
  local exts = extensionSet(not opts.folder and opts.filters or nil)
  local st = {
    dir = (opts.initialDir and fs.isDir(opts.initialDir)) and opts.initialDir or defaultDir(),
    pathText = nil, error = nil, entries = {}, selected = {},
  }
  local done = false
  local function finish(path)
    if done then return end
    done = true
    onResult(path)
  end

  local function navigate(dir)
    local items = listEntries(dir, exts, opts.folder)
    if not items then
      overlays.toast("Can't open that folder.", 2)
      return
    end
    st.dir, st.entries, st.error, st.pathText, st.selected = dir, items, nil, nil, {}
  end
  navigate(st.dir)

  local dialog = overlays.dialog({
    title = opts.title or (opts.folder and "Choose a Folder" or "Choose a File"),
    width = DIALOG_W,
    onDismiss = function() finish(nil) end,
    content = function(_, x, y, w)
      local c = theme.c
      local yy = y

      if ui.iconButton("arrow_upward", x, yy, { tooltip = "Up one level", id = "filepicker:up" }) then
        navigate(fs.dirname(st.dir))
      end
      if ui.iconButton("refresh", x + 44, yy, { tooltip = "Refresh", id = "filepicker:refresh" }) then
        navigate(st.dir)
      end
      local fieldOpts = { h = 40, error = st.error }
      local text, _, submitted = ui.textField("filepicker:path", x + 92, yy, w - 92, st.pathText or st.dir, fieldOpts)
      st.pathText = text
      if submitted then
        if fs.isDir(text) then
          navigate(text)
        else
          st.error = "Not a folder."
        end
      end
      yy = yy + ui.textFieldHeight(fieldOpts) + 8
      ui.divider(x, yy, w)
      yy = yy + 8

      local listTop = yy
      local off = ui.beginScroll("filepicker:list", x, listTop, w, LIST_H)
      local ry = listTop - off
      local multi = opts.multiple and not opts.folder
      for i, e in ipairs(st.entries) do
        local r = ui.region("filepicker:item" .. i, x, ry, w, ROW_H, { cursor = "hand" })
        if r.hovered then ui.rect("fill", x, ry, w, ROW_H, 0, theme.alpha(c.onSurface, 0.08)) end
        local iconX = x + 8
        if multi and not e.isDir then
          local full = fs.join(st.dir, e.name)
          local wasSelected = st.selected[full] == true
          local cb = ui.checkbox("filepicker:cb" .. i, x + 8, ry + (ROW_H - 18) / 2, wasSelected)
          if r.clicked or cb ~= wasSelected then st.selected[full] = (not wasSelected) or nil end
          iconX = x + 40
        end
        ui.icon(e.isDir and "folder" or "insert_drive_file", iconX, ry + (ROW_H - 20) / 2, 20, c.onSurfaceVariant)
        ui.text(e.name, iconX + 32, ry, { h = ROW_H, valign = "middle", w = x + w - (iconX + 32) - 16, ellipsis = true })
        if r.clicked and e.isDir then
          navigate(fs.join(st.dir, e.name))
        elseif r.clicked and not multi then
          finish(fs.join(st.dir, e.name))
        end
        ry = ry + ROW_H
      end
      ui.endScroll("filepicker:list", #st.entries * ROW_H)

      return (listTop - y) + LIST_H
    end,
    actions = opts.folder and {
      { label = "Cancel", variant = "text", onClick = function() finish(nil) end },
      { label = "Select This Folder", variant = "filled", onClick = function() finish(st.dir) end },
    } or (opts.multiple and {
      { label = "Cancel", variant = "text", onClick = function() finish(nil) end },
      { label = "Select", variant = "filled", disabled = function() return next(st.selected) == nil end, onClick = function()
        local paths = {}
        for p in pairs(st.selected) do paths[#paths + 1] = p end
        table.sort(paths)
        finish(paths)
      end },
    } or {
      { label = "Cancel", variant = "text", onClick = function() finish(nil) end },
    }),
  })
  if opts.multiple and not opts.folder then
    local base = dialog.content
    dialog.content = function(d, x, y, w)
      local count = 0
      for _ in pairs(st.selected) do count = count + 1 end
      d.actions[2].label = count > 0 and ("Select " .. count .. " File" .. (count == 1 and "" or "s")) or "Select"
      return base(d, x, y, w)
    end
  end
  return dialog
end

function M.openFile(opts, onResult)
  opts = opts or {}
  opts.folder = false
  return open(opts, onResult)
end

function M.pickFolder(opts, onResult)
  opts = opts or {}
  opts.folder = true
  return open(opts, onResult)
end

return M
