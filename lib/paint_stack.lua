local Chips = require("lib.chips")
local Effects = require("lib.effect_registry")
local Lighting = require("lib.lighting")
local Linked = require("lib.linked_weathering")
local Colors = require("lib.paint_colors")
local Wear = require("lib.paint_wear")
local Rain = require("lib.rain")
local Streaks = require("lib.streaks")
local Surface = require("lib.surface")
local Texture = require("lib.texture")

local Paint = {}
Paint.defaults = {
  color = {r = 99, g = 124, b = 102, a = 255},
  palette = {},
  opacity = 100, chips = 38, corrosion = 68, trails = 0, dirt = 0, moss = 0, soot = 0,
  edgeWear = Wear.defaults.edgeWear, edgeWidth = Wear.defaults.edgeWidth,
  bevelWear = Wear.defaults.bevelWear, bevelWidth = Wear.defaults.bevelWidth,
  scuffs = Wear.defaults.scuffs, scuffDirection = Wear.defaults.scuffDirection,
  fading = Wear.defaults.fading,
  rainStrength = Rain.defaults.intensity, rainDuration = Rain.defaults.duration,
  seed = 1, seamless = false,
}

Paint.newWear = { chips = 32, edgeWear = 46, scuffs = 29, fading = 24, corrosion = 73 }

local floor, min, max = math.floor, math.min, math.max
local stages = {
  {key = "dirt", style = "Dirt", seedOffset = 473, edge = 6, bottom = 32, scale = 5},
  {key = "moss", style = "Moss", seedOffset = 977, edge = 22, bottom = 12, scale = 4},
  {key = "soot", style = "Soot", seedOffset = 217, edge = 7, bottom = 0, scale = 5},
}

local function clamp(value, low, high)
  return max(low, min(high, value))
end

local function number(value, fallback, low, high)
  value = tonumber(value)
  if not value or value ~= value then value = fallback end
  return clamp(value, low, high)
end

local function percent(options, field)
  return number(options[field], Paint.defaults[field], 0, 100) / 100
end

local function byte(value)
  return floor(clamp(value, 0, 255) + 0.5)
end

local function pixel(r, g, b, a)
  return (byte(a) << 24) | (byte(b) << 16) | (byte(g) << 8) | byte(r)
end

local function rgba(packed)
  return packed & 255, (packed >> 8) & 255, (packed >> 16) & 255, packed >> 24
end

local function allows(mask, index, x, y)
  if not mask then return true end
  local value
  if type(mask) == "function" then value = mask(x, y) else value = mask[index] end
  return value and value ~= 0
end

local function seedFor(options, offset)
  local seed = floor(number(options.seed, Paint.defaults.seed, -2147483648, 4294967295))
  return (seed + (offset or 0)) & 0xffffffff
end

local function surfaceFor(options)
  if type(options.surface) == "table" then return options.surface end
  if type(options.heights) == "table" then
    return {heights = options.heights, strength = 62, placement = "Material"}
  end
end

local function permission(masks, stage, index)
  local mask = masks and masks[stage]
  return mask and number(mask[index], 0, 0, 255) / 255 or 1
end

local function tintFrom(color)
  local swatchR, swatchG, swatchB = number(color.r, 0, 0, 255),
    number(color.g, 0, 0, 255), number(color.b, 0, 0, 255)
  local swatch = Surface.luminance(swatchR, swatchG, swatchB)
  local dr, dg, db = swatchR / 255 - swatch, swatchG / 255 - swatch, swatchB / 255 - swatch
  local dark, light = min(dr, dg, db), max(dr, dg, db)
  local bias = (swatch - 0.5) * 0.45
  -- The tone curve is monotonic and keeps both endpoints. Chroma is reduced
  -- only where necessary to fit saturated swatches into the destination gamut.
  return function(r, g, b)
    local source = Surface.luminance(r, g, b)
    local value = source + bias * 4 * source * (1 - source)
    local saturation = 1
    if dark < 0 then saturation = min(saturation, value / -dark) end
    if light > 0 then saturation = min(saturation, (1 - value) / light) end
    return (value + dr * saturation) * 255, (value + dg * saturation) * 255,
      (value + db * saturation) * 255
  end
end

local function chipCoverage(metal, index)
  return number(metal[index], 0, 0, 255) / 255
end

function Paint.generate(width, height, params, mask)
  params = params or {}
  local controls = {
    density = percent(params, "chips") * 100, intensity = 100, edge = 30,
    seed = seedFor(params), seamless = params.seamless == true, surface = surfaceFor(params),
    runoff = 100,
  }
  local generated = Linked.generate(width, height, controls, mask)
  if percent(params, "edgeWear") == 0 and percent(params, "bevelWear") == 0 and percent(params, "scuffs") == 0
      and percent(params, "fading") == 0 then
    return generated
  end
  local wear = Wear.generate(width, height, params, mask)
  generated.wear = wear
  if percent(params, "edgeWear") > 0 then
    generated.unwornChips, generated.chips = generated.chips, {}
    for i, chip in ipairs(generated.unwornChips) do
      generated.chips[i] = byte(chip + (255 - chip) * (wear.edge[i] or 0) / 255)
    end
  end
  return generated
end

local function layerVariant(width, height, params, surface, footprint, stage, strength)
  if strength == 0 then return nil end
  return Effects.generator(stage.style)(width, height, {
    style = stage.style, seed = seedFor(params, stage.seedOffset), seamless = params.seamless == true,
    scale = stage.scale, density = 24 + strength * 76, intensity = 72,
    clustering = 67, edge = stage.edge, bottom = stage.bottom, surface = surface,
  }, footprint)
end

local function mixed(r, g, b, packed)
  if not packed then return r, g, b end
  local br, bg, bb, ba = rgba(packed)
  local share = ba / 255
  return r + (br - r) * share, g + (bg - g) * share, b + (bb - b) * share
end

local function rampSegment(position)
  position = clamp(position, 0, 1) * 2
  local index = position < 1 and 1 or 2
  return index, position - index + 1
end

local function paintRamp(ramp, r, g, b)
  local i, t = rampSegment(Surface.luminance(r, g, b))
  local a, z = ramp[i], ramp[i + 1]
  return a.r + (z.r - a.r) * t, a.g + (z.g - a.g) * t,
    a.b + (z.b - a.b) * t, (a.a + (z.a - a.a) * t) / 255
end

local function wearOverlay(index, amount, tones, layer, paintAlpha, masks, key, light, r, g, b)
  if not layer then return nil end
  local tone = tones and tones[index] or 128
  local strength = (amount[index] or 0) / 255
  local coverage = paintAlpha * strength * permission(masks, key, index)
  if coverage < 0.5 then return nil end
  local shade = (tone - 128) / 255 * 20
  local i, t = rampSegment(light * 0.73 + tone / 255 * 0.27)
  local a, z = layer[i], layer[i + 1]
  local alpha = byte(coverage * (a.alpha + (z.alpha - a.alpha) * t))
  if alpha == 0 then return nil end
  local nr, ng, nb = a.tint(r + shade, g + shade, b + shade)
  local zr, zg, zb = z.tint(r + shade, g + shade, b + shade)
  return pixel(nr + (zr - nr) * t, ng + (zg - ng) * t, nb + (zb - nb) * t, alpha)
end

local function wearLayer(color)
  return {alpha = color.a / 255, tint = tintFrom(color)}
end

local function wearRamp(palette, id)
  local ramp = Colors.get(palette, id)
  return { wearLayer(ramp[1]), wearLayer(ramp[2]), wearLayer(ramp[3]) }
end

local function primerField(width, height, metal, footprint, seamless)
  local field = {}
  local function exposed(x, y)
    if seamless then x, y = x % width, y % height end
    if x < 0 or y < 0 or x >= width or y >= height then return 0 end
    local i = y * width + x + 1
    return footprint[i] and chipCoverage(metal, i) or 0
  end
  for i in pairs(footprint) do
    local x, y = (i - 1) % width, (i - 1) // width
    local localExposure = chipCoverage(metal, i)
    local adjacent = max(exposed(x - 1, y), exposed(x + 1, y), exposed(x, y - 1), exposed(x, y + 1))
    local thinning = 3.6 * localExposure * (1 - localExposure)
    local lip = max(0, adjacent - localExposure - 0.28) * 0.19
    field[i] = byte(255 * (thinning + lip))
  end
  return field
end

local function layDeposits(width, height, params, surface, footprint, base, waterAt, output)
  for _, stage in ipairs(stages) do
    local key = stage.key
    local strength = percent(params, key)
    local field = layerVariant(width, height, params, surface, footprint, stage, strength)
    if field then
      local sample = Effects.sampler(stage.style, Colors.get(params.palette, key))
      local heights = output.relief[key]
      for i, source in pairs(base) do
        if (field[i] or 0) > 0 then
          local r, g, b, sampleAlpha, relief = sample(field[i])
          local wet = 1
          if waterAt and heights then
            local flow, retained = waterAt((i - 1) % width, (i - 1) // width)
            wet = key == "moss" and (0.35 + 1.35 * retained) or (0.55 + 1.05 * flow)
          end
          local alpha = byte((sampleAlpha or 0) * strength * (source >> 24) / 255 * wet
            * permission(params.effectMasks, key, i))
          if alpha > 0 then
            output[key][i] = pixel(r, g, b, alpha)
            -- Relief from the sampler already includes its pigment alpha.
            if heights and relief then heights[i] = relief * alpha / sampleAlpha end
          end
        end
      end
    end
  end
end

local function withDeposits(heights, relief, opacity, base)
  local dirt = number(opacity and opacity.dirt, 1, 0, 1)
  local moss = number(opacity and opacity.moss, 1, 0, 1)
  if (dirt == 0 or not next(relief.dirt)) and (moss == 0 or not next(relief.moss)) then return heights end
  local terrain = {}
  for i, source in pairs(base) do
    local height = heights and heights[i]
    local lift = dirt * (relief.dirt[i] or 0) + moss * (relief.moss[i] or 0)
    if lift > 0 then height = min(1, (height or Surface.luminance(rgba(source))) + lift) end
    terrain[i] = height
  end
  return terrain
end

local function shadeDeposits(base, output, width, context)
  for _, stage in ipairs(stages) do
    local key = stage.key
    for i, deposit in pairs(output[key]) do
      local dr, dg, db, alpha = rgba(deposit)
      local r, g, b = rgba(base[i])
      r, g, b = mixed(r, g, b, output.metal[i])
      r, g, b = mixed(r, g, b, output.paint[i])
      r, g, b = mixed(r, g, b, output.primer[i])
      r, g, b = mixed(r, g, b, output.fading[i])
      r, g, b = mixed(r, g, b, output.scuff[i])
      r, g, b = mixed(r, g, b, output.rust[i])
      r, g, b = mixed(r, g, b, output.trails[i])
      if key ~= "dirt" then r, g, b = mixed(r, g, b, output.dirt[i]) end
      if key == "soot" then r, g, b = mixed(r, g, b, output.moss[i]) end
      local x, y = (i - 1) % width, (i - 1) // width
      dr, dg, db = Lighting.tint(dr, dg, db, r, g, b, alpha / 255, context(x, y), 75)
      output[key][i] = pixel(dr, dg, db, alpha)
    end
  end
end

function Paint.render(width, height, params, mask, baseReader, generated, chipMask)
  params = params or {}
  local output = {metal = {}, paint = {}, bevel = {}, primer = {}, fading = {}, scuff = {}, rust = {},
    trails = {}, dirt = {}, moss = {}, soot = {}, relief = {dirt = {}, moss = {}}}
  if width < 1 or height < 1 then return output end

  local base, footprint = {}, {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local i = y * width + x + 1
      if allows(mask, i, x, y) then
        local r, g, b, a = baseReader(x, y)
        if r and g and b and (a == nil or a > 0) then
          base[i], footprint[i] = pixel(r, g, b, a or 255), true
        end
      end
    end
  end
  if not next(footprint) then return output end

  local function baseAt(x, y)
    local packed = base[y * width + x + 1]
    if packed then return rgba(packed) end
  end

  generated = generated or Paint.generate(width, height, params, footprint)
  local metal = chipMask or generated.chips
  local wear = generated.wear
  local bevel = wear and percent(params, "bevelWear") > 0 and wear.bevel
  local palette = type(params.palette) == "table" and params.palette or {}
  local metalTint = palette.metal and wearLayer(Colors.get(palette, "metal"))
  local fadingTint = wear and percent(params, "fading") > 0 and wearRamp(palette, "fading")
  local scuffTint = wear and percent(params, "scuffs") > 0 and wearRamp(palette, "scuff")
  local primer = (palette.primer or percent(params, "edgeWear") > 0)
    and primerField(width, height, metal, footprint, params.seamless == true)
  local primerTint = primer and wearRamp(palette, "primer")
  local coatRamp = palette.paint and Colors.get(palette, "paint")
  local pigment = Colors.get(palette, "rust")
  local trailPigment = palette.trails and Colors.get(palette, "trails")
  local surface = surfaceFor(params)
  local heights = surface and surface.heights
  local trails = percent(params, "trails")
  local rainStrength, rainDuration = percent(params, "rainStrength"), percent(params, "rainDuration")
  local seamless = params.seamless == true
  local function storm(terrain)
    return Rain.sampler(width, height, terrain, seamless, footprint, {
      intensity = rainStrength * 100, duration = rainDuration * 100, wrapY = false, contour = true,
    })
  end
  local baseWaterAt, baseRouteAt
  local configuredRain = params.rainStrength ~= nil or params.rainDuration ~= nil
  if configuredRain and (params.captureRain or trails > 0 or percent(params, "dirt") > 0 or percent(params, "moss") > 0) then
    baseWaterAt, baseRouteAt = storm(heights)
  end
  -- Close the accumulation step before rerouting the runoff over it.
  layDeposits(width, height, params, surface, footprint, base, baseWaterAt, output)
  local terrain = withDeposits(heights, output.relief, params.depositOpacity, base)
  output.weatherHeights = terrain
  local waterAt, routeAt = baseWaterAt, baseRouteAt
  if terrain ~= heights and (configuredRain or trails > 0 or params.captureRain) then
    waterAt, routeAt = storm(terrain)
  end
  local bevelWaterAt, bevelRouteAt = waterAt, routeAt
  local bevelFeedsRunoff = false
  local stormAge = rainStrength > 0 and rainDuration ^ 0.55 or 0
  local masks, rustAt = params.effectMasks, params.rustAt
  local sourceColor = params.color or Paint.defaults.color
  local coat = percent(params, "opacity") * number(sourceColor.a, 255, 0, 255) / 255
  local corrosion = percent(params, "corrosion")
  local tint = tintFrom(sourceColor)
  local context = Lighting.sampler(width, height, baseAt, footprint, params.seamless == true)
  local rustNotes = {}
  local chipRustField, bevelRustField
  local function rustField(guide)
    return Effects.generator("Rust")(width, height, {
      style = "Rust", density = 88, scale = 4, intensity = 64,
      seed = seedFor(params, 235), seamless = params.seamless == true, surface = guide,
    }, footprint)
  end

  if coat > 0 then
    for i, source in pairs(base) do
      local r, g, b, alpha = rgba(source)
      local chips = chipCoverage(metal, i)
      local bevelShare = 0
      if bevel and (bevel[i] or 0) > 0 then
        local exposed = byte(bevel[i] * permission(masks, "bevel", i))
        if exposed > 0 then
          output.bevel[i] = exposed
          bevelShare = (1 - chips) * exposed / 255
        end
      end
      local coverage = chips + bevelShare
      local paintAlpha = byte(alpha * coat * (1 - coverage))
      if metalTint and coverage > 0 and paintAlpha < 255 then
        -- Metal is under paint: compensate for the fraction the paint still covers.
        local metalAlpha = byte(alpha * coat * coverage * metalTint.alpha / (1 - paintAlpha / 255))
        if metalAlpha > 0 then
          local mr, mg, mb = metalTint.tint(r, g, b)
          output.metal[i] = pixel(mr, mg, mb, metalAlpha)
        end
      end
      if paintAlpha > 0 then
        local light = Surface.luminance(r, g, b)
        local pr, pg, pb, pigmentAlpha
        if coatRamp then
          pr, pg, pb, pigmentAlpha = paintRamp(coatRamp, r, g, b)
          paintAlpha = byte(paintAlpha * pigmentAlpha)
        else
          pr, pg, pb = tint(r, g, b)
        end
        if paintAlpha > 0 then output.paint[i] = pixel(pr, pg, pb, paintAlpha) end
        if primer then
          output.primer[i] = wearOverlay(i, primer, nil, primerTint, paintAlpha,
            masks, "primer", light, pr, pg, pb)
          pr, pg, pb = mixed(pr, pg, pb, output.primer[i])
        end
        if wear then
          output.fading[i] = wearOverlay(i, wear.fading, wear.fadingTones, fadingTint, paintAlpha,
            masks, "fading", light, pr, pg, pb)
          pr, pg, pb = mixed(pr, pg, pb, output.fading[i])
          output.scuff[i] = wearOverlay(i, wear.scuff, wear.scuffTones, scuffTint, paintAlpha,
            masks, "scuff", light, pr, pg, pb)
        end
      end

      local oxidizable = chips + (stormAge > 0 and bevelShare or 0)
      local rustAmount = oxidizable * coat * corrosion * permission(masks, "rust", i)
      if rustAmount > 0 then
        r, g, b = mixed(r, g, b, output.metal[i])
        local x, y = (i - 1) % width, (i - 1) // width
        local oxide = (generated.rust[i] or 0) / 255
        local tone = generated.tones[i] or 0
        if chips > chipCoverage(generated.unwornChips or generated.chips, i) then
          -- Authored exposures can oxidize anywhere. Rubbing along a rim
          -- produces smaller amounts so freshly polished metal still reads.
          chipRustField = chipRustField or rustField(surface)
          local sample = chipRustField[i] or 0
          local aged, rustTone = (sample & 255) / 255, (sample >> 8) & 255
          local authored = chips > chipCoverage(generated.chips, i)
          local extra = authored and (0.40 + 0.60 * aged) or (0.13 + 0.56 * aged)
          oxide, tone = max(oxide, extra), rustTone > 0 and rustTone or max(tone, 96)
        end
        local savedR, savedG, savedB, savedAlpha
        if rustAt then savedR, savedG, savedB, savedAlpha = rustAt(x, y) end
        local savedCoverage = savedR and number(savedAlpha, 255, 0, 255) / 255 or 0
        local chipWeight = chips / oxidizable
        local remembered = savedCoverage * chipWeight
        local added = oxide * (1 - savedCoverage) * chipWeight
        local bevelOxide = 0
        if bevelShare > 0 and stormAge > 0 then
          if not bevelWaterAt then bevelWaterAt, bevelRouteAt = storm(terrain) end
          local flow, retained, exposure = bevelWaterAt(x, y)
          -- A passing film contributes less than water held against a lip.
          local wetness = stormAge * min(1, 2.65 * retained + 0.74 * flow + 0.32 * exposure * rainStrength)
          if wetness > 0 then
            -- Use grain without cavity bias. Water already accounts for the shape.
            bevelRustField = bevelRustField or rustField()
            local sample = bevelRustField[i] or 0
            local crust, rustTone = (sample & 255) / 255, (sample >> 8) & 255
            local patch = clamp((crust - 0.13 + 0.16 * wetness) * 2.75, 0, 1)
            bevelOxide = bevelShare / oxidizable * wetness * patch * 0.92
            if bevelOxide > 0 then
              tone = byte((added * tone + bevelOxide * rustTone) / (added + bevelOxide))
              added = added + bevelOxide
            end
          end
        end
        local rr, gg, bb, pigmentAlpha = Texture.softDepositSample((tone << 8) | 255, pigment)
        if palette.rust then
          added = added * (pigmentAlpha or 0) / 255
          if remembered > 0 then
            local savedTone = byte(Surface.luminance(savedR, savedG, savedB) * 255)
            local savedPigment
            savedR, savedG, savedB, savedPigment = Texture.softDepositSample((savedTone << 8) | 255, pigment)
            remembered = remembered * (savedPigment or 0) / 255
          end
        end
        local total = added + remembered
        local rustAlpha = byte(alpha * rustAmount * total)
        if rustAlpha > 0 then
          if added > 0 then
            rr, gg, bb = Lighting.tint(rr, gg, bb, r, g, b, rustAlpha / 255, context(x, y), 65)
            if remembered > 0 then
              local share = remembered / total
              rr, gg, bb = rr + (savedR - rr) * share, gg + (savedG - gg) * share,
                bb + (savedB - bb) * share
            end
          else
            rr, gg, bb = savedR, savedG, savedB
          end
          output.rust[i] = pixel(rr, gg, bb, rustAlpha)
          rustNotes[i] = (0.55 * tone / 255) + 0.27
          bevelFeedsRunoff = bevelFeedsRunoff or bevelOxide > 0
        end
      end
    end
  end

  local runoffWater = waterAt or (bevelFeedsRunoff and bevelWaterAt)
  local runoffRoutes = routeAt or (bevelFeedsRunoff and bevelRouteAt)
  local function dissolvedRust(water, x, y)
    local i = y * width + x + 1
    local oxide = ((output.rust[i] or 0) >> 24) / 255
    if water and oxide > 0 then
      local flow, retained, exposure = water(x, y)
      local washed = max(flow, retained * 0.72, exposure * rainStrength * 0.36)
      oxide = oxide * (1 - (1 - washed)^2.8)
    end
    return oxide, rustNotes[i]
  end
  if next(output.rust) and trails > 0 and (not runoffWater or rainStrength * rainDuration > 0) then
    local visibility = runoffWater and (0.58 + 0.42 * rainStrength ^ 0.72) or 1
    local stainAt = Streaks.sampler(width, height, terrain, footprint,
      seamless, function(x, y) return dissolvedRust(runoffWater, x, y) end, {
        strength = trails * visibility * 100, seed = seedFor(params),
        -- A longer shower sustains the carrier farther downstream.
        scale = runoffWater and (2 + 22 * rainDuration) or nil,
        wrapY = not runoffWater,
        routes = runoffRoutes,
      })
    -- Walk in row order because the rain transport sampler builds rows lazily.
    for i = 1, width * height do
      local covered = output.paint[i]
      if covered and chipCoverage(metal, i) == 0 then
        local x, y = (i - 1) % width, (i - 1) // width
        local amount, tone = stainAt(x, y)
        local alpha = byte((covered >> 24) * amount * permission(masks, "trails", i))
        if alpha > 0 then
          local rr, gg, bb
          local toneByte = byte(tone * 255)
          if trailPigment then
            rr, gg, bb, alpha = Texture.softDepositSample((toneByte << 8) | alpha, trailPigment)
          else
            rr, gg, bb = Chips.sample((toneByte << 40) | (alpha << 32))
          end
          if alpha and alpha > 0 then
            local r, g, b = rgba(covered)
            r, g, b = mixed(r, g, b, output.primer[i])
            r, g, b = mixed(r, g, b, output.fading[i])
            r, g, b = mixed(r, g, b, output.scuff[i])
            rr, gg, bb = Lighting.tint(rr, gg, bb, r, g, b, alpha / 255, context(x, y), 75)
            output.trails[i] = pixel(rr, gg, bb, alpha)
          end
        end
      end
    end
  end

  shadeDeposits(base, output, width, context)
  if params.captureRain then
    local function trace(water, routes)
      return {
        width = width, height = height, seamless = seamless, waterAt = water, routeAt = routes,
        rustAt = function(x, y) return trails * dissolvedRust(water, x, y) end,
      }
    end
    if not runoffWater then runoffWater, runoffRoutes = storm(terrain) end
    output.rain = trace(runoffWater, runoffRoutes)
    if terrain ~= heights then
      if not baseWaterAt then baseWaterAt, baseRouteAt = storm(heights) end
      output.rain.base = trace(baseWaterAt, baseRouteAt)
    end
  end
  return output
end

return Paint
