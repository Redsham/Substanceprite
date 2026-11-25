local AO = require("lib.ambient_occlusion")
local CastShadow = require("lib.cast_shadow")
local Lighting = require("lib.material_lighting")

local SceneLighting = {}
local ceil, floor, min, max = math.ceil, math.floor, math.min, math.max

local function byte(value)
  return floor(max(0, min(255, value)) + 0.5)
end

local function strength(enabled, value, fallback, maximum)
  if not enabled then return 0 end
  value = tonumber(value)
  if not value or value ~= value then value = fallback end
  return max(0, min(100, value)) * maximum / 100
end

local function allowed(mask, index, x, y)
  if not mask then return true end
  local value
  if type(mask) == "function" then value = mask(x, y) else value = mask[index] end
  return value and value ~= 0
end

-- Treat the footprint as solid only where a separate normal-blend layer can
-- sit without increasing the composed sprite's transparency coverage.
local function opaqueSource(width, height, mask, read)
  local source = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local index = y * width + x + 1
      if allowed(mask, index, x, y) then
        local r, g, b, a = read(x, y)
        if r and g and b and (a == nil or a == 255) then
          source[index] = byte(r) | (byte(g) << 8) | (byte(b) << 16) | 0xff000000
        end
      end
    end
  end
  return source
end

local function minimumOpacity(source, target)
  if target > source then return (target - source) / (255 - source) end
  if target < source then return (source - target) / source end
  return 0
end

-- Invert normal source-over at the lowest usable alpha. Each channel can
-- lighten or darken independently while retaining the underlying pixel.
local function overlay(r, g, b, rr, gg, bb)
  rr, gg, bb = byte(rr), byte(gg), byte(bb)
  local amount = max(minimumOpacity(r, rr), minimumOpacity(g, gg), minimumOpacity(b, bb))
  local alpha = ceil(amount * 255)
  if alpha == 0 then return end
  local scale = 255 / alpha
  return byte(r + (rr - r) * scale) | (byte(g + (gg - g) * scale) << 8)
    | (byte(b + (bb - b) * scale) << 16) | (alpha << 24)
end

local function directShader(width, height, heights, settings, mask, rect)
  local direct = {}
  for key, value in pairs(settings) do direct[key] = value end
  direct.ao, direct.shadows = false, false
  return Lighting.shader(width, height, heights, direct, mask, rect)
end

function SceneLighting.map(width, height, heights, settings, mask, read, rect, channel)
  width, height = floor(width), floor(height)
  local footprint = opaqueSource(width, height, mask, read)
  return Lighting.map(width, height, heights, settings or {}, footprint, rect, channel)
end

-- Each sparse layer is indexed relative to rect. The optional diagnostic maps
-- are dense raw geometry, with intensity applied only to the overlay pixels.
function SceneLighting.render(width, height, heights, settings, mask, read, rect)
  width, height, settings = floor(width), floor(height), settings or {}
  rect = rect or { x = 0, y = 0, width = width, height = height }
  local out = { light = {}, ao = {}, shadows = {} }
  local outWidth, outHeight = floor(rect.width), floor(rect.height)
  if width < 1 or height < 1 or outWidth < 1 or outHeight < 1 or not Lighting.enabled(settings) then return out end

  local source = opaqueSource(width, height, mask, read)
  local shade = settings.directLight == true and directShader(width, height, heights, settings, source, rect)
  local aoStrength = strength(settings.ao == true, settings.aoStrength, AO.defaults.strength, AO.maxDarkening)
  local shadowStrength = strength(settings.shadows == true, settings.shadowStrength,
    CastShadow.defaults.strength, CastShadow.maxDarkening)
  if aoStrength > 0 then out.aoMap = Lighting.map(width, height, heights, settings, source, rect, Lighting.aoChannel) end
  if shadowStrength > 0 then
    out.shadowMap = Lighting.map(width, height, heights, settings, source, rect, Lighting.shadowChannel)
  end

  local originX, originY = floor(rect.x), floor(rect.y)
  local seamless = settings.seamless == true
  for v = 0, outHeight - 1 do
    for u = 0, outWidth - 1 do
      local x, y = originX + u, originY + v
      if seamless then x, y = x % width, y % height end
      if x >= 0 and x < width and y >= 0 and y < height then
        local pixel = source[y * width + x + 1]
        if pixel then
          local index = v * outWidth + u + 1
          if shade then
            local r, g, b = pixel & 255, (pixel >> 8) & 255, (pixel >> 16) & 255
            out.light[index] = overlay(r, g, b, shade(r, g, b, index))
          end
          local ao = out.aoMap and byte(out.aoMap[index] * aoStrength * 255) or 0
          local shadow = out.shadowMap and byte(out.shadowMap[index] * shadowStrength * 255) or 0
          if ao > 0 then out.ao[index] = ao << 24 end
          if shadow > 0 then out.shadows[index] = shadow << 24 end
        end
      end
    end
  end
  return out
end

return SceneLighting
