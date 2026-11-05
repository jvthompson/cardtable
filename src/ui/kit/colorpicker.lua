-- Port of color_picker_field.dart: a hex field and a preview button that
-- opens a full saturation/value + hue picker dialog.
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local color = require("src.core.color")

local P = {}

-- Full picker dialog; onPicked(argb) is called on "Select".
function P.openPickerDialog(initial, onPicked)
  local r, g, b = color.toRgba(initial)
  local h, s, v = color.rgbToHsv(r, g, b)
  local st = { h = h, s = s, v = v }
  overlays.dialog({
    title = "Pick a Color",
    width = 360,
    content = function(d, x, y, w)
      local boxH = 200
      -- Saturation/value square: hue base color with white->color and black overlay.
      local steps = 24
      for i = 0, steps - 1 do
        local s0 = i / steps
        for j = 0, steps - 1 do
          local v0 = 1 - j / steps
          local cr, cg, cb = color.hsvToRgb(st.h, s0 + 0.5 / steps, v0 - 0.5 / steps)
          love.graphics.setColor(cr, cg, cb)
          love.graphics.rectangle("fill", x + i * w / steps, y + j * boxH / steps, w / steps + 1, boxH / steps + 1)
        end
      end
      local sq = ui.region("cp:sv", x, y, w, boxH, { cursor = "crosshair" })
      if sq.held then
        local mx, my = ui.mouse()
        st.s = math.max(0, math.min(1, (mx - x) / w))
        st.v = 1 - math.max(0, math.min(1, (my - y) / boxH))
      end
      love.graphics.setColor(1, 1, 1)
      love.graphics.setLineWidth(2)
      love.graphics.circle("line", x + st.s * w, y + (1 - st.v) * boxH, 7)
      love.graphics.setLineWidth(1)

      -- Hue bar.
      local hy = y + boxH + 16
      local barH = 16
      for i = 0, 59 do
        local cr, cg, cb = color.hsvToRgb(i / 60, 1, 1)
        love.graphics.setColor(cr, cg, cb)
        love.graphics.rectangle("fill", x + i * w / 60, hy, w / 60 + 1, barH)
      end
      local hbar = ui.region("cp:hue", x, hy - 4, w, barH + 8, { cursor = "hand" })
      if hbar.held then
        local mx = ui.mouse()
        st.h = math.max(0, math.min(0.999, (mx - x) / w))
      end
      love.graphics.setColor(1, 1, 1)
      love.graphics.setLineWidth(2)
      love.graphics.rectangle("line", x + st.h * w - 3, hy - 3, 6, barH + 6, 2, 2)
      love.graphics.setLineWidth(1)

      -- Preview.
      local py = hy + barH + 16
      local cr, cg, cb = color.hsvToRgb(st.h, st.s, st.v)
      love.graphics.setColor(cr, cg, cb)
      love.graphics.rectangle("fill", x, py, 48, 32, 4, 4)
      ui.text("#" .. color.hexFromColor(color.fromRgba(cr, cg, cb, 1)), x + 60, py, { h = 32, valign = "middle" })
      return py + 32 - y
    end,
    actions = {
      { label = "Cancel", variant = "text" },
      { label = "Select", variant = "filled", onClick = function()
        local cr, cg, cb = color.hsvToRgb(st.h, st.s, st.v)
        onPicked(color.fromRgba(cr, cg, cb, 1))
      end },
    },
  })
end

-- Hex field + preview button. Returns (newArgb, heightUsed).
-- opts.label: what the field represents, shown as its floating label
-- instead of the generic "Hex" default (e.g. "Tabletop Color").
function P.field(id, x, y, w, selected, opts)
  opts = opts or {}
  local st = ui.state(id)
  if st.picked then
    selected = st.picked
    st.picked = nil
  end
  -- Keep the hex text in sync when the color changes from elsewhere.
  if st.lastColor ~= selected then
    st.hex = color.hexFromColor(selected)
    st.lastColor = selected
  end
  local hexText, changed = ui.textField(id .. ":hex", x, y, w - 48, st.hex, {
    label = opts.label or "Hex", prefix = "#", maxLength = 7, labelBackground = opts.labelBackground,
  })
  st.hex = hexText
  if changed then
    selected = color.colorFromHex(hexText, selected)
    st.lastColor = selected
  end
  local bx, by = x + w - 40, y + 4
  local r = ui.region(id .. ":full", bx, by, 40, 40, { cursor = "hand", tooltip = "More colors" })
  local col = { color.toRgba(selected) }
  ui.rect("fill", bx, by, 40, 40, 4, col)
  ui.rect("line", bx + 0.5, by + 0.5, 39, 39, 4, theme.c.outline)
  ui.iconCentered("colorize", bx, by, 40, 40, 18, theme.isLight(col) and theme.fixed.black or theme.fixed.white)
  if r.clicked then
    P.openPickerDialog(selected, function(argb) st.picked = argb end)
  end
  return selected, 48
end

return P
