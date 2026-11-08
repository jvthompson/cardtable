-- Persistent key/value settings (replaces Flutter's shared_preferences).
-- Stored as settings.json in LÖVE's save directory, keeping the Flutter
-- key names.
local json = require("lib.json")

local S = {}

S.keys = {
  gamesDirectoryPath = "games_directory_path",
  decksDirectoryPath = "decks_directory_path",
  playerName = "player_profile_name",
  playerColor = "player_profile_color",
  playerAvatarPath = "player_profile_avatar_path",
  reconnectHostKey = "reconnect_host_key",
  reconnectPlayerId = "reconnect_player_id",
  discordRefreshToken = "discord_refresh_token",
  darkMode = "dark_mode_enabled",
  -- LÖVE port only:
  uiScale = "ui_scale",
  recentServers = "recent_servers",
  selectionColor = "selection_color",
  feltColor = "felt_color",
  playmatBorderColor = "playmat_border_color",
  currentTurnColor = "current_turn_color",
  feltTexture = "felt_texture_enabled",
}

local FILE = "settings.json"
local values

local function load()
  if values then return end
  values = {}
  local ok, raw = pcall(love.filesystem.read, FILE)
  if ok and raw then
    local v = json.tryDecode(raw)
    if type(v) == "table" then
      for k, x in pairs(v) do values[k] = x end
    end
  end
end

local function save()
  local o = json.object()
  local keys = {}
  for k in pairs(values) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do o[k] = values[k] end
  pcall(love.filesystem.write, FILE, json.encode(o, { indent = "  " }))
end

function S.get(key, default)
  load()
  local v = values[key]
  if v == nil then return default end
  return v
end

function S.set(key, value)
  load()
  values[key] = value
  save()
end

function S.remove(key)
  load()
  values[key] = nil
  save()
end

return S
