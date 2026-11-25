local Color = {}

Color.presets = { "Neutral", "Warm", "Cold", "Industrial", "Cartoon" }

local settings = {
  Neutral    = { hueShift = 0,   saturation = 0,   lightness = 28, contrast = 42 },
  Warm       = { hueShift = 32,  saturation = 12,  lightness = 32, contrast = 49 },
  Cold       = { hueShift = -34, saturation = -8,  lightness = 30, contrast = 48 },
  Industrial = { hueShift = -16, saturation = -45, lightness = 25, contrast = 62 },
  Cartoon    = { hueShift = 44,  saturation = 33,  lightness = 37, contrast = 70 },
}

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function channel(value, fallback)
  return math.floor(clamp(tonumber(value) or fallback, 0, 255) + 0.5)
end

local function toLinear(channelValue)
  local value = channelValue / 255
  if value <= 0.04045 then
    return value / 12.92
  end
  return ((value + 0.055) / 1.055) ^ 2.4
end

local function toChannel(linear)
  local value = clamp(linear, 0, 1)
  if value <= 0.0031308 then
    return math.floor(12.92 * value * 255 + 0.5)
  end
  return math.floor((1.055 * value ^ (1 / 2.4) - 0.055) * 255 + 0.5)
end

-- Oklab matrices by Björn Ottosson, https://bottosson.github.io/posts/oklab/
local function toLab(rgb)
  local r, g, b = toLinear(rgb.r), toLinear(rgb.g), toLinear(rgb.b)
  local l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ^ (1 / 3)
  local m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ^ (1 / 3)
  local s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ^ (1 / 3)

  return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
         1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
         0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
end

local function fromLab(lightness, a, b)
  local l = (lightness + 0.3963377774 * a + 0.2158037573 * b) ^ 3
  local m = (lightness - 0.1055613458 * a - 0.0638541728 * b) ^ 3
  local s = (lightness - 0.0894841775 * a - 1.2914855480 * b) ^ 3

  return  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
         -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
         -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
end

local function inGamut(r, g, b)
  return r >= 0 and r <= 1 and g >= 0 and g <= 1 and b >= 0 and b <= 1
end

local function fromLch(lightness, chroma, hue)
  local cosHue, sinHue = math.cos(hue), math.sin(hue)
  local r, g, b = fromLab(lightness, chroma * cosHue, chroma * sinHue)
  if inGamut(r, g, b) then
    return toChannel(r), toChannel(g), toChannel(b)
  end

  -- Preserve the lightness and hue by reducing chroma before quantizing to 8 bits.
  local low, high = 0, chroma
  for _ = 1, 18 do
    local middle = (low + high) * 0.5
    if inGamut(fromLab(lightness, middle * cosHue, middle * sinHue)) then
      low = middle
    else
      high = middle
    end
  end
  r, g, b = fromLab(lightness, low * cosHue, low * sinHue)
  return toChannel(r), toChannel(g), toChannel(b)
end

local function option(options, key, minimum, maximum)
  return clamp(tonumber(options[key]) or settings.Neutral[key], minimum, maximum)
end

function Color.preset(name)
  local copy = {}
  for key, value in pairs(settings[name] or settings.Neutral) do
    copy[key] = value
  end
  return copy
end

function Color.lightness(rgb)
  return (toLab(rgb))
end

function Color.generate(base, options)
  options = options or settings.Neutral
  local anchor = {
    r = channel(base.r, 0), g = channel(base.g, 0), b = channel(base.b, 0),
    a = channel(base.a, 255), name = "Base",
  }
  local hueShift = option(options, "hueShift", -60, 60)
  local saturation = 1 + option(options, "saturation", -100, 100) / 100
  local lightness = option(options, "lightness", 0, 60) / 60
  local contrast = option(options, "contrast", 0, 100) / 100
  local baseLight, labA, labB = toLab(anchor)
  local baseChroma = math.sqrt(labA * labA + labB * labB)
  local baseHue = math.atan(labB, labA)

  local spread = (0.10 + 0.58 * lightness) * (0.58 + 0.42 * contrast)
  local near = 0.60 - 0.20 * contrast
  -- Adapt to the available range on both sides of the base to avoid clipped stops.
  local darkRoom, lightRoom = baseLight, 1 - baseLight
  local darkExtent = math.min(0.95, spread / (0.38 + 0.62 * darkRoom)) * darkRoom
  local lightExtent = math.min(0.95, spread / (0.38 + 0.62 * lightRoom)) * lightRoom

  local warmth = hueShift >= 0
  local hueAmount = math.abs(hueShift) / 60

  local function makeStop(name, targetLight, chromaWeight, temperatureWeight, targetHue, previous)
    local hue = baseHue
    local temperature = hueAmount * temperatureWeight
    local tint = 0.035 * temperature * math.max(0, 1 - baseChroma / 0.05)
    if baseChroma < 0.001 then
      hue = targetHue
    else
      -- Use a circular interpolation with smooth behavior across the hue wheel.
      local a = math.cos(baseHue) + 0.70 * temperature * math.cos(targetHue)
      local b = math.sin(baseHue) + 0.70 * temperature * math.sin(targetHue)
      hue = math.atan(b, a)
    end

    local chroma = saturation * (baseChroma * chromaWeight + tint)
    local r, g, b = fromLch(targetLight, chroma, hue)
    local stop = { r = r, g = g, b = b, a = anchor.a, name = name }

    -- Quantization can move a very dark or very light stop past its inner neighbor.
    local measured, previousLight = Color.lightness(stop), Color.lightness(previous)
    if (targetLight < baseLight and measured > previousLight)
      or (targetLight > baseLight and measured < previousLight) then
      stop.r, stop.g, stop.b = previous.r, previous.g, previous.b
    end
    return stop
  end

  local shadow = makeStop("Shadow", baseLight - near * darkExtent, 0.98,
    warmth and 0.36 or 0.72, math.rad(warmth and 38 or 264), anchor)
  local deepShadow = makeStop("Deep Shadow", baseLight - darkExtent, 0.80,
    warmth and 0.56 or 1.00, math.rad(warmth and 35 or 275), shadow)
  local light = makeStop("Light", baseLight + near * lightExtent, 0.92,
    warmth and 0.67 or 0.38, math.rad(warmth and 72 or 227), anchor)
  local highlight = makeStop("Highlight", baseLight + lightExtent, 0.62,
    warmth and 1.00 or 0.56, math.rad(warmth and 83 or 218), light)

  return { deepShadow, shadow, anchor, light, highlight }
end

return Color
