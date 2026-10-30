-- Port of lib/data/game_loader.dart.
local json = require("lib.json")
local fs = require("src.data.fs")
local models = require("src.core.models")
local util = require("src.core.util")
local resolver = require("src.data.image_resolver")

local L = {}

L.standardDeckAssetPath = "assets/games/standard_52/standard_52.json"
L.standardDeckId = "standard_52"

-- Appends the 52 generated cards when any zone asks for a standard deck.
local function withStandardDeckCards(game)
  if not util.any(game.zones, function(z) return z.standardDeck end) then return game end
  local existing = {}
  for _, c in ipairs(game.cards) do existing[c.id] = true end
  local cards = util.shallowCopy(game.cards)
  for _, c in ipairs(models.buildStandardDeckCards()) do
    if not existing[c.id] then cards[#cards + 1] = c end
  end
  local out = util.copyWith(game, { cards = cards })
  models.GameDefinition.invalidateIndex(out)
  return out
end
L.withStandardDeckCards = withStandardDeckCards

local function resolveGameImagePaths(game, folderPath)
  local cards = util.map(game.cards, function(c)
    if c.imagePath == nil then return c end
    return util.copyWith(c, { imagePath = resolver.resolveBareImagePath(folderPath, c.imagePath, c.setId) })
  end)
  -- Card backs are game-wide, never per-set.
  local cardBacks = util.map(game.cardBacks, function(b)
    if b.imagePath == nil then return b end
    return util.copyWith(b, { imagePath = resolver.resolveBareImagePath(folderPath, b.imagePath) })
  end)
  return models.GameDefinition.new({
    id = game.id, name = game.name, cards = cards, sets = game.sets, cardBacks = cardBacks,
    zones = game.zones, tagGroups = game.tagGroups, folderPath = folderPath,
    tableColor = game.tableColor, playmatBorderColor = game.playmatBorderColor,
    hasScenarios = game.hasScenarios, scenarios = game.scenarios,
    scenarioCardBackId = game.scenarioCardBackId,
    sameOrientationForAll = game.sameOrientationForAll,
  })
end

function L.loadStandardDeck()
  local raw = assert(love.filesystem.read(L.standardDeckAssetPath))
  return withStandardDeckCards(models.GameDefinition.fromJson(json.decode(raw)))
end

-- Loads every gamedef.json (case-insensitive name) directly inside
-- folderPath. Invalid files are skipped; the second return lists
-- {path, error} for each one so the UI can report it if it wants to.
function L.loadFromFolder(folderPath)
  local items = fs.list(folderPath)
  if not items then return {}, {} end
  local games, errors = {}, {}
  for _, e in ipairs(items) do
    if not e.isDir and e.name:lower() == "gamedef.json" then
      local path = fs.join(folderPath, e.name)
      local ok, result = pcall(function()
        local raw = assert(fs.readFile(path))
        return withStandardDeckCards(resolveGameImagePaths(models.GameDefinition.fromJson(json.decode(raw)), folderPath))
      end)
      if ok then
        games[#games + 1] = result
      else
        errors[#errors + 1] = { path = path, error = tostring(result) }
      end
    end
  end
  return games, errors
end

-- Loads the games in every direct subfolder of rootPath.
function L.loadGamesFromDirectory(rootPath)
  local items = fs.list(rootPath)
  if not items then return {}, {} end
  local games, errors = {}, {}
  for _, e in ipairs(items) do
    if e.isDir then
      local g, errs = L.loadFromFolder(fs.join(rootPath, e.name))
      for _, x in ipairs(g) do games[#games + 1] = x end
      for _, x in ipairs(errs) do errors[#errors + 1] = x end
    end
  end
  return games, errors
end

-- The game library as the pickers show it: the folder's games, with the
-- bundled Standard 52-Card Deck always last.
function L.loadLibrary(rootPath)
  local games, errors = L.loadGamesFromDirectory(rootPath)
  games[#games + 1] = L.loadStandardDeck()
  return games, errors
end

return L
