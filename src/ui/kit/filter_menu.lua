-- Ports of multi_select_filter_menu.dart and the CardSortMenu widget in
-- card_sort_menu.dart. Each is an outlined trigger button whose popup stays
-- open while toggling (filters) or closes on pick (sort).
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")

local M = {}

local MAX_PER_COLUMN = 15   -- max option rows per column before wrapping to a new column
local MAX_COLUMNS = 3       -- max columns visible at once; beyond this we paginate
local ROW_H = 36
local PAGE_ROW_H = 36       -- height of the pager row (icon buttons sized 32 to match row rhythm)

local function triggerButton(id, x, y, label, open)
  local w = ui.textWidth(label, 14, "medium") + 24 + 24
  local h = 40
  local r = ui.region(id, x, y, w, h, { cursor = "hand" })
  local c = theme.c
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, h / 2, c.outline)
  if r.hovered or open then ui.rect("fill", x, y, w, h, h / 2, theme.alpha(c.primary, 0.08)) end
  ui.text(label, x + 16, y, { weight = "medium", h = h, valign = "middle", color = c.primary })
  ui.icon("arrow_drop_down", x + w - 30, y + 8, 24, c.primary)
  return w, r.clicked
end

function M.triggerWidth(label) return ui.textWidth(label, 14, "medium") + 48 end

-- Shared chrome for both popups below: anchors a pw x ph panel under the
-- trigger at (x, y, triggerW, 40), clamped on-screen, themed to the trigger
-- button's palette (overlays draw after the theme that opened them may have
-- changed), and closed on an outside click. `draw(px, py, c)` renders the
-- popup's own contents onto that panel.
local function openPopup(st, x, y, triggerW, pw, ph, draw)
  local pal = theme.c
  local px, py = x, y + 44
  ui.overlay(function()
    local saved = theme.c
    theme.c = pal
    local c = theme.c
    local sw, sh = ui.screenSize()
    if px + pw > sw - 8 then px = math.max(8, sw - 8 - pw) end
    if py + ph > sh - 8 then py = math.max(8, sh - 8 - ph) end
    ui.cover(-1e9, -1e9, 2e9, 2e9)
    ui.shadow(px, py, pw, ph, 4, 2)
    ui.rect("fill", px, py, pw, ph, 4, c.surfaceContainer)
    draw(px, py, c)
    if (ui.mousePressed(1) or ui.mousePressed(2)) and not ui.hoverIgnoringLayer(px, py, pw, ph)
      and not ui.hoverIgnoringLayer(x, y, triggerW, 40) then
      st.open = false
    end
    theme.c = saved
  end)
end

-- options = { {id=, name=}, ... }; selected / excluded are sets {id=true}
-- and are mutated in place. excluded nil = no exclude column.
-- Returns the button width.
function M.multiSelect(id, x, y, label, options, selected, excluded)
  local st = ui.state(id)
  local count = 0
  for _, o in ipairs(options) do
    if selected[o.id] then count = count + 1 end
  end
  local w, clicked = triggerButton(id, x, y, label .. " (" .. count .. ")", st.open)
  if clicked then st.open = not st.open end
  if not st.open then return w end

  local perPage = MAX_PER_COLUMN * MAX_COLUMNS
  local totalPages = math.max(1, math.ceil(#options / perPage))
  st.page = math.min(math.max(st.page or 1, 1), totalPages)
  local paged = totalPages > 1

  local colW = 0
  for _, o in ipairs(options) do colW = math.max(colW, ui.textWidth(o.name, 14)) end
  colW = colW + 48 + (excluded and 40 or 0) + 16

  local columns, rows
  if paged then
    columns, rows = MAX_COLUMNS, MAX_PER_COLUMN
  else
    columns = math.max(1, math.ceil(#options / MAX_PER_COLUMN))
    rows = math.min(#options, MAX_PER_COLUMN)
  end

  local pw = math.max(220, columns * colW + (columns - 1) * 16 + 16)
  local ph = 8 + ROW_H + 9 + (paged and (PAGE_ROW_H + 4) or 0) + rows * ROW_H + 8
  openPopup(st, x, y, w, pw, ph, function(px, py, c)
    local allSelected = #options > 0 and count == #options
    local yy = py + 8
    local r = ui.region(id .. ":all", px, yy, pw, ROW_H, { cursor = "hand" })
    if r.hovered then ui.rect("fill", px, yy, pw, ROW_H, 0, theme.alpha(c.onSurface, 0.08)) end
    local allCb = ui.checkbox(id .. ":allcb", px + 16, yy + 9, allSelected)
    ui.text(allSelected and "Deselect All" or "Select All", px + 48, yy, { h = ROW_H, valign = "middle", color = c.onSurface })
    if r.clicked or allCb ~= allSelected then
      for _, o in ipairs(options) do selected[o.id] = (not allSelected) or nil end
    end
    yy = yy + ROW_H + 4
    ui.divider(px, yy, pw, c.outlineVariant)
    yy = yy + 5
    if paged then
      local pageLabel = "Page " .. st.page .. " / " .. totalPages
      local labelW = math.max(56, ui.textWidth(pageLabel, 12) + 12)
      local rowW = 32 + labelW + 32
      local rx = px + (pw - rowW) / 2
      if ui.iconButton("chevron_left", rx, yy, {
        id = id .. ":prevpage", size = 32, iconSize = 18, tooltip = "Previous Page", disabled = st.page <= 1,
      }) then
        st.page = st.page - 1
      end
      ui.text(pageLabel, rx + 32, yy, {
        w = labelW, h = 32, size = 12, align = "center", valign = "middle", color = c.onSurfaceVariant,
      })
      if ui.iconButton("chevron_right", rx + 32 + labelW, yy, {
        id = id .. ":nextpage", size = 32, iconSize = 18, tooltip = "Next Page", disabled = st.page >= totalPages,
      }) then
        st.page = st.page + 1
      end
      yy = yy + PAGE_ROW_H + 4
    end
    local startIdx = (st.page - 1) * perPage + 1
    local endIdx = math.min(#options, st.page * perPage)
    for i = startIdx, endIdx do
      local o = options[i]
      local pageIdx = i - startIdx
      local col = math.floor(pageIdx / MAX_PER_COLUMN)
      local row = pageIdx % MAX_PER_COLUMN
      local ox, oy = px + 8 + col * (colW + 16), yy + row * ROW_H
      local rowW = colW - (excluded and 40 or 0)
      local rr = ui.region(id .. ":o" .. i, ox, oy, rowW, ROW_H, { cursor = "hand" })
      if rr.hovered then ui.rect("fill", ox, oy, rowW, ROW_H, 0, theme.alpha(c.onSurface, 0.08)) end
      local wasSelected = selected[o.id] == true
      local cb = ui.checkbox(id .. ":cb" .. i, ox + 8, oy + 9, wasSelected)
      ui.text(o.name, ox + 40, oy, { h = ROW_H, valign = "middle", color = c.onSurface })
      if rr.clicked or cb ~= wasSelected then
        if selected[o.id] then
          selected[o.id] = nil
        else
          selected[o.id] = true
          if excluded then excluded[o.id] = nil end
        end
      end
      if excluded then
        local isEx = excluded[o.id] == true
        if ui.iconButton(isEx and "close" or "check_box_outline_blank", ox + colW - 40, oy - 2, {
          size = 40, iconSize = 18, id = id .. ":ex" .. i,
          color = isEx and theme.fixed.red or theme.alpha(c.onSurface, 0.38),
          tooltip = isEx and "Stop excluding" or "Exclude cards with this tag",
        }) then
          if isEx then
            excluded[o.id] = nil
          else
            excluded[o.id] = true
            selected[o.id] = nil
          end
        end
      end
    end
  end)
  return w
end

-- options = { {id=, name=}, ... }; returns the selected id (nil = default).
function M.sortMenu(id, x, y, options, selectedId)
  local st = ui.state(id)
  if st.hasPick then
    selectedId = st.pick
    st.hasPick, st.pick = false, nil
  end
  local label = "Sort"
  for _, o in ipairs(options) do
    if o.id == selectedId then label = "Sort: " .. o.name end
  end
  local w, clicked = triggerButton(id, x, y, label, st.open)
  if clicked then st.open = not st.open end
  if st.open then
    local all = { { id = nil, name = "Default order" } }
    for _, o in ipairs(options) do all[#all + 1] = o end
    local pw = 200
    for _, o in ipairs(all) do pw = math.max(pw, ui.textWidth(o.name, 14) + 64) end
    local ph = 16 + #all * ROW_H + 9
    openPopup(st, x, y, w, pw, ph, function(px, py, c)
      local yy = py + 8
      for i, o in ipairs(all) do
        local r = ui.region(id .. ":s" .. i, px, yy, pw, ROW_H, { cursor = "hand" })
        if r.hovered then ui.rect("fill", px, yy, pw, ROW_H, 0, theme.alpha(c.onSurface, 0.08)) end
        if o.id == selectedId then ui.icon("check", px + 12, yy + 9, 18, c.onSurface) end
        ui.text(o.name, px + 40, yy, { h = ROW_H, valign = "middle", color = c.onSurface })
        if r.clicked then
          st.pick, st.hasPick = o.id, true
          st.open = false
        end
        yy = yy + ROW_H
        if i == 1 then
          ui.divider(px, yy + 4, pw, c.outlineVariant)
          yy = yy + 9
        end
      end
    end)
  end
  return selectedId, w
end

function M.close(id) ui.state(id).open = false end

return M
