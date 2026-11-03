-- Port of lib/data/deck_library_loader.dart. A deck's display name is its
-- file name without ".json"; built-in decks ship inside <game>/decks/, or
-- <game>/_decks/ if that exists too (see D.builtInDecksDir).
local json = require("lib.json")
local fs = require("src.data.fs")
local models = require("src.core.models")

local D = {}

local function scanDirectory(dir, game, isBuiltIn)
  local items = fs.list(dir)
  local entries, incompatible = {}, {}
  if not items then return { entries = entries, incompatible = incompatible } end
  for _, e in ipairs(items) do
    if not e.isDir and e.name:lower():sub(-5) == ".json" then
      local path = fs.join(dir, e.name)
      local displayName = e.name:sub(1, -6)
      local raw = json.tryDecode(fs.readFile(path) or "")
      if type(raw) == "table" then
        local ok, deck = pcall(models.DeckConfig.fromJson, raw)
        if ok then
          if deck.gameId == game.id then
            entries[#entries + 1] = { displayName = displayName, filePath = path, deck = deck, isBuiltIn = isBuiltIn }
          end
        elseif type(deck) == "table" and deck.legacyDeckFormat and raw.gameId == game.id then
          incompatible[#incompatible + 1] = { displayName = displayName, filePath = path, isBuiltIn = isBuiltIn }
        end
      end
    end
  end
  local byName = function(a, b) return a.displayName < b.displayName end
  table.sort(entries, byName)
  table.sort(incompatible, byName)
  return { entries = entries, incompatible = incompatible }
end

function D.gameDeckDir(rootPath, game) return fs.join(rootPath, game.id) end

function D.loadDecksForGame(rootPath, game)
  return scanDirectory(D.gameDeckDir(rootPath, game), game, false)
end

-- A game's built-in decks folder: "_decks" when present, else "decks".
function D.builtInDecksDir(folderPath)
  local preferred = fs.join(folderPath, "_decks")
  if fs.isDir(preferred) then return preferred end
  return fs.join(folderPath, "decks")
end

function D.loadBuiltInDecksForGame(game)
  if game.folderPath == nil then return { entries = {}, incompatible = {} } end
  return scanDirectory(D.builtInDecksDir(game.folderPath), game, true)
end

-- The player's own decks first, then the game's built-in ones.
function D.loadAllDecksForGame(rootPath, game)
  local owned = D.loadDecksForGame(rootPath, game)
  local builtIn = D.loadBuiltInDecksForGame(game)
  local entries, incompatible = {}, {}
  for _, l in ipairs({ owned.entries, builtIn.entries }) do
    for _, x in ipairs(l) do entries[#entries + 1] = x end
  end
  for _, l in ipairs({ owned.incompatible, builtIn.incompatible }) do
    for _, x in ipairs(l) do incompatible[#incompatible + 1] = x end
  end
  return { entries = entries, incompatible = incompatible }
end

function D.cardCount(entry) return models.DeckConfig.totalCardCount(entry.deck) end

-- Reads a single deck file (e.g. "Browse for file..."). Returns deck or
-- nil, reason where reason is "legacy", "invalid" or "unreadable".
function D.readDeckFile(path)
  local data = fs.readFile(path)
  if not data then return nil, "unreadable" end
  local raw = json.tryDecode(data)
  if type(raw) ~= "table" then return nil, "invalid" end
  local ok, deck = pcall(models.DeckConfig.fromJson, raw)
  if ok then return deck end
  if type(deck) == "table" and deck.legacyDeckFormat then return nil, "legacy" end
  return nil, "invalid"
end

-- Validates a user-typed deck/save name (minus ".json"). Returns an error
-- message, or nil when valid. Callers trim the name first.
function D.validateName(name, emptyMessage)
  if name == "" then return emptyMessage or "Enter a deck name." end
  if name == "." or name == ".." then return "Invalid name." end
  if name:find('[/\\:%*%?"<>|]') then return 'Name cannot contain: / \\ : * ? " < > |' end
  return nil
end

function D.deckPath(rootPath, gameId, name) return fs.join(rootPath, gameId, name .. ".json") end

function D.deckExists(rootPath, gameId, name) return fs.isFile(D.deckPath(rootPath, gameId, name)) end

-- Writes <rootPath>/<gameId>/<name>.json (compact JSON, like Flutter).
function D.writeDeck(rootPath, gameId, name, deck)
  fs.mkdirs(fs.join(rootPath, gameId))
  local path = D.deckPath(rootPath, gameId, name)
  local ok, err = fs.writeFile(path, json.encode(models.DeckConfig.toJson(deck)))
  if not ok then return nil, err end
  return path
end

return D
