local Surface = require("lib.surface")
local Lighting = { defaultMatch = 85 }

local floor, min, max = math.floor, math.min, math.max

local function unit(value)
  return max(0, min(1, value))
end

local function smooth(value)
  value = unit(value)
  return value * value * (3 - 2 * value)
end

local function mix(from, to, amount)
  return from + (to - from) * amount
end

local function byte(value)
  return floor(unit(value) * 255 + 0.5)
end

local function noContext()
  return nil
end

local directions = { {1, 0}, {-1, 0}, {0, 1}, {0, -1} }

-- A packed context stores original luma and a reference for the receiving
-- surface. Both are derived before compositing any effects.
function Lighting.sampler(width, height, sourceReader, mask, seamless)
  width, height = floor(width), floor(height)
  if width < 1 or height < 1 or type(sourceReader) ~= "function" then return noContext end

  local lumas, histogram, total = {}, {}, 0
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local index = y * width + x + 1
      if not mask or mask[index] then
        local r, g, b, alpha = sourceReader(x, y)
        if r ~= nil and (alpha == nil or alpha > 0) then
          local luma = byte(Surface.luminance(r, g, b))
          local weight = alpha or 255
          lumas[index] = luma
          histogram[luma] = (histogram[luma] or 0) + weight
          total = total + weight
        end
      end
    end
  end
  if total == 0 then return noContext end

  local low, high, accumulated = nil, 0, 0
  for luma = 0, 255 do
    accumulated = accumulated + (histogram[luma] or 0)
    if not low and accumulated >= 0.35 * total then low = luma end
    if accumulated >= 0.65 * total then
      high = luma
      break
    end
  end
  local reference = (low + high) * 0.5

  local function lumaAt(x, y)
    if seamless then
      x, y = x % width, y % height
    elseif x < 0 or y < 0 or x >= width or y >= height then
      return nil
    end
    return lumas[y * width + x + 1]
  end

  local cache = {}
  return function(x, y)
    if seamless then x, y = x % width, y % height end
    local luma = lumaAt(x, y)
    if not luma then return nil end
    local index = y * width + x + 1
    if cache[index] then return cache[index] end

    local sum, weight = luma * 4, 4
    for _, direction in ipairs(directions) do
      local dx, dy = direction[1], direction[2]
      for distance = 1, 3 do
        local neighbor = lumaAt(x + dx * distance, y + dy * distance)
        if not neighbor then break end
        local influence = 4 - distance
        sum, weight = sum + neighbor * influence, weight + influence
      end
    end
    -- Favor the sprite's overall midtones so a dark seam does not become its
    -- own exposure reference. Adapt slightly to large differences in value.
    local localReference = floor(mix(reference, sum / weight, 0.30) + 0.5)
    local context = (localReference << 8) | luma
    cache[index] = context
    return context
  end
end

-- Modulate the pigment's value and chroma under the underlying image's
-- lighting. Opacity remains with the caller and is composed exactly once.
function Lighting.tint(swatchR, swatchG, swatchB, baseR, baseG, baseB, opacity, context, match)
  local amount = unit((match or Lighting.defaultMatch) / 100)
  if amount == 0 or not context or not baseR then return swatchR, swatchG, swatchB end

  local pigment = Surface.luminance(swatchR, swatchG, swatchB)
  local underlay = Surface.luminance(baseR, baseG, baseB)
  local source = (context & 255) / 255
  local reference = (context >> 8) / 255
  local light = mix(source, underlay, 0.82)
  local midtones = 4 * light * (1 - light)
  local value = unit(light + (pigment - reference) * 0.46 * midtones)

  -- Specular peaks retain more of the underlying color and less of the
  -- pigment. Applying this mostly to the bright end leaves warm midtones.
  local peaks = smooth((source - 0.60) / 0.34)
  local localPeaks = smooth((source - reference - 0.12) / 0.28)
  local gloss = unit(0.75 * peaks + 0.25 * localPeaks * (0.4 + 0.6 * peaks))
  gloss = gloss * (0.80 + 0.20 * unit(opacity or 1))
  value = mix(value, light, gloss * 0.70)
  local pigmentChroma = min(1.28, (value + 0.04) / (pigment + 0.04))
    * (1 - gloss * 0.82)
  local underlyingChroma = gloss * 0.44

  local function channel(swatch, base)
    local lit = value + (swatch / 255 - pigment) * pigmentChroma
      + (base / 255 - underlay) * underlyingChroma
    return byte(mix(swatch / 255, unit(lit), amount))
  end
  return channel(swatchR, baseR), channel(swatchG, baseG), channel(swatchB, baseB)
end

return Lighting
