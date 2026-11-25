local Texture = require("lib.texture")

local Soot = {
  defaults = { density = 66, scale = 5, intensity = 76, clustering = 70 },
  colors = {
    { r = 32, g = 29, b = 29 },
    { r = 69, g = 58, b = 53 },
    { r = 122, g = 103, b = 88 },
  },
}

local function clamp(value)
  return math.max(0, math.min(1, value))
end

local function smooth(value)
  local t = clamp(value)
  return t * t * (3 - 2 * t)
end

local function setting(options, key, fallback, minimum, maximum)
  local number = tonumber(options[key])
  if not number or number ~= number then return fallback end
  return math.max(minimum, math.min(maximum, number))
end

local function footprintBounds(width, height, mask)
  if not mask then return 0, 0, width - 1, height - 1 end
  local left, top, right, bottom = width, height, -1, -1
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      if mask[y * width + x + 1] then
        left, top = math.min(left, x), math.min(top, y)
        right, bottom = math.max(right, x), math.max(bottom, y)
      end
    end
  end
  return left, top, right, bottom
end

local function sourceColumn(width, mask, bottom, target, low, high)
  if not mask then return target end
  local best, closest = target, math.huge
  for x = low, high do
    local distance = math.abs(x - target)
    if distance < closest and mask[bottom * width + x + 1] then
      best, closest = x, distance
    end
  end
  return best
end

function Soot.generate(width, height, options, mask, rect)
  options = options or {}
  width, height = math.floor(width), math.floor(height)
  rect = rect or { x = 0, y = 0, width = width, height = height }
  local left, top, right, bottom = footprintBounds(width, height, mask)
  local spanX, spanY = right - left + 1, bottom - top + 1
  local density = setting(options, "density", Soot.defaults.density, 0, 100)
  local intensity = setting(options, "intensity", Soot.defaults.intensity, 0, 100)
  local outWidth, outHeight = math.floor(rect.width), math.floor(rect.height)
  local result = {}
  if spanX <= 0 or spanY <= 0 or density == 0 or intensity == 0 then
    for i = 1, math.max(0, outWidth) * math.max(0, outHeight) do result[i] = 0 end
    return result
  end

  local scale = setting(options, "scale", Soot.defaults.scale, 1, 64)
  local clustering = setting(options, "clustering", Soot.defaults.clustering, 0, 100)
  local seed = math.floor(setting(options, "seed", 1, -2147483648, 4294967295))
  local seamless = options.seamless == true
  local targets = Texture.generateSoftDeposit(width, height, {
    style = "Dirt", density = 57 + density * 0.42, intensity = 100,
    clustering = clustering, scale = scale, softness = 82, runoff = 0,
    seamless = seamless, seed = (seed ~ 0x415f810b) & 0xffffffff,
    edge = options.edge, bottom = options.bottom, surface = options.surface,
  }, mask, rect)

  local variation = ((seed * 1664525 + 1013904223) & 0xffff) / 0xffff
  local sourceY = bottom
  local seamMargin = seamless and top == 0 and bottom == height - 1 and math.floor(height * 0.17) or 0
  sourceY = sourceY - seamMargin
  local center = sourceColumn(width, mask, sourceY, left + (spanX - 1) * (0.29 + variation * 0.42), left, right)
  local widthAtSource = math.max(1.3, math.min(spanX * 0.24, scale * 1.13))
  local outX, outY = math.floor(rect.x), math.floor(rect.y)
  local i = 1
  for row = 0, outHeight - 1 do
    local y = outY + row
    if seamless then y = y % height end
    local rise = clamp((sourceY - y) / math.max(1, sourceY - top))
    local falloff = 1 - smooth((rise - 0.04) / (0.34 + density * 0.006))
    if seamMargin > 0 then
      falloff = falloff * (1 - smooth((y - sourceY) / seamMargin)) * smooth(y / seamMargin)
    end
    local drift = math.sin(rise * 4.4 + variation * 3.1) - math.sin(variation * 3.1)
    local plumeX = center + drift * rise * (0.7 + spanX * 0.15)
    local plumeWidth = widthAtSource + spanX * rise * 0.31
    for column = 0, outWidth - 1 do
      local sample = targets[i]
      result[i] = 0
      if sample and sample > 0 then
        local x = outX + column
        if seamless then x = x % width end
        local grain = (sample & 255) / 255
        local tone = ((sample >> 8) & 255) / 255
        local distance = math.abs(x - plumeX)
        if seamless then distance = math.min(distance % width, (-distance) % width) end
        local rim = 1 - smooth((distance / plumeWidth - 0.18 + (tone - 0.5) * 0.35) / 0.91)
        local shape = rim * falloff
        local coverage = math.floor(shape * (0.37 + grain * 0.83) * intensity * 2.55 + 0.5)
        if coverage > 0 then
          local pigment = math.floor(clamp(tone * 0.44 + rise * 0.41 + (1 - rim) * 0.12) * 255 + 0.5)
          result[i] = (pigment << 8) | math.min(255, coverage)
        end
      end
      i = i + 1
    end
  end
  return result
end

function Soot.sampler(colors)
  return function(sample)
    local r, g, b, a = Texture.softDepositSample(sample, colors)
    if not r then return nil end
    return r, g, b, a, a * 0.022 / 255
  end
end

return Soot
