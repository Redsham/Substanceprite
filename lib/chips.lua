local Surface = require("lib.surface")
local Texture = require("lib.texture")
local Weather = require("lib.weather")
local Streaks = require("lib.streaks")

local Chips = {}
Chips.style = "Paint Chips"
Chips.defaults = {
  density = 38, scale = 4, intensity = 80, clustering = 65, softness = 57, runoff = 68,
  trails = 65, edge = 0, bottom = 0, seed = 1,
}

local steelColors = { 0x32312FF0, 0x66635FF8, 0xAFADA7FF }

function Chips.defaultColors()
  local colors = {}
  for i, value in ipairs(steelColors) do
    colors[i] = {
      r = (value >> 24) & 255, g = (value >> 16) & 255,
      b = (value >> 8) & 255, a = value & 255,
    }
  end
  return colors
end

local defaultSteel = Chips.defaultColors()
local rustColors = Texture.defaultColors("Rust")
local abs, floor, min, max, sqrt = math.abs, math.floor, math.min, math.max, math.sqrt

local function clamp(value, low, high)
  return min(high, max(low, value))
end

local function unit(value)
  return clamp(value, 0, 1)
end

local function smooth(value)
  return value * value * (3 - 2 * value)
end

local function mix(a, b, amount)
  return a + (b - a) * amount
end

local function byte(value)
  return floor(unit(value) * 255 + 0.5)
end

local function number(options, key, low, high)
  local value = tonumber(options[key])
  if not value or value ~= value then value = Chips.defaults[key] end
  return clamp(value, low, high)
end

local function rustTone(steelTone)
  return unit(steelTone * 0.84 + 0.06)
end

local function hash(x, y, seed)
  local value = ((x * 0x9e3779b1) ~ (y * 0x85ebca77) ~ seed) & 0xffffffff
  value = ((value ~ (value >> 16)) * 0x7feb352d) & 0xffffffff
  value = ((value ~ (value >> 15)) * 0x846ca68b) & 0xffffffff
  return (value ~ (value >> 16)) / 4294967296
end

local function spacing(size, step, seamless)
  step = min(step, size >= 8 and size * 0.55 or max(2, size * 1.25))
  if not seamless then return step end
  local cells = max(1, floor(size / step + 0.5))
  return size / cells, cells
end

local function buildField(width, height, mask, seamless)
  return function(x, y)
    if seamless then
      x, y = x % width, y % height
    elseif x < 0 or x >= width or y < 0 or y >= height then
      return false
    end
    return not mask or not not mask[y * width + x + 1]
  end
end

local function edgeExposure(x, y, allowed)
  if not allowed(x, y) then return 0 end
  if not allowed(x - 1, y) or not allowed(x + 1, y)
     or not allowed(x, y - 1) or not allowed(x, y + 1) then return 1 end
  if not allowed(x - 2, y) or not allowed(x + 2, y)
     or not allowed(x, y - 2) or not allowed(x, y + 2) then return 0.45 end
  return 0
end

local function reliefReader(width, height, heights, allowed, seamless)
  return function(x, y)
    if not allowed(x, y) then return nil end
    if seamless then x, y = x % width, y % height end
    local value = heights[y * width + x + 1]
    if type(value) == "number" and value == value then return unit(value) end
  end
end

local function silhouetteNormal(x, y, allowed)
  local gx = (allowed(x + 1, y) and 2 or 0) - (allowed(x - 1, y) and 2 or 0)
  local gy = (allowed(x, y + 1) and 2 or 0) - (allowed(x, y - 1) and 2 or 0)
  for dy = -1, 1, 2 do
    for dx = -1, 1, 2 do
      if allowed(x + dx, y + dy) then gx, gy = gx + dx, gy + dy end
    end
  end
  return gx / 4, gy / 4
end

local function reliefNormal(x, y, heightAt)
  local center = heightAt(x, y)
  if not center then return 0, 0 end
  local left, right = heightAt(x - 1, y) or center, heightAt(x + 1, y) or center
  local above, below = heightAt(x, y - 1) or center, heightAt(x, y + 1) or center
  local gx, gy = right - left, below - above
  if abs(gx) + abs(gy) > 0.06 then return gx, gy end
  -- Along the center of a symmetric raised seam the slope cancels;
  -- the larger second derivative still identifies its cross-section.
  local bendX, bendY = abs(left + right - 2 * center), abs(above + below - 2 * center)
  if bendX > bendY * 1.35 then return bendX * 0.70, 0 end
  if bendY > bendX * 1.35 then return 0, bendY * 0.70 end
  return 0, 0
end

local function contour(x, y, allowed, heightAt, strength)
  local gx, gy = silhouetteNormal(x, y, allowed)
  if heightAt then
    local dx, dy = reliefNormal(x, y, heightAt)
    -- Either tangent direction gives the same axis.
    if gx * dx + gy * dy < 0 then dx, dy = -dx, -dy end
    gx, gy = gx + dx * strength, gy + dy * strength
  end
  return gx, gy, sqrt(gx * gx + gy * gy)
end

local function fractureProfile(radius, keyX, keyY, seed)
  local left, right = {}, {}
  local taper = { 0.05, 0.72, 0.90, 0.83, 0.62, 0.10 }
  local shift = (hash(keyX, keyY, seed + 201) - 0.5) * radius
  for i, body in ipairs(taper) do
    local bend = shift * (i - 3.5) / 2.5
    left[i] = bend - body * radius * (0.53 + 0.68 * hash(keyX, keyY, seed + i * 19))
    right[i] = bend + body * radius * (0.61 + 0.73 * hash(keyX, keyY, seed + i * 31))
  end
  return left, right
end

local function impactDistance(x, y, impact)
  local dx, dy = x - impact.x, y - impact.y
  local long = (dx * impact.cos + dy * impact.sin) / impact.length
  local across = -dx * impact.sin + dy * impact.cos
  local position = (clamp(long, -1, 1) + 1) * 2.5
  local index = min(5, floor(position) + 1)
  local fraction = position - index + 1
  local left = mix(impact.left[index], impact.left[index + 1], fraction)
  local right = mix(impact.right[index], impact.right[index + 1], fraction)
  return max((abs(long) - 1) * impact.length, left - across, across - right)
end

local function chipField(width, height, options, allowed, mask)
  local seed = floor(number(options, "seed", -2147483648, 4294967295)) ~ 0x19b82f
  local scale = number(options, "scale", 1, 64)
  local density = number(options, "density", 0, 100) / 100
  local clustering = number(options, "clustering", 0, 100) / 100
  local softness = number(options, "softness", 0, 100) / 100
  local runoff = number(options, "runoff", 0, 100) / 100
  local intensity = number(options, "intensity", 0, 100) / 100
  local edge = number(options, "edge", 0, 100) / 100
  local bottom = number(options, "bottom", 0, 100) / 100
  local seamless = options.seamless == true
  local gear = type(options.surface) == "table" and options.surface or nil
  local edgeStrength = 0.37 + 0.44 * edge
  local feather = 0.32 + softness * 0.66
  local grid = max(4.3, scale * 2.18)
  local stepX, periodX = spacing(width, grid, seamless)
  local stepY, periodY = spacing(height, grid, seamless)
  local size = min(stepX, stepY)
  local strength = gear and (tonumber(gear.strength) or Texture.defaultSurfaceStrength) or 0
  local ridge, selected, rain, heightAt
  if gear and type(gear.heights) == "table" then
    if strength > 0 then
      ridge = Surface.sampler(width, height, gear.heights, seamless, "Ridges")
      heightAt = reliefReader(width, height, gear.heights, allowed, seamless)
      if gear.placement and gear.placement ~= "Material" and gear.placement ~= "Ridges" then
        selected = Surface.sampler(width, height, gear.heights, seamless, gear.placement)
      end
    end
    if runoff > 0 then rain = Weather.sampler(width, height, gear.heights, seamless, mask, scale) end
  end
  strength = unit(strength / 100)
  local search = max(1, floor(size * 0.14 + 0.5))
  local contacts = { { 0, 0 }, { -search, 0 }, { search, 0 }, { 0, -search }, { 0, search } }

  local function contact(x, y)
    if not allowed(x, y) then return -1, 0, 0, 0 end
    local gx, gy, slope = contour(x, y, allowed, heightAt, strength)
    local value = edgeExposure(x, y, allowed) * edgeStrength
    if ridge then value = value + max(0, ridge(x, y)) * strength * 0.25 + min(0.30, slope * 0.42) end
    if selected then value = value + selected(x, y) * strength * 0.23 end
    return value, gx, gy, slope
  end

  local function geometry(cx, cy, cos, sin, length, radius, keyX, keyY, noise)
    local left, right = fractureProfile(radius, keyX, keyY, noise)
    return { x = cx, y = cy, cos = cos, sin = sin, length = length, left = left, right = right }
  end

  local function makeImpact(cellX, cellY)
    local keyX = seamless and cellX % periodX or cellX
    local keyY = seamless and cellY % periodY or cellY
    local cx = (cellX + 0.21 + 0.58 * hash(keyX, keyY, seed + 11)) * stepX
    local cy = (cellY + 0.21 + 0.58 * hash(keyX, keyY, seed + 23)) * stepY
    local px, py = floor(cx), floor(cy)
    local match, exposure, gx, gy, slope = -2, -1, 0, 0, 0
    local moveX, moveY = 0, 0
    for i, delta in ipairs(contacts) do
      local dx, dy = delta[1], delta[2]
      local value, ax, ay, magnitude = contact(px + dx, py + dy)
      local score = value - (i == 1 and 0 or 0.14) + 0.035 * hash(keyX, keyY, seed + i * 53)
      if score > match then
        match, exposure, gx, gy, slope = score, value, ax, ay, magnitude
        moveX, moveY = dx, dy
      end
    end
    if exposure < 0 then return false end
    cx, cy = cx + moveX, cy + moveY
    if bottom > 0 then
      local row = py + moveY
      local lower = seamless and (0.5 + 0.5 * math.sin(2 * math.pi * row / height - math.pi))
                    or unit(row / max(1, height - 1))
      exposure = exposure + bottom * (lower - 0.44) * 0.35
    end
    local cluster = hash(keyX // 2, keyY // 2, seed + 47) - 0.5
    local chance = density * (0.24 + 0.57 * density + 1.30 * exposure)
                   + cluster * clustering * 0.39
    if hash(keyX, keyY, seed + 31) > chance then return false end
    local drift = hash(keyX // 2, keyY // 2, seed + 59) * math.pi
    local jitter = hash(keyX, keyY, seed + 61) - 0.5
    local angle = slope > 0.12 and math.atan(-gx, gy) + jitter * 0.32 or drift + jitter * 0.69
    local cos, sin = math.cos(angle), math.sin(angle)
    local fracture = hash(keyX, keyY, seed + 71)
    local impactWidth = max(0.40, size * (0.076 + 0.085 * fracture))
    local impactLength = size * (0.25 + 0.24 * hash(keyX, keyY, seed + 89))
    if fracture > 0.79 then impactWidth, impactLength = impactWidth * 1.39, impactLength * 0.82 end
    local impact = geometry(cx, cy, cos, sin, impactLength, impactWidth, keyX, keyY, seed)
    impact.age = hash(keyX, keyY, seed + 101)
    if hash(keyX, keyY, seed + 117) < clustering * 0.54 then
      local sign = hash(keyX, keyY, seed + 129) < 0.5 and -1 or 1
      local along = sign * impactLength * (0.78 + 0.28 * hash(keyX, keyY, seed + 137))
      local across = impactWidth * (0.60 + 0.71 * hash(keyX, keyY, seed + 139))
      impact.flake = geometry(cx + cos * along - sin * across, cy + sin * along + cos * across,
        cos, sin, impactLength * 0.48, impactWidth * 0.51, keyX, keyY, seed + 179)
    end
    return impact
  end

  local previousRow, rows
  return function(x, y)
    local gridX, gridY = floor(x / stepX), floor(y / stepY)
    if gridY ~= previousRow then
      previousRow, rows = gridY, { {}, {}, {} }
    end
    local age, best = 0, math.huge
    for dy = -1, 1 do
      local row = rows[dy + 2]
      for cellX = gridX - 1, gridX + 1 do
        local impact = row[cellX]
        if impact == nil then
          impact = makeImpact(cellX, gridY + dy)
          row[cellX] = impact
        end
        if impact then
          local distance = impactDistance(x + 0.5, y + 0.5, impact)
          if impact.flake then distance = min(distance, impactDistance(x + 0.5, y + 0.5, impact.flake) + 0.08) end
          if distance < best then best, age = distance, impact.age end
        end
      end
    end
    if best > feather * 0.64 then return 0 end
    local grain = hash(x, y, seed + 151)
    best = best + (grain - 0.5) * 0.24
    local alpha = smooth(unit((feather * 0.46 - best) / feather)) * intensity
    local coverage = byte(alpha)
    if coverage == 0 then return 0 end

    local exposure = smooth(unit((0.09 - best) / (0.27 + feather * 0.23)))
    local tone = clamp(0.16 + 0.31 * exposure + 0.15 * grain - 0.117 * age, 0, 0.66)
    local wet, flow, retention = 0, 0, 0
    if rain then wet, flow, retention = rain(x, y) end
    -- Oxidation is bounded by exposed metal. Fast drainage contributes less
    -- than retained water, and freshly struck chips can stay steel-colored.
    local moisture = runoff * max(0, retention * 0.88 + max(0, wet) * 0.20 - flow * 0.13)
    local oxidationThreshold = 0.86 - runoff * 0.545
    local oxide = smooth(unit((age * 0.70 + grain * 0.16 + moisture - oxidationThreshold) / 0.45))
                  * exposure * unit(-best * 5)
    return (byte(exposure) << 24) | (byte(oxide) << 16) | (byte(tone) << 8) | coverage
  end
end

function Chips.generate(width, height, options, mask, rect)
  width, height = floor(width), floor(height)
  options = options or {}
  rect = rect or { x = 0, y = 0, width = width, height = height }
  local rw, rh = floor(rect.width), floor(rect.height)
  local result = {}
  if rw < 1 or rh < 1 then return result end
  if width < 1 or height < 1 or number(options, "density", 0, 100) == 0
     or number(options, "intensity", 0, 100) == 0 then
    for i = 1, rw * rh do result[i] = 0 end
    return result
  end

  local seamless = options.seamless == true
  local allowed = buildField(width, height, mask, seamless)
  local sample = chipField(width, height, options, allowed, mask)
  local trails = number(options, "trails", 0, 100)
  local stainAt
  if trails > 0 and number(options, "runoff", 0, 100) > 0 then
    local chipSample, cached = sample, {}
    sample = function(x, y)
      if not allowed(x, y) then return 0 end
      local index = y * width + x + 1
      local value = cached[index]
      if value == nil then
        value = chipSample(x, y)
        cached[index] = value
      end
      return value
    end
    local surface = type(options.surface) == "table" and options.surface or nil
    stainAt = Streaks.sampler(width, height, surface and surface.heights, mask, seamless,
      function(x, y)
        local chip = sample(x, y)
        local oxide = ((chip >> 16) & 255) / 255
        if oxide == 0 then return 0 end
        local coverage = (chip & 255) / 255
        return oxide * coverage, rustTone(((chip >> 8) & 255) / 255)
      end, { strength = trails, scale = options.scale, seed = options.seed })
  end
  local x0, y0, i = floor(rect.x), floor(rect.y), 1
  for dy = 0, rh - 1 do
    local y = y0 + dy
    if seamless then y = y % height end
    for dx = 0, rw - 1 do
      local x = x0 + dx
      if seamless then x = x % width end
      local value = 0
      if allowed(x, y) then
        value = sample(x, y)
        if value == 0 and stainAt then
          local amount, tone = stainAt(x, y)
          local alpha = byte(amount)
          if alpha > 0 then value = (byte(tone) << 40) | (alpha << 32) end
        end
      end
      result[i] = value
      i = i + 1
    end
  end
  return result
end

function Chips.trail(sample)
  return ((sample or 0) >> 32) & 255, ((sample or 0) >> 40) & 255
end

local function ramp(colors, tone)
  local index = tone < 0.5 and 1 or 2
  local a, b = colors[index], colors[index + 1]
  local amount = tone * 2 - index + 1
  return mix(a.r, b.r, amount), mix(a.g, b.g, amount), mix(a.b, b.b, amount),
         mix(a.a or 255, b.a or 255, amount)
end

-- A chip stores coverage, steel tone, oxidation and exposed metal in the low
-- four bytes. A transported stain on paint uses the two higher bytes.
-- Relief is weighted by this pixel's alpha, so the caller only scales it by
-- the compositing opacity (not by alpha a second time).
function Chips.sample(sample, colors)
  if not sample or sample <= 0 then return nil end
  local stain, stainTone = Chips.trail(sample)
  if stain > 0 then
    -- Oxide carried by water tints intact paint and contributes no chip depth.
    local r, g, b = ramp(rustColors, 0.27 + 0.73 * stainTone / 255)
    return floor(r + 8.5), floor(g + 1.5), floor(b - 4.5), stain, 0
  end
  local coverage, tone = (sample & 255) / 255, ((sample >> 8) & 255) / 255
  local oxide, exposure = ((sample >> 16) & 255) / 255, ((sample >> 24) & 255) / 255
  local r, g, b, a = ramp(colors or defaultSteel, tone)
  local rr, rg, rb = ramp(rustColors, rustTone(tone))
  local alpha = floor(a * coverage + 0.5)
  if alpha == 0 then return nil end
  local relief = exposure * (-0.062 + oxide * 0.030) * (alpha / 255)
  return floor(mix(r, rr, oxide) + 0.5), floor(mix(g, rg, oxide) + 0.5),
         floor(mix(b, rb, oxide) + 0.5), alpha, relief
end

return Chips
