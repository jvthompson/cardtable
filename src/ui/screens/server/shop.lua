-- Collection mode: the Card Shop, where players spend tokens on packs for
-- a game's sets and on starter decks. Packs use the same algorithm as the
-- Pack Generator widget (run on the server).
local ui = require("src.ui.kit.ui")
local theme = require("src.ui.kit.theme")
local overlays = require("src.ui.kit.overlays")
local widgets = require("src.ui.kit.widgets")
local json = require("lib.json")
local models = require("src.core.models")
local util = require("src.core.util")
local sound = require("src.game.sound")
local CR = require("src.ui.table.card_render")
local resolver = require("src.data.image_resolver")
local deckLibrary = require("src.data.deck_library")
local common = require("src.ui.screens.server.common")
local GamePicker = require("src.ui.screens.game_picker")

local TABS = { "Packs", "Decks" }
local CW, CH = CR.cardWidth, CR.cardHeight
-- Pack-summary cards match the Deck Editor's card pool: a third larger,
-- with up to three lines of name.
local POOL_SCALE = 4 / 3
local PW, PH = CW * POOL_SCALE, CH * POOL_SCALE
local NAME_LINES = 3

local S = {}
S.__index = S

function S.new(sc, info)
  local self = setmetatable({ title = "Card Shop", sc = sc, tab = 1 }, S)
  if info then self:open(info) end
  return self
end

function S:onBack() require("src.app").pop() end

function S:open(info)
  local sc = self.sc
  common.withGame(sc, info.id, function(game)
    sc:request("collectionGet", json.object({ "gameId", game.id }), function(r)
      if not r.ok then
        overlays.alert("Couldn't Load Card Shop", r.message or "Something went wrong.")
        return
      end
      self.game, self.info, self.owned = game, info, r.cards or {}
      self.title = "Card Shop -- " .. game.name
    end)
  end)
end

function S:buyPack(set)
  local sc = self.sc
  self.buying = set.id
  sc:request("packBuy", json.object({ "gameId", self.game.id, "setId", set.id }), function(r)
    self.buying = nil
    if not r.ok then
      sound.play("error")
      overlays.alert("Couldn't Open Pack", r.message or "Something went wrong.")
      return
    end
    local before = util.shallowCopy(self.owned)
    for _, id in ipairs(r.cards) do self.owned[id] = (self.owned[id] or 0) + 1 end
    if sc.self then sc.self.tokens = r.tokens end
    self:showPack(set, r.cards, before)
  end)
end

function S:buyStarter(starter)
  local sc = self.sc
  self.buying = "starter:" .. starter.name
  sc:request("starterBuy", json.object({ "gameId", self.game.id, "name", starter.name }), function(r)
    self.buying = nil
    if not r.ok then
      sound.play("error")
      overlays.alert("Couldn't Buy Starter Deck", r.message or "Something went wrong.")
      return
    end
    local before = util.shallowCopy(self.owned)
    local ids = {}
    for id, n in pairs(r.cards or {}) do
      self.owned[id] = (self.owned[id] or 0) + n
      for _ = 1, n do ids[#ids + 1] = id end
    end
    table.sort(ids)
    if sc.self then sc.self.tokens = r.tokens end
    self:showPack({ name = starter.name }, ids, before, starter.name .. " Starter Deck")
    overlays.toast('Added "' .. (r.savedName or starter.name) .. '" to your decks.')
  end)
end

local function newBadge(x, y)
  ui.rect("fill", x, y, 36, 18, 9, theme.fixed.green)
  ui.text("NEW", x, y, { size = 10, weight = "bold", w = 36, h = 18, align = "center", valign = "middle", color = theme.fixed.white })
end

-- An opened pack: the cards are revealed one at a time (Next Card / Skip),
-- then shown together, with cards new to the collection marked.
function S:showPack(set, ids, before, title)
  local game = self.game
  local cards = {}
  for _, id in ipairs(ids) do
    local def = models.GameDefinition.cardById(game, id)
    if def then cards[#cards + 1] = { def = def, new = (before[id] or 0) == 0 } end
  end
  title = title or (set.name .. " Pack")
  sound.play("shuffle")
  if #cards == 0 then return end
  self:revealPack(cards, title)
end

-- One card at a time, drawn large inside the dialog.
local REVEAL_W = 480
function S:revealPack(cards, title)
  local game = self.game
  local index = 1
  local nextAction = { label = "Next Card", variant = "filled" }
  local function showAll() self:showPackSummary(cards, title) end
  local function advance(d)
    if index >= #cards then
      d:close()
      showAll()
      return true
    end
    index = index + 1
    sound.play("draw")
    if index == #cards then nextAction.label = "Show All" end
    return true
  end
  nextAction.onClick = advance
  if #cards == 1 then nextAction.label = "Show All" end
  overlays.dialog({
    title = title,
    width = REVEAL_W,
    dismissible = false,
    onEnter = advance,
    content = function(_, x, y, w)
      local card = cards[index]
      local def = card.def
      ui.text("Card " .. index .. " of " .. #cards, x, y, { w = w, align = "center", size = 13, color = theme.c.onSurfaceVariant })
      -- Fit the card (portrait or turned) in a box under the counter.
      local _, sh = ui.screenSize()
      local boxW, boxH = w, math.max(240, math.min(460, sh - 380))
      local turned = def.orientation and def.orientation ~= "portrait"
      local bw, bh = turned and CH or CW, turned and CW or CH
      local s = math.min(boxW / bw, boxH / bh)
      local cy = y + 28 + bh * s / 2
      CR.draw({ def = def, faceUp = true, cx = x + w / 2, cy = cy, scale = s,
        angle = CR.orientationTurns(def.orientation) * 2 * math.pi, cardBacks = game.cardBacks })
      if card.new then newBadge(x + (w - bw * s) / 2 + 8, y + 28 + 8) end
      local ty = y + 28 + bh * s + 12
      ui.text(def.cardTitle, x, ty, { w = w, align = "center", weight = "bold", maxLines = 2 })
      return ty - y + ui.textHeight(def.cardTitle, w) + 4
    end,
    actions = {
      { label = "Skip", variant = "text", onClick = function(d) d:close(); showAll(); return true end },
      nextAction,
    },
  })
end

-- Every card from the pack, laid out like the Deck Editor's card pool, with
-- the Space preview for the hovered card.
function S:showPackSummary(cards, title)
  local game = self.game
  local gap = 12
  local nameH = NAME_LINES * theme.font(11):getHeight()
  local tileW, rowH = PW + 24, PH + 6 + nameH + 4
  local perRow = math.min(#cards, 6)
  local width = math.max(420, perRow * (tileW + gap) - gap + 48)
  overlays.dialog({
    title = title,
    width = width,
    content = function(_, x, y, w)
      local hovered
      local rows = math.ceil(#cards / perRow)
      for i, card in ipairs(cards) do
        local col, row = (i - 1) % perRow, math.floor((i - 1) / perRow)
        local rowCount = math.min(perRow, #cards - row * perRow)
        local rowW = rowCount * (tileW + gap) - gap
        local tx = x + (w - rowW) / 2 + col * (tileW + gap)
        local cx, ty = tx + tileW / 2, y + 8 + row * (rowH + gap)
        local r = ui.region("pk:" .. i, cx - PW / 2, ty, PW, PH + 6 + nameH)
        CR.draw({ def = card.def, faceUp = true, cx = cx, cy = ty + PH / 2, scale = POOL_SCALE,
          angle = CR.orientationTurns(card.def.orientation) * 2 * math.pi, cardBacks = game.cardBacks })
        if card.new then newBadge(cx - PW / 2 + 4, ty + 4) end
        ui.text(card.def.cardTitle, tx, ty + PH + 6, { size = 11, w = tileW, align = "center", maxLines = NAME_LINES })
        if r.hovered then hovered = card.def end
      end
      if hovered and love.keyboard.isDown("space") then
        ui.overlay(function()
          local sw, sh = ui.screenSize()
          CR.drawPreview(CR.definitionFaces(hovered, game.cardBacks), game.cardBacks, sw, sh, (ui.mouse()))
        end)
      end
      return 8 + rows * (rowH + gap) - gap
    end,
    actions = { { label = "Done", variant = "filled" } },
  })
end

local LOW_TOKEN_HINT = "You need more tokens. Admins can grant tokens, and some servers give out a regular allowance."

-- Packs tab: sets as large image tiles, the same treatment the
-- game-selection grid uses.
function S:drawPacks(x, y, w, h)
  local c = theme.c
  local sc = self.sc
  local game = self.game
  local tokens = sc.self and sc.self.tokens or 0
  local cost = sc.info.packCost or 1
  local function plural(n) return n .. (n == 1 and " token" or " tokens") end
  ui.text("Open Packs", x, y, { size = 18 })
  ui.text(plural(tokens) .. "  ·  " .. plural(cost) .. " per pack", x, y + 26, { size = 13, color = c.onSurfaceVariant })
  local yy = y + 56
  local sets = self.info.sets or {}
  -- Falls back to the game's default card back when no matching art file
  -- is found.
  local defaultBack = game.cardBacks[1] and game.cardBacks[1].imagePath

  if #sets == 0 then
    ui.text("This game has no sets, so it has no packs.", x, yy, { color = c.onSurfaceVariant })
    return
  end

  local tiles = {}
  for _, set in ipairs(sets) do
    tiles[#tiles + 1] = {
      id = "pack:" .. set.id,
      name = set.name,
      caption = set.cardCount .. " cards  ·  " .. plural(cost),
      imagePath = resolver.resolveImageAnyExt(game.folderPath, set.id) or defaultBack,
      folderPath = game.folderPath,
      disabled = self.buying ~= nil or tokens < cost,
      set = set,
    }
  end
  local gridH = math.min(GamePicker.gridHeight(w, #tiles), math.max(1, y + h - yy))
  GamePicker.drawGrid("shop:packs", tiles, x, yy, w, gridH, 24, function(t) self:buyPack(t.set) end)
  yy = yy + gridH + 24

  if tokens < cost then
    ui.text(LOW_TOKEN_HINT, x, yy, { w = w, size = 12, color = c.onSurfaceVariant })
  end
end

-- Decks tab: starter decks as large image tiles, same treatment as Packs.
function S:drawDecks(x, y, w, h)
  local c = theme.c
  local sc = self.sc
  local game = self.game
  local tokens = sc.self and sc.self.tokens or 0
  local starters = self.info.starterDecks or {}
  local starterCost = sc.info.starterDeckCost or 3
  local function plural(n) return n .. (n == 1 and " token" or " tokens") end
  ui.text("Starter Decks", x, y, { size = 18 })
  ui.text(plural(tokens) .. "  ·  " .. plural(starterCost) .. " per starter deck", x, y + 26,
    { size = 13, color = c.onSurfaceVariant })
  local yy = y + 56
  local defaultBack = game.cardBacks[1] and game.cardBacks[1].imagePath

  if #starters == 0 then
    ui.text("This game has no starter decks.", x, yy, { color = c.onSurfaceVariant })
    return
  end

  local decksFolder = deckLibrary.builtInDecksDir(game.folderPath)
  local tiles = {}
  for _, starter in ipairs(starters) do
    tiles[#tiles + 1] = {
      id = "starter:" .. starter.name,
      name = starter.name,
      caption = starter.cardCount .. " cards  ·  " .. plural(starterCost),
      imagePath = resolver.resolveImageAnyExt(decksFolder, starter.name) or defaultBack,
      folderPath = game.folderPath,
      disabled = self.buying ~= nil or tokens < starterCost,
      starter = starter,
    }
  end
  local gridH = math.min(GamePicker.gridHeight(w, #tiles), math.max(1, y + h - yy))
  GamePicker.drawGrid("shop:starters", tiles, x, yy, w, gridH, 24, function(t) self:buyStarter(t.starter) end)
  yy = yy + gridH + 24

  if tokens < starterCost then
    ui.text(LOW_TOKEN_HINT, x, yy, { w = w, size = 12, color = c.onSurfaceVariant })
  end
end

function S:draw(x, y, w, h)
  if not self.game then
    ui.spinner(x + w / 2, y + h / 2, 18)
    return
  end
  local pad = 24
  local tab, th = widgets.tabBar("shop:tabs", x, y, w, TABS, self.tab)
  self.tab = tab
  local by = y + th + pad
  local bx, bw, bh = x + pad, w - 2 * pad, y + h - by - pad
  if self.tab == 1 then self:drawPacks(bx, by, bw, bh)
  else self:drawDecks(bx, by, bw, bh) end
end

return S
