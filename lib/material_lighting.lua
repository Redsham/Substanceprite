local AO = require("lib.ambient_occlusion")
local CastShadow = require("lib.cast_shadow")
local Normal = require("lib.normal")

local Lighting = {}
Lighting.aoChannel = "Ambient Occlusion"
Lighting.shadowChannel = "Cast Shadows"
Lighting.defaults = { angle = 135, elevation = CastShadow.defaults.elevation, strength = 70 }

local min, max = math.min, math.max

local function value(raw, fallback, low, high)
  local n = tonumber(raw)
  if not n or n ~= n then return fallback end
  return max(low, min(high, n))
end

local function percent(raw, fallback)
  return value(raw, fallback, 0, 100) / 100
end

local function direction(settings)
  return math.rad(value(settings.lightAngle, Lighting.defaults.angle, 0, 360)),
    math.rad(value(settings.lightElevation or settings.shadowElevation, Lighting.defaults.elevation, 5, 85))
end

function Lighting.isMap(channel)
  return channel == Lighting.aoChannel or channel == Lighting.shadowChannel
end

function Lighting.map(width, height, heights, settings, mask, rect, channel)
  if channel == Lighting.aoChannel then
    return AO.generate(width, height, heights, { radius = settings.aoRadius, seamless = settings.seamless }, mask, rect)
  end
  local azimuth, elevation = direction(settings)
  return CastShadow.generate(width, height, heights, {
    angle = -math.deg(azimuth), elevation = math.deg(elevation), seamless = settings.seamless,
    reach = settings.shadowReach, softness = settings.shadowSoftness,
  }, mask, rect)
end

function Lighting.enabled(settings)
  return settings.directLight == true and percent(settings.lightStrength, Lighting.defaults.strength) > 0
    or settings.ao == true and percent(settings.aoStrength, AO.defaults.strength) > 0
    or settings.shadows == true and percent(settings.shadowStrength, CastShadow.defaults.strength) > 0
end

function Lighting.shader(width, height, heights, settings, mask, rect, forceDirect)
  local direct = (forceDirect or settings.directLight == true)
    and percent(settings.lightStrength, Lighting.defaults.strength) or 0
  local aoStrength = settings.ao == true and percent(settings.aoStrength, AO.defaults.strength) * AO.maxDarkening or 0
  local shadowStrength = settings.shadows == true
    and percent(settings.shadowStrength, CastShadow.defaults.strength) * CastShadow.maxDarkening or 0
  if direct == 0 and aoStrength == 0 and shadowStrength == 0 then return nil end

  local normals, ao, shadows
  local lx, ly, lz, tr, tg, tb, ta
  if direct > 0 then
    local azimuth, elevation = direction(settings)
    local horizontal = math.cos(elevation)
    lx, ly, lz = math.cos(azimuth) * horizontal, math.sin(azimuth) * horizontal, math.sin(elevation)
    local tint = settings.lightColor or {}
    tr, tg, tb = value(tint.r, 255, 0, 255) / 255, value(tint.g, 255, 0, 255) / 255, value(tint.b, 255, 0, 255) / 255
    ta = value(tint.a, 255, 0, 255) / 255
    normals = Normal.generate(width, height, heights, {
      strength = settings.normalStrength, smoothing = settings.smoothing, seamless = settings.seamless,
    }, mask, rect)
  end
  if aoStrength > 0 then ao = Lighting.map(width, height, heights, settings, mask, rect, Lighting.aoChannel) end
  if shadowStrength > 0 then
    shadows = Lighting.map(width, height, heights, settings, mask, rect, Lighting.shadowChannel)
  end

  return function(r, g, b, index)
    local light = 1
    if normals then
      local nr, ng, nb = Normal.rgb(normals[index])
      if nr then
        local nx, ny, nz = (nr - 128) / 127, (ng - 128) / 127, (nb - 128) / 127
        local incidence = max(0, nx * lx + ny * ly + nz * lz)
        if nr ~= 128 or ng ~= 128 then
          local delta = incidence - lz
          light = light + direct * delta * (delta < 0 and 0.84 or 0.65)
        end
        local colorMix = direct * incidence * ta * 0.42
        r, g, b = r * (1 - colorMix * (1 - tr)), g * (1 - colorMix * (1 - tg)), b * (1 - colorMix * (1 - tb))
      end
    end
    if ao then light = light * (1 - ao[index] * aoStrength) end
    if shadows then light = light * (1 - shadows[index] * shadowStrength) end
    return r * light, g * light, b * light
  end
end

return Lighting
