-- Colors, fonts and icons. Mirrors lib/app_theme.dart (Material 3 seeded
-- from green, light and dark) plus the explicit colors the Flutter widgets
-- use. Colors are {r, g, b, a} tables in 0..1.
local utf8 = require("utf8")

local T = {}

local function hex(s, a)
  s = s:gsub("#", "")
  return { tonumber(s:sub(1, 2), 16) / 255, tonumber(s:sub(3, 4), 16) / 255, tonumber(s:sub(5, 6), 16) / 255, a or 1 }
end
T.hex = hex

-- Material 3 schemes generated from Colors.green (approximate tones).
T.light = {
  primary = hex("#3B6939"), onPrimary = hex("#FFFFFF"),
  primaryContainer = hex("#BCF0B4"), onPrimaryContainer = hex("#002204"),
  secondaryContainer = hex("#D7E8CD"), onSecondaryContainer = hex("#121F0E"),
  surface = hex("#F8FBF1"), onSurface = hex("#191D17"), onSurfaceVariant = hex("#424940"),
  surfaceContainer = hex("#ECEFE5"), surfaceContainerHigh = hex("#E7E9E0"), surfaceContainerHighest = hex("#E1E4DA"),
  outline = hex("#72796F"), outlineVariant = hex("#C2C9BD"),
  error = hex("#BA1A1A"), scrim = hex("#000000", 0.32), disabled = hex("#191D17", 0.38),
  shadow = hex("#000000", 0.35),
}

T.dark = {
  primary = hex("#A1D39A"), onPrimary = hex("#0A390F"),
  primaryContainer = hex("#235024"), onPrimaryContainer = hex("#BCF0B4"),
  secondaryContainer = hex("#3B4B37"), onSecondaryContainer = hex("#D7E8CD"),
  surface = hex("#11140F"), onSurface = hex("#E1E4DA"), onSurfaceVariant = hex("#C2C9BD"),
  surfaceContainer = hex("#1D211B"), surfaceContainerHigh = hex("#282B25"), surfaceContainerHighest = hex("#32362F"),
  outline = hex("#8C9388"), outlineVariant = hex("#424940"),
  error = hex("#FFB4AB"), scrim = hex("#000000", 0.5), disabled = hex("#E1E4DA", 0.38),
  shadow = hex("#000000", 0.6),
}

-- Fixed colors used regardless of theme.
T.fixed = {
  overlayPanel = hex("#262626"),
  titleBar = hex("#1B2430"),
  titleBarForeground = { 1, 1, 1, 0.7 },
  white = { 1, 1, 1, 1 },
  black = { 0, 0, 0, 1 },
  orange = hex("#FF9800"),
  blue = hex("#2196F3"),
  blueAccent = hex("#448AFF"),
  red = hex("#F44336"),
  green = hex("#4CAF50"),
  greenDark = hex("#43A047"),
  redAccent = hex("#FF5252"),
  cardBackBlue = hex("#1565C0"),
  missingBack = hex("#B71C1C"),
}

T.isDark = false
T.c = T.light

function T.setDark(dark)
  T.isDark = dark and true or false
  T.c = T.isDark and T.dark or T.light
end

-- Returns a copy of color with alpha multiplied.
function T.alpha(c, a) return { c[1], c[2], c[3], (c[4] or 1) * a } end

function T.mix(a, b, t)
  return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, (a[4] or 1) + ((b[4] or 1) - (a[4] or 1)) * t }
end

-- Relative luminance > 0.5 means "light" (pick dark text on it).
function T.isLight(c)
  local function lin(x) return x <= 0.03928 and x / 12.92 or ((x + 0.055) / 1.055) ^ 2.4 end
  return 0.2126 * lin(c[1]) + 0.7152 * lin(c[2]) + 0.0722 * lin(c[3]) > 0.5
end

---------------------------------------------------------------------------
-- Fonts
---------------------------------------------------------------------------

local FONT_FILES = {
  regular = "assets/fonts/Roboto-Regular.ttf",
  medium = "assets/fonts/Roboto-Medium.ttf",
  bold = "assets/fonts/Roboto-Bold.ttf",
}
local fonts = {}
local iconFonts = {}

-- Effective UI scale (display DPI x the user's UI scale setting). The whole
-- UI is drawn under love.graphics.scale(T.scale); fonts are rasterized at
-- that density (LÖVE's font dpiscale) so text stays sharp while every
-- measurement stays in logical units.
T.scale = 1

function T.setScale(s)
  if s == T.scale then return end
  T.scale = s
  fonts, iconFonts = {}, {}
end

local function newFont(file, size)
  return love.graphics.newFont(file, size, "normal", T.scale)
end

-- weight: "regular" (default) | "medium" | "bold"
function T.font(size, weight)
  weight = weight or "regular"
  size = math.floor(size + 0.5)
  local key = weight .. size
  local f = fonts[key]
  if not f then
    f = newFont(FONT_FILES[weight] or FONT_FILES.regular, size)
    -- Roboto lacks symbols such as the card suits; fall back to Noto Sans
    -- Symbols 2 for those glyphs.
    local ok, sym = pcall(newFont, "assets/fonts/NotoSansSymbols2-Regular.ttf", size)
    if ok then f:setFallbacks(sym) end
    fonts[key] = f
  end
  return f
end

function T.iconFont(size)
  size = math.floor(size + 0.5)
  local f = iconFonts[size]
  if not f then
    f = newFont("assets/fonts/MaterialIcons-Regular.ttf", size)
    iconFonts[size] = f
  end
  return f
end

-- Material Icons codepoints for the icons the app uses. Outlined variants
-- from the Flutter code map to their filled counterparts.
T.icons = {
  add = 0xe145, close = 0xe5cd, folder_open = 0xe2c8, delete_outline = 0xe92e, save = 0xe161,
  refresh = 0xe5d5, filter_alt_off = 0xeb32, shuffle = 0xe043, search = 0xe8b6, remove = 0xe15b,
  clear = 0xe14c, arrow_drop_down = 0xe5c5, warning_amber = 0xf083, visibility = 0xe8f4,
  visibility_off = 0xe8f5, system_update = 0xe62a, style = 0xe41d, save_alt = 0xe171,
  person_remove = 0xef66, note_add = 0xe89c, merge_type = 0xe252, logout = 0xe9ba, power_settings_new = 0xe8ac,
  light_mode = 0xe518, image_not_supported = 0xf116, filter_none = 0xe3e0, expand_more = 0xe5cf,
  expand_less = 0xe5ce, drag_indicator = 0xe945, dark_mode = 0xe51c, crop_square = 0xe3c6,
  copy_all = 0xe2ec, colorize = 0xe3b8, chevron_right = 0xe5cc, chevron_left = 0xe5cb,
  check_box_outline_blank = 0xe835, check_box = 0xe834, check = 0xe5ca, broken_image = 0xe3ad,
  keyboard = 0xe312, arrow_back = 0xe5c4, settings = 0xe8b8, person = 0xe7fd, edit = 0xe3c9, palette = 0xe40a, more_vert = 0xe5d4,
  info_outline = 0xe88f, build = 0xe869, layers = 0xe53b, widgets = 0xe1bd, image = 0xe3f4,
  send = 0xe163, shield = 0xe9e0, toll = 0xe8e0, block = 0xe14b, vpn_key = 0xe0da, card_giftcard = 0xe8f6,
  sports_esports = 0xea28, group = 0xe7ef, swap_horiz = 0xe8d4, hourglass_empty = 0xe88b, history = 0xe889,
  local_cafe = 0xe541, folder = 0xe2c7, insert_drive_file = 0xe24d, arrow_upward = 0xe5d8,
  upload_file = 0xe2c6, menu_book = 0xea19,
}

local glyphCache = {}
function T.glyph(name)
  local g = glyphCache[name]
  if not g then
    local cp = T.icons[name]
    if not cp then error("unknown icon '" .. tostring(name) .. "'", 2) end
    g = utf8.char(cp)
    glyphCache[name] = g
  end
  return g
end

function T.setColor(c, alphaMul)
  love.graphics.setColor(c[1], c[2], c[3], (c[4] or 1) * (alphaMul or 1))
end

return T
