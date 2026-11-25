local Chips = require("lib.chips")
local Deposits = require("lib.deposits")
local Effects = require("lib.effect_registry")

local Colors = {}

Colors.definitions = {
  { id = "paint", label = "Paint", count = 3 },
  { id = "metal", label = "Exposed Metal", count = 1 },
  { id = "primer", label = "Primer at Exposed Edges", count = 3 },
  { id = "scuff", label = "Scuffed Paint", count = 3 },
  { id = "fading", label = "Faded Paint", count = 3 },
  { id = "rust", label = "Rust in Metal", count = 3 },
  { id = "trails", label = "Rust Trails", count = 3 },
  { id = "dirt", label = "Dirt", count = 3 },
  { id = "moss", label = "Moss", count = 3 },
  { id = "soot", label = "Soot", count = 3 },
}

local function trailColor(tone)
  local r, g, b = Chips.sample((tone << 40) | (255 << 32))
  return { r = r, g = g, b = b, a = 255 }
end

local rust = Deposits.defaultColors("Rust")
for _, shade in ipairs(rust) do shade.a = 255 end

local defaults = {
  paint = {
    { r = 43, g = 53, b = 50, a = 255 },
    { r = 99, g = 124, b = 102, a = 255 },
    { r = 195, g = 212, b = 175, a = 255 },
  },
  metal = { r = 140, g = 145, b = 149, a = 255 },
  primer = {
    { r = 64, g = 46, b = 40, a = 135 },
    { r = 127, g = 93, b = 72, a = 165 },
    { r = 177, g = 150, b = 117, a = 142 },
  },
  scuff = {
    { r = 108, g = 103, b = 92, a = 130 },
    { r = 181, g = 170, b = 146, a = 180 },
    { r = 222, g = 215, b = 188, a = 195 },
  },
  fading = {
    { r = 118, g = 108, b = 91, a = 102 },
    { r = 209, g = 190, b = 156, a = 128 },
    { r = 239, g = 225, b = 196, a = 148 },
  },
  rust = rust,
  trails = { trailColor(0), trailColor(128), trailColor(255) },
  dirt = Deposits.defaultColors("Dirt"),
  moss = Deposits.defaultColors("Moss"),
  soot = Effects.defaultColors("Soot"),
}

local function channel(value, fallback)
  value = tonumber(value)
  if not value or value ~= value then return fallback end
  return math.floor(math.max(0, math.min(255, value)) + 0.5)
end

local function swatch(value, fallback)
  if type(value) ~= "table" then value = {} end
  return {
    r = channel(value.r, fallback.r),
    g = channel(value.g, fallback.g),
    b = channel(value.b, fallback.b),
    a = channel(value.a, fallback.a or 255),
  }
end

-- Return a copy so the picker cannot mutate another material's colors.
function Colors.get(palette, id)
  local fallback = defaults[id]
  if not fallback then return nil end
  local value = type(palette) == "table" and palette[id] or nil
  if fallback.r then return swatch(value, fallback) end
  -- Old documents store a single abrasion or fading tint.
  if type(value) == "table" and value.r and (id == "scuff" or id == "fading") then
    local solid = swatch(value, fallback[2])
    return { swatch(solid, solid), swatch(solid, solid), swatch(solid, solid) }
  end
  local ramp = {}
  for i, color in ipairs(fallback) do
    ramp[i] = swatch(type(value) == "table" and value[i] or nil, color)
  end
  return ramp
end

function Colors.paintRamp(color)
  local base = swatch(color, defaults.paint[2])
  local function toward(reference, amount)
    local shade = { a = base.a }
    for _, channelName in ipairs({ "r", "g", "b" }) do
      shade[channelName] = channel(base[channelName] + (reference - base[channelName]) * amount, base[channelName])
    end
    return shade
  end
  return { toward(0, 0.57), base, toward(255, 0.64) }
end

-- A missing override stays missing. In particular, the source metal is
-- visible through the coating by default.
function Colors.normalize(palette)
  local normalized = {}
  if type(palette) ~= "table" then return normalized end
  for _, effect in ipairs(Colors.definitions) do
    local id = effect.id
    if type(palette[id]) == "table" then normalized[id] = Colors.get(palette, id) end
  end
  return normalized
end

return Colors
