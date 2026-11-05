-- App settings dialog, opened from the Home screen and the in-game menu.
-- New settings go here as sections: a heading, then rows.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local window = require("src.platform.window")
local profile = require("src.data.profile")
local handSettings = require("src.data.hand_settings")
local tableSettings = require("src.data.table_settings")
local colorpicker = require("src.ui.kit.colorpicker")

local M = {}

local function app() return require("src.app") end

local function pct(v) return math.floor(v * 100 + 0.5) .. "%" end

local function scaleOptions()
  local opts = {}
  for _, v in ipairs(app().uiScaleOptions) do
    opts[#opts + 1] = { value = v, label = v == 1 and "100% (Default)" or pct(v) }
  end
  return opts
end

local function heading(text, x, y)
  ui.text(text, x, y, { size = 14, weight = "bold", color = theme.c.primary })
  return 28
end

-- opts.inGame: opened over the game table (which always draws light).
function M.open(opts)
  opts = opts or {}
  local A = app()
  local options = scaleOptions()
  return overlays.dialog({
    title = "Settings",
    width = 440,
    content = function(_, x, y, w)
      local c = theme.c
      local yy = y

      yy = yy + heading("Display", x, yy)
      local current = A.uiScaleSetting()
      local picked = ui.dropdown("settings:uiScale", x, yy + 6, w, options, current,
        { label = "UI scale", labelBackground = c.surfaceContainerHigh })
      if picked ~= current then A.setUiScaleSetting(picked) end
      yy = yy + 6 + 48 + 8
      local dpi, eff = window.dpiScale(), A.effectiveScale()
      local note = "Windows display scaling: " .. pct(dpi) .. ". Effective scale: " .. pct(eff) .. "."
      if eff + 0.005 < dpi * A.uiScaleSetting() then
        note = note .. " Limited so the app still fits on this screen."
      end
      ui.text(note, x, yy, { w = w, size = 12, color = c.onSurfaceVariant })
      yy = yy + ui.textHeight(note, w, 12) + 24

      yy = yy + heading("Appearance", x, yy)
      local subtitle = opts.inGame and "The game table always uses the light theme." or nil
      if ui.switchRow("settings:dark", "Dark mode", x, yy, w, theme.isDark, { subtitle = subtitle }) ~= theme.isDark then
        theme.setDark(not theme.isDark)
        profile.setDarkMode(theme.isDark)
      end
      yy = yy + 32 + (subtitle and ui.textHeight(subtitle, w - 64, 12) + 4 or 0) + 24

      yy = yy + heading("Hand", x, yy)
      for _, d in ipairs(handSettings.defs) do
        local v, held = ui.sliderRow("settings:hand:" .. d.id, d.label, x, yy, w, handSettings.get(d.id), d.min, d.max,
          { step = d.step, format = d.format })
        -- Applied live while dragging; saved once the slider is released.
        handSettings.set(d.id, v, held)
        yy = yy + 64
      end
      local label = "Reset hand to defaults"
      if ui.button(label, x - 12, yy, ui.buttonWidth(label), nil,
        { variant = "text", disabled = handSettings.isDefault(), id = "settings:hand:reset" }) then
        handSettings.reset()
      end
      yy = yy + ui.BUTTON_H + 16

      yy = yy + heading("Table", x, yy)
      local game = opts.game
      local feltTextureOn = tableSettings.feltTextureEnabled()
      local feltTextureSubtitle = "Adds a subtle woven-cloth texture to the table."
      if ui.switchRow("settings:feltTexture", "Felt texture", x, yy, w, feltTextureOn,
        { subtitle = feltTextureSubtitle }) ~= feltTextureOn then
        tableSettings.setFeltTextureEnabled(not feltTextureOn)
      end
      yy = yy + 32 + ui.textHeight(feltTextureSubtitle, w - 64, 12) + 4 + 24

      ui.text("Selection color", x, yy, { size = 12, color = c.onSurfaceVariant })
      yy = yy + 20
      local picked, ph = colorpicker.field("settings:selectionColor", x, yy, w, tableSettings.selectionColor(),
        { labelBackground = c.surfaceContainerHigh })
      tableSettings.setSelectionColor(picked)
      yy = yy + ph + 4
      label = "Reset selection color"
      if ui.button(label, x - 12, yy, ui.buttonWidth(label), nil,
        { variant = "text", disabled = tableSettings.isSelectionColorDefault(), id = "settings:selectionColor:reset" }) then
        tableSettings.resetSelectionColor()
      end
      yy = yy + ui.BUTTON_H + 16

      local feltHex = game and game.tableColor
      ui.text("Table color", x, yy, { size = 12, color = c.onSurfaceVariant })
      yy = yy + 20
      local pickedFelt, fh = colorpicker.field("settings:feltColor", x, yy, w, tableSettings.feltColor(feltHex),
        { labelBackground = c.surfaceContainerHigh })
      tableSettings.setFeltColor(pickedFelt, feltHex)
      yy = yy + fh + 4
      label = "Reset table color"
      if ui.button(label, x - 12, yy, ui.buttonWidth(label), nil,
        { variant = "text", disabled = tableSettings.isFeltColorDefault(), id = "settings:feltColor:reset" }) then
        tableSettings.resetFeltColor()
      end
      yy = yy + ui.BUTTON_H + 16

      local borderHex = game and game.playmatBorderColor
      ui.text("Playmat border color", x, yy, { size = 12, color = c.onSurfaceVariant })
      yy = yy + 20
      local pickedBorder, bh = colorpicker.field("settings:playmatBorderColor", x, yy, w,
        tableSettings.playmatBorderColor(borderHex), { labelBackground = c.surfaceContainerHigh })
      tableSettings.setPlaymatBorderColor(pickedBorder, borderHex)
      yy = yy + bh + 4
      label = "Reset playmat border color"
      if ui.button(label, x - 12, yy, ui.buttonWidth(label), nil,
        { variant = "text", disabled = tableSettings.isPlaymatBorderColorDefault(), id = "settings:playmatBorderColor:reset" }) then
        tableSettings.resetPlaymatBorderColor()
      end
      yy = yy + ui.BUTTON_H
      return yy - y
    end,
    actions = { { label = "Done", variant = "filled" } },
  })
end

return M
