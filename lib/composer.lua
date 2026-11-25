local Material = require("lib.material")
local Surface = require("lib.surface")
local Texture = require("lib.texture")
local Effects = require("lib.effect_registry")
local Masks = require("lib.mask_registry")
local Lighting = require("lib.lighting")

local Composer = {}
Composer.kinds = { "Finish", "Deposits" }
Composer.masks = Masks.styles
Composer.emptyPixel = -1
Composer.defaultColors = Effects.defaultColors

local min, max, floor = math.min, math.max, math.floor

local function clamp(value, low, high)
  return min(high, max(low, value))
end

local function percent(value, default)
  value = tonumber(value)
  if not value or value ~= value then value = default end
  return clamp(value, 0, 100) / 100
end

local function byte(value)
  return floor(clamp(value, 0, 255) + 0.5)
end

local function mix(from, to, amount)
  return from + (to - from) * amount
end

function Composer.pack(r, g, b)
  return (byte(r) << 16) | (byte(g) << 8) | byte(b)
end

function Composer.rgb(pixel)
  if not pixel or pixel < 0 then return nil end
  return (pixel >> 16) & 255, (pixel >> 8) & 255, pixel & 255
end

function Composer.newLayer(kind, style)
  local finish = kind ~= "Deposits"
  style = style or (finish and Material.styles[1] or Texture.defaults.style)
  local profile = finish and Material.preset(style) or Effects.profile(style)
  local controls = not finish and Effects.controls(style)
  return {
    kind = finish and "Finish" or "Deposits", style = style, enabled = true,
    amount = finish and 100 or 55, mask = "Whole Surface",
    density = profile.density, scale = profile.scale, intensity = profile.intensity,
    clustering = profile.clustering,
    colors = not finish and Composer.defaultColors(style) or nil,
    lighting = not finish and Lighting.defaultMatch or nil,
    softness = controls and controls.softness or nil, runoff = controls and controls.runoff or nil,
    trails = controls and controls.trails or nil,
  }
end

function Composer.paletteRange(width, height, mask, baseReader)
  local bins, count = {}, 0
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      if not mask or mask[y * width + x + 1] then
        local r, g, b, alpha = baseReader(x, y)
        if r ~= nil and (alpha == nil or alpha > 0) then
          local level = byte(Surface.luminance(r, g, b) * 255)
          bins[level] = (bins[level] or 0) + 1
          count = count + 1
        end
      end
    end
  end
  if count == 0 then return nil end

  local first = floor((count - 1) * 0.05 + 0.5) + 1
  local last = floor((count - 1) * 0.95 + 0.5) + 1
  local low, accumulated = nil, 0
  for level = 0, 255 do
    accumulated = accumulated + (bins[level] or 0)
    if not low and accumulated >= first then low = level end
    if accumulated >= last then return { low = low, high = level } end
  end
end

local function paletteLookup(palette, range)
  local stops = {}
  for i, color in ipairs(palette) do
    stops[#stops + 1] = {
      order = i,
      luma = Surface.luminance(color.r, color.g, color.b),
      r = color.r, g = color.g, b = color.b,
    }
  end
  if #stops == 0 then return nil end
  table.sort(stops, function(a, b)
    if a.luma == b.luma then return a.order < b.order end
    return a.luma < b.luma
  end)
  if #stops == 1 and range then
    local colors = {}
    for level = 0, 255 do colors[level] = stops[1] end
    return colors
  end
  if not range then
    if stops[1].luma > 0 then table.insert(stops, 1, { luma = 0, r = 0, g = 0, b = 0 }) end
    if stops[#stops].luma < 1 then stops[#stops + 1] = { luma = 1, r = 255, g = 255, b = 255 } end
  end

  local low, high = stops[1].luma, stops[#stops].luma
  local colors, stop = {}, 1
  for level = 0, 255 do
    local luma = level / 255
    if range then
      local amount = range.high <= range.low and 0.5 or clamp((level - range.low) / (range.high - range.low), 0, 1)
      luma = mix(low, high, amount)
    end
    while stop < #stops - 1 and stops[stop + 1].luma <= luma do stop = stop + 1 end
    local a, b = stops[stop], stops[stop + 1]
    local amount = b.luma == a.luma and 0 or (luma - a.luma) / (b.luma - a.luma)
    colors[level] = {
      r = mix(a.r, b.r, amount), g = mix(a.g, b.g, amount), b = mix(a.b, b.b, amount),
    }
  end
  return colors
end

local function compileLayers(width, height, options, mask, rect, stages)
  local layers = {}
  local paletteAmount = percent(options.paletteAmount, 100)
  if options.palette and paletteAmount > 0 then
    local palette = paletteLookup(options.palette, options.paletteRange)
    if palette then
      local layer = { palette = palette, amount = paletteAmount, kind = "Palette" }
      if stages then
        layer.stage = { name = options.paletteName or "Material Palette", kind = "Palette", index = 0, pixels = {} }
        stages[#stages + 1] = layer.stage
      end
      layers[#layers + 1] = layer
    end
  end

  for index, settings in ipairs(options.layers or {}) do
    local finish = settings.kind == "Finish"
    local effect = settings.kind == "Deposits" and Effects.get(settings.style)
    local soft = effect and Effects.controls(settings.style)
    local amount = percent(settings.amount, 100)
    local placement = settings.mask or "Whole Surface"
    local visible = settings.enabled ~= false and amount > 0
    local maskType = Masks.get(placement)
    if visible and (finish or effect) and maskType and (not maskType.requiresHeight or options.heights) then
      local params = {
        style = settings.style, seed = settings.seed or options.seed or 1,
        seamless = options.seamless == true,
        density = settings.density, scale = settings.scale, intensity = settings.intensity,
        clustering = settings.clustering, edge = settings.edge, bottom = settings.bottom,
        direction = settings.direction, form = settings.form,
        softness = settings.softness, runoff = settings.runoff, trails = settings.trails,
      }
      if options.heights and (settings.surfaceStrength or soft) then
        local reliefPlacement = placement == "Recesses" or placement == "Ridges" or placement == "Slopes"
        params.surface = {
          heights = options.heights, strength = settings.surfaceStrength or (soft and soft.surfaceStrength) or 0,
          placement = reliefPlacement and placement or "Material",
        }
      end
      local generate = finish and Material.generate or Effects.generator(settings.style)
      local layer = {
        kind = settings.kind, amount = amount, style = settings.style,
        samples = generate(width, height, params, mask, rect),
      }
      if finish then
        layer.shade = Material.shader(params)
      else
        layer.lighting = tonumber(settings.lighting) or Lighting.defaultMatch
        local colors = Composer.defaultColors(settings.style)
        for level, color in ipairs(settings.colors or {}) do
          colors[level] = color
        end
        layer.deposit = Effects.sampler(settings.style, colors)
      end
      layer.guide = Masks.sampler(placement, width, height, options, mask, settings)
      layer.directMask = maskType.direct == true
      if placement ~= "Painted Mask" and options.masks and options.masks[settings.id] then
        layer.painted = Masks.sampler("Painted Mask", width, height, options, mask, settings)
      end
      if stages then
        layer.stage = {
          name = settings.name or settings.style or settings.kind,
          kind = settings.kind, index = index, pixels = {},
        }
        stages[#stages + 1] = layer.stage
      end
      layers[#layers + 1] = layer
    end
  end
  return layers
end

local function process(layer, index, x, y, r, g, b, height, context)
  local opacity = layer.amount
  if layer.palette then
    local color = layer.palette[byte(Surface.luminance(r, g, b) * 255)]
    return mix(r, color.r, opacity), mix(g, color.g, opacity), mix(b, color.b, opacity), height
  end
  local sample = layer.samples[index]
  if not sample or sample == 0 then return r, g, b, height end

  if layer.painted then opacity = opacity * layer.painted(x, y) end
  if layer.guide then
    local coverage = layer.guide(x, y) or 0
    if layer.directMask then
      opacity = opacity * clamp(coverage, 0, 1)
    else
      local weight = clamp(coverage * 1.8, 0, 1)
      opacity = opacity * weight * weight * (3 - 2 * weight)
    end
  end
  if opacity == 0 then return r, g, b, height end

  local outR, outG, outB
  if layer.shade then
    outR, outG, outB = layer.shade(byte(r), byte(g), byte(b), sample)
    if height then
      local detail = (((sample >> 24) & 255) - 128) / 127
      local form = (((sample >> 8) & 255) - 128) / 127
      local gain = (sample & 255) / 255
      height = height + (0.085 * detail + 0.20 * form) * gain * opacity
    end
  else
    local alpha, relief
    outR, outG, outB, alpha, relief = layer.deposit(sample)
    if not outR then return r, g, b, height end
    if height then height = height + (relief or 0) * opacity end
    opacity = opacity * alpha / 255
    if context and layer.lighting > 0 and opacity > 0 then
      outR, outG, outB = Lighting.tint(outR, outG, outB, r, g, b, opacity, context, layer.lighting)
    end
  end
  return mix(r, outR, opacity), mix(g, outG, opacity), mix(b, outB, opacity), height
end

-- The base reader samples 0-based coordinates in the full target. Any crop
-- and optional captured stages use the same output-relative row-major order.
function Composer.render(width, height, options, mask, rect, baseReader)
  width, height = floor(width), floor(height)
  options = options or {}
  rect = rect or { x = 0, y = 0, width = width, height = height }
  local outWidth, outHeight = floor(rect.width), floor(rect.height)
  local outX, outY = floor(rect.x), floor(rect.y)
  local pixels = {}
  local stages = options.captureLayers and {} or nil
  local relief = options.captureRelief and {} or nil
  local details = (stages or relief) and { stages = stages, heights = relief } or nil
  if outWidth < 1 or outHeight < 1 then return pixels, details end

  local layers = compileLayers(width, height, options, mask, rect, stages)
  local lightAt
  for _, layer in ipairs(layers) do
    if layer.lighting and layer.lighting > 0 then
      lightAt = Lighting.sampler(width, height, baseReader, mask, options.seamless)
      break
    end
  end
  local index = 1
  for row = 0, outHeight - 1 do
    local y = outY + row
    if options.seamless and height > 0 then y = y % height end
    for column = 0, outWidth - 1 do
      local x = outX + column
      if options.seamless and width > 0 then x = x % width end
      local baseIndex = y * width + x + 1
      local value = Composer.emptyPixel
      local r, g, b, alpha
      if x >= 0 and y >= 0 and x < width and y < height and (not mask or mask[baseIndex]) then
        r, g, b, alpha = baseReader(x, y)
      end
      if r ~= nil and (alpha == nil or alpha > 0) then
        local depth
        if relief then depth = options.heights and options.heights[baseIndex] or 0.5 end
        local context = lightAt and lightAt(x, y)
        for _, layer in ipairs(layers) do
          r, g, b, depth = process(layer, index, x, y, r, g, b, depth, context)
          if layer.stage then layer.stage.pixels[index] = Composer.pack(r, g, b) end
        end
        value = Composer.pack(r, g, b)
        if relief then relief[index] = clamp(depth, 0, 1) end
      elseif stages then
        for _, stage in ipairs(stages) do stage.pixels[index] = Composer.emptyPixel end
      end
      pixels[index] = value
      index = index + 1
    end
  end
  return pixels, details
end

return Composer
