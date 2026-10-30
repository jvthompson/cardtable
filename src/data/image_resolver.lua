-- Port of lib/data/image_path_resolver.dart.
local fs = require("src.data.fs")
local models = require("src.core.models")
local util = require("src.core.util")

local R = {}

-- Existence checks run during rendering, so they're memoized; call
-- R.clearCache() after the filesystem changes (editor saves, refresh).
local existsCache = {}

local function exists(path)
  local v = existsCache[path]
  if v == nil then
    v = fs.isFile(path)
    existsCache[path] = v
  end
  return v
end

function R.clearCache() existsCache = {} end

function R.resolveBareImagePath(folderPath, bareImagePath, setId)
  local base = setId == nil and folderPath or fs.join(folderPath, setId)
  return fs.join(base, bareImagePath)
end

function R.resolvedImagePathForDisplay(folderPath, bareImagePath, setId)
  if bareImagePath == nil then return nil end
  return R.resolveBareImagePath(folderPath, bareImagePath, setId)
end

local function uniqueCardBackPathFor(imagePath)
  local lastDot = imagePath:match("^.*()%.")
  -- Only a dot inside the file name counts, not one in a parent folder.
  local lastSep = imagePath:match("^.*()[/\\]") or 0
  if lastDot == nil or lastDot <= 1 or lastDot < lastSep then return imagePath .. models.cardBackFileSuffix end
  return imagePath:sub(1, lastDot - 1) .. models.cardBackFileSuffix .. imagePath:sub(lastDot)
end
R.uniqueCardBackPathFor = uniqueCardBackPathFor

-- Returns path (or nil), missing (bool), orientation.
function R.resolveCardBackImagePath(cardBacks, card)
  local cardBackId = card and card.cardBackId
  if cardBackId == models.uniqueCardBackId then
    local orientation = card.uniqueBackOrientation or "portrait"
    if card.imagePath == nil then return nil, true, orientation end
    local candidate = uniqueCardBackPathFor(card.imagePath)
    if exists(candidate) then return candidate, false, orientation end
    return nil, true, orientation
  end
  local selected
  if cardBackId ~= nil then
    selected = util.find(cardBacks, function(b) return b.id == cardBackId end)
  end
  selected = selected or cardBacks[1]
  if selected == nil then return nil, false, "portrait" end
  return selected.imagePath, false, selected.orientation or "portrait"
end

R.packGeneratorImageFileName = "packgen.png"

function R.resolvePackGeneratorImagePath(folderPath)
  if folderPath == nil then return nil end
  local candidate = fs.join(folderPath, R.packGeneratorImageFileName)
  return exists(candidate) and candidate or nil
end

local IMAGE_EXTENSIONS = { "png", "jpg", "jpeg", "webp", "gif", "bmp" }

-- Probes <folderPath>/<baseName>.<ext> for each known extension, in order.
function R.resolveImageAnyExt(folderPath, baseName)
  if folderPath == nil or baseName == nil then return nil end
  for _, ext in ipairs(IMAGE_EXTENSIONS) do
    local candidate = fs.join(folderPath, baseName .. "." .. ext)
    if exists(candidate) then return candidate end
  end
  return nil
end

function R.resolveGameLogoImagePath(folderPath)
  return R.resolveImageAnyExt(folderPath, "gamelogo")
end

-- Client side: keep the host's card/zone/tag/set data but use this
-- machine's own image paths (nil where the client lacks the card), and the
-- local card backs and folder.
function R.mergeLocalImagePaths(remote, localGame)
  local localImageById = {}
  for _, c in ipairs(localGame.cards) do localImageById[c.id] = c.imagePath or false end
  return models.GameDefinition.new({
    id = remote.id,
    name = remote.name,
    cards = util.map(remote.cards, function(c)
      local p = localImageById[c.id]
      return util.copyWith(c, { imagePath = p or util.NIL })
    end),
    cardBacks = localGame.cardBacks,
    zones = remote.zones,
    tagGroups = remote.tagGroups,
    sets = remote.sets,
    folderPath = localGame.folderPath,
    hasScenarios = remote.hasScenarios,
    scenarios = remote.scenarios,
    sameOrientationForAll = remote.sameOrientationForAll,
  })
end

return R
