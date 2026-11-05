-- Table display settings (LÖVE port only). Selection color is a simple
-- override of a hardcoded default. Table/playmat-border color resolve a
-- chain: an explicit player override (settings.json) beats the current
-- game's own tableColor/playmatBorderColor (gamedef.json, "#RRGGBB"), which
-- beats a hardcoded default. Overrides are stored as ARGB ints; leaving a
-- setting at its effective default (nothing picked, or picking back to
-- whatever's already in effect) is left unsaved.
local settings = require("src.data.settings")
local color = require("src.core.color")

local T = {}

T.defaultSelectionColor = 0xFFFFEB3B -- Material yellow 500
T.defaultFeltColor = 0xFF0B6E4F -- mirrors the old theme.fixed.felt
T.defaultPlaymatBorderColor = 0xFF063D2A -- mirrors the old theme.fixed.centerMarkerBorder

local selectionCached

function T.selectionColor()
  if selectionCached == nil then
    local v = tonumber(settings.get(settings.keys.selectionColor))
    selectionCached = v and math.floor(v) or T.defaultSelectionColor
  end
  return selectionCached
end

function T.setSelectionColor(argb)
  if argb == T.selectionColor() then return end
  selectionCached = argb
  if argb == T.defaultSelectionColor then
    settings.remove(settings.keys.selectionColor)
  else
    settings.set(settings.keys.selectionColor, argb)
  end
end

function T.isSelectionColorDefault() return T.selectionColor() == T.defaultSelectionColor end
function T.resetSelectionColor() T.setSelectionColor(T.defaultSelectionColor) end

local feltLoaded, feltOverride

function T.feltOverride()
  if not feltLoaded then
    local v = tonumber(settings.get(settings.keys.feltColor))
    feltOverride, feltLoaded = v and math.floor(v) or nil, true
  end
  return feltOverride
end

-- gameHex: the current game's own tableColor ("#RRGGBB"), or nil.
function T.feltColor(gameHex)
  return T.feltOverride() or (gameHex and color.colorFromHex(gameHex, nil)) or T.defaultFeltColor
end

function T.setFeltColor(argb, gameHex)
  if argb == T.feltColor(gameHex) then return end
  feltOverride, feltLoaded = argb, true
  settings.set(settings.keys.feltColor, argb)
end

function T.isFeltColorDefault() return T.feltOverride() == nil end
function T.resetFeltColor()
  feltOverride, feltLoaded = nil, true
  settings.remove(settings.keys.feltColor)
end

local borderLoaded, borderOverride

function T.playmatBorderOverride()
  if not borderLoaded then
    local v = tonumber(settings.get(settings.keys.playmatBorderColor))
    borderOverride, borderLoaded = v and math.floor(v) or nil, true
  end
  return borderOverride
end

-- gameHex: the current game's own playmatBorderColor ("#RRGGBB"), or nil.
function T.playmatBorderColor(gameHex)
  return T.playmatBorderOverride() or (gameHex and color.colorFromHex(gameHex, nil)) or T.defaultPlaymatBorderColor
end

function T.setPlaymatBorderColor(argb, gameHex)
  if argb == T.playmatBorderColor(gameHex) then return end
  borderOverride, borderLoaded = argb, true
  settings.set(settings.keys.playmatBorderColor, argb)
end

function T.isPlaymatBorderColorDefault() return T.playmatBorderOverride() == nil end
function T.resetPlaymatBorderColor()
  borderOverride, borderLoaded = nil, true
  settings.remove(settings.keys.playmatBorderColor)
end

-- Whether the felt's woven-cloth shader is on (default: yes).
function T.feltTextureEnabled()
  return settings.get(settings.keys.feltTexture) ~= false
end

function T.setFeltTextureEnabled(enabled)
  if enabled then
    settings.remove(settings.keys.feltTexture)
  else
    settings.set(settings.keys.feltTexture, false)
  end
end

return T
