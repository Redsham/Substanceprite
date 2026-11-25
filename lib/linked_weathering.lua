local Chips = require("lib.chips")
local Lighting = require("lib.lighting")
local Streaks = require("lib.streaks")

local Linked = {}
local floor, min, max = math.floor, math.min, math.max
local defaultTone = 128

local function byte(value)
  return floor(max(0, min(255, value)) + 0.5)
end

local function pixel(r, g, b, a)
  return (a << 24) | (byte(b) << 16) | (byte(g) << 8) | byte(r)
end

local function allows(mask, index, x, y)
  if not mask then return true end
  local value
  if type(mask) == "function" then
    value = mask(x, y)
  else
    value = mask[index]
  end
  return value and value ~= 0
end

local function stageOpacity(params, stage)
  if params.enabled and params.enabled[stage] == false then return 0 end
  return byte(params.opacity and params.opacity[stage] or 255) / 255
end

local function toneAt(tones, index)
  local tone = tones and tones[index] or 0
  if tone > 0 then return tone end
  return defaultTone
end

function Linked.generate(width, height, params, mask)
  width, height = floor(width), floor(height)
  local options = {}
  for key, value in pairs(params or {}) do options[key] = value end
  options.trails = 0

  local footprint = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local index = y * width + x + 1
      if allows(mask, index, x, y) then footprint[index] = true end
    end
  end

  local chips, rust, trails, tones = {}, {}, {}, {}
  local geometry = Chips.generate(width, height, options, footprint)
  for index, sample in ipairs(geometry) do
    local coverage = sample & 255
    chips[index] = coverage
    rust[index] = (sample >> 16) & 255
    -- White permits a stain to appear here if later mask edits route it here.
    trails[index] = footprint[index] and 255 or 0
    tones[index] = coverage > 0 and max(1, (sample >> 8) & 255) or 0
  end
  return { chips = chips, rust = rust, trails = trails, tones = tones }
end

function Linked.render(width, height, params, mask, baseReader, masks, tones)
  width, height = floor(width), floor(height)
  params = params or {}
  local chips, rust, trails = {}, {}, {}
  local output = { chips = chips, rust = rust, trails = trails }
  if width < 1 or height < 1 then return output end

  local base, footprint = {}, {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local index = y * width + x + 1
      if allows(mask, index, x, y) then
        local r, g, b, a = baseReader(x, y)
        if r and g and b and a ~= 0 then
          base[index] = pixel(r, g, b, a or 255)
          footprint[index] = true
        end
      end
    end
  end

  local function readBase(x, y)
    local value = base[y * width + x + 1]
    if value then return value & 255, (value >> 8) & 255, (value >> 16) & 255, value >> 24 end
  end

  local seamless = params.seamless == true
  local contextAt = Lighting.sampler(width, height, readBase, footprint, seamless)
  -- The host applies each layer's opacity. Mask coverage uses it only when a
  -- downstream layer depends on the amount of visible underlying material.
  local chipOpacity = stageOpacity(params, "chips")
  local rustOpacity = stageOpacity(params, "rust")
  local chipMask, rustMask, trailMask = masks.chips, masks.rust, masks.trails
  local surface = type(params.surface) == "table" and params.surface or nil
  local function oxideAt(x, y)
    local index = y * width + x + 1
    local source = base[index]
    if not source then return 0 end
    local alpha, coverage, oxide = source >> 24, chipMask[index] or 0, rustMask[index] or 0
    local mass = alpha * coverage * oxide * chipOpacity * rustOpacity / 255^3
    local tone = toneAt(tones, index) / 255
    return mass, tone * 0.84 + 0.06
  end

  local stainAt
  if chipOpacity > 0 and rustOpacity > 0 and (tonumber(params.runoff) or Chips.defaults.runoff) > 0 then
    stainAt = Streaks.sampler(width, height, surface and surface.heights, footprint, seamless,
      oxideAt, { strength = params.trails, scale = params.scale, seed = params.seed })
  end

  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local index = y * width + x + 1
      chips[index], rust[index], trails[index] = 0, 0, 0
      local baseR, baseG, baseB, baseA = readBase(x, y)
      if baseR then
        local coverage = chipMask[index] or 0
        if coverage > 0 then
          local tone = toneAt(tones, index)
          local steelR, steelG, steelB, steelA = Chips.sample((tone << 8) | coverage, params.colors)
          local context = contextAt(x, y)
          local receiveR, receiveG, receiveB = baseR, baseG, baseB
          if steelR then
            local alpha = byte(steelA * baseA / 255)
            steelR, steelG, steelB = Lighting.tint(steelR, steelG, steelB, baseR, baseG, baseB,
              alpha * chipOpacity / 255, context, params.lighting)
            if alpha > 0 then chips[index] = pixel(steelR, steelG, steelB, alpha) end

            local steel = chipOpacity * alpha / 255
            local share = steel / (steel + (1 - steel) * baseA / 255)
            receiveR = baseR + (steelR - baseR) * share
            receiveG = baseG + (steelG - baseG) * share
            receiveB = baseB + (steelB - baseB) * share
          end

          local oxide = rustMask[index] or 0
          local rustAlpha = byte(oxide * coverage * baseA * chipOpacity / 255^2)
          if rustAlpha > 0 then
            local opaqueOxide = (255 << 16) | (tone << 8) | 255
            local r, g, b = Chips.sample(opaqueOxide)
            r, g, b = Lighting.tint(r, g, b, receiveR, receiveG, receiveB,
              rustAlpha * rustOpacity / 255, context, params.lighting)
            rust[index] = pixel(r, g, b, rustAlpha)
          end
        elseif stainAt and (trailMask[index] or 0) > 0 then
          local amount, tone = stainAt(x, y)
          local alpha = byte(amount * trailMask[index] * baseA / 255)
          if alpha > 0 then
            local r, g, b = Chips.sample((byte(tone * 255) << 40) | (alpha << 32))
            r, g, b = Lighting.tint(r, g, b, baseR, baseG, baseB,
              alpha / 255, contextAt(x, y), params.lighting)
            trails[index] = pixel(r, g, b, alpha)
          end
        end
      end
    end
  end
  return output
end

return Linked
