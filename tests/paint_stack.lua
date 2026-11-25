local Paint = require("lib.paint_stack")
local PaintColors = require("lib.paint_colors")
local Surface = require("lib.surface")

local function pack(r, g, b, a)
  return (a << 24) | (b << 16) | (g << 8) | r
end

local function alpha(pixel)
  return (pixel or 0) >> 24
end

local function luminance(pixel)
  return Surface.luminance(pixel & 255, (pixel >> 8) & 255, (pixel >> 16) & 255)
end

local function arrayEqual(a, b, count)
  for i = 1, count do
    if a[i] ~= b[i] then return false end
  end
  return true
end

local function trailScore(trails, width)
  local total, lastRow = 0, -1
  for index, pixel in pairs(trails) do
    total = total + alpha(pixel)
    lastRow = math.max(lastRow, (index - 1) // width)
  end
  return total, lastRow
end

return function(test)
  test("arbitrary paint colors retain the order of the underlying shades", function()
    local width, height = 32, 4
    local function reader(x) return 18 + 7 * x, 18 + 7 * x, 18 + 7 * x, 255 end
    local swatches = {{r = 230, g = 30, b = 21}, {r = 26, g = 110, b = 243},
      {r = 255, g = 255, b = 255}, {r = 0, g = 0, b = 0}}
    local renders = {}
    for i, color in ipairs(swatches) do
      local paint = Paint.render(width, height, {color = color, chips = 0}, nil, reader).paint
      renders[i] = paint
      for x = 1, width do
        assert(alpha(paint[x]) == 255)
        if x > 1 then assert(luminance(paint[x]) > luminance(paint[x - 1]), "collapsed shade ramp") end
        assert(paint[x + width] == paint[x], "same input light must match")
      end
    end
    assert(luminance(renders[3][16]) > luminance(renders[4][16]) + 0.30,
      "black and white paint must be distinguishable")
    assert((renders[1][16] & 255) > ((renders[1][16] >> 16) & 255), "red swatch reads red")
    assert((renders[2][16] & 255) < ((renders[2][16] >> 16) & 255), "blue swatch reads blue")
  end)

  test("white metal reveals source, gray metal feathers its edge and alpha stays clipped", function()
    local metal = {255, 128, 0, 255, 0}
    local function source(x)
      return 151, 147, 140, ({255, 255, 255, 0, 94})[x + 1]
    end
    local params = {chips = 0, corrosion = 0, trails = 100}
    local result = Paint.render(5, 1, params, nil, source, nil, metal)
    assert(result.paint[1] == nil and result.rust[1] == nil, "a clean exposed chip must leave the source pixel alone")
    assert(alpha(result.paint[2]) == 127 and alpha(result.paint[3]) == 255, "gray map feathers paint")
    assert(result.paint[4] == nil and result.rust[4] == nil, "transparent source stays transparent")
    assert(alpha(result.paint[5]) == 94, "paint respects semitransparent edges")
    assert(next(result.trails) == nil, "no trails without rust")
    params.opacity = 0
    params.corrosion = 100
    assert(next(Paint.render(5, 1, params, nil, source, nil, metal).rust) == nil, "disabled coating removes rust")
  end)

  test("any exposed map pixel can oxidize and an edited rust mask also stops its trails", function()
    local width, height, x, y = 28, 25, 10, 3
    local i = y * width + x + 1
    local metal = {[i] = 255}
    local function base() return 106, 115, 115, 255 end
    local function oldRust(u, v) if u == x and v == y then return 192, 85, 31, 255 end end
    local params = {chips = 0, corrosion = 100, trails = 100, seed = 219}
    local derived = Paint.render(width, height, params, nil, base, nil, metal)
    assert(next(derived.rust) == i and derived.rust[i] ~= nil, "painted metal outside the seed should rust")
    for j in pairs(derived.rust) do assert(j == i, "oxide escaped the metal mask") end
    params.rustAt = oldRust
    local saved = Paint.render(width, height, params, nil, base, nil, metal)
    assert(saved.rust[i] == pack(192, 85, 31, 255), "old raster rust survives in a fully exposed chip")
    assert(next(saved.trails), "remembered rust emits a runoff trail")
    assert(saved.trails[i] == nil, "trail should lie only on paint")
    params.effectMasks = {rust = {}}
    local hidden = Paint.render(width, height, params, nil, base, nil, metal)
    assert(next(hidden.rust) == nil and next(hidden.trails) == nil, "masked rust cannot supply a trail")
    params.effectMasks = {rust = {[i] = 128}, trails = {}}
    local feathered = Paint.render(width, height, params, nil, base, nil, metal)
    assert(alpha(feathered.rust[i]) == 128 and next(feathered.trails) == nil)
  end)

  test("chips are deterministic and dirt and moss follow height and their own masks", function()
    local width, height = 49, 42
    local size = width * height
    local params = {chips = 69, seed = 219, dirt = 72, moss = 80, corrosion = 77, trails = 69}
    local footprint, heights = {}, {}
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local i = y * width + x + 1
        footprint[i] = x ~= 4
        heights[i] = x >= 16 and x <= 22 and 0.22 or (y < 18 and 0.8 or 0.57)
      end
    end
    local function base(x, y)
      return 98 + y, 104 + x, 119, 255
    end
    local chips = Paint.generate(width, height, params, footprint)
    assert(arrayEqual(chips.chips, Paint.generate(width, height, params, footprint).chips, size))
    params.seed = 812
    assert(not arrayEqual(chips.chips, Paint.generate(width, height, params, footprint).chips, size))
    params.seed = 219
    local flat = Paint.render(width, height, params, footprint, base)
    params.heights = heights
    local guided = Paint.render(width, height, params, footprint, base)
    assert(not arrayEqual(flat.dirt, guided.dirt, size) and not arrayEqual(flat.moss, guided.moss, size),
      "height map affects both deposit patterns")
    assert(next(guided.dirt) and next(guided.moss) and not arrayEqual(guided.moss, guided.dirt, size))
    for key, pixels in pairs(guided) do
      for i in pairs(pixels) do assert(footprint[i], key .. " passed the selection") end
    end
    params.effectMasks = {dirt = {}, moss = {}}
    local masked = Paint.render(width, height, params, footprint, base)
    assert(next(masked.dirt) == nil and next(masked.moss) == nil)
    assert(arrayEqual(masked.paint, guided.paint, size) and arrayEqual(masked.rust, guided.rust, size),
      "deposit masks cannot change the paint or rust")
  end)

  test("rain strength affects stain and duration carries it farther down", function()
    local width, height, sourceX, sourceY = 24, 44, 11, 1
    local metal = {[sourceY * width + sourceX + 1] = 255}
    local function base(x, y)
      if x == 4 and y > 8 then return 111, 118, 116, 0 end
      return 111, 118, 116, 255
    end
    local function oldRust(x, y)
      if x == sourceX and y == sourceY then return 173, 76, 32, 255 end
    end
    local settings = {chips = 0, corrosion = 100, trails = 100, rustAt = oldRust,
      seed = 219, seamless = true}
    local function storm(strength, duration)
      settings.rainStrength, settings.rainDuration = strength, duration
      return Paint.render(width, height, settings, nil, base, nil, metal)
    end
    local mild = storm(20, 25)
    local downpour = storm(100, 25)
    local prolonged = storm(100, 100)
    local mildScore = trailScore(mild.trails, width)
    local heavyScore, heavyEnd = trailScore(downpour.trails, width)
    local longScore, longEnd = trailScore(prolonged.trails, width)
    assert(heavyScore > mildScore and heavyScore > 0, "heavier rain must mobilize more pigment")
    assert(longEnd > heavyEnd and longScore > heavyScore, "longer rain must carry pigment farther")
    assert(longScore > trailScore(storm(85, 100).trails, width), "strength must remain adjustable in heavy rain")
    assert(next(storm(0, 100).trails) == nil and next(storm(100, 0).trails) == nil,
      "zero rain or time stops the runoff")
    assert(arrayEqual(mild.paint, prolonged.paint, width * height)
      and arrayEqual(mild.rust, prolonged.rust, width * height),
      "rain controls only move existing rust across the paint")
    for index in pairs(prolonged.trails) do
      local x, y = (index - 1) % width, (index - 1) // width
      assert(y > sourceY and select(4, base(x, y)) > 0, "runoff climbed or escaped the silhouette")
    end
    settings.effectMasks = {rust = {}}
    assert(next(storm(100, 100).trails) == nil, "rain cannot pick up masked rust")
  end)

  test("rain changes deposits without creating pigment or overriding authored masks", function()
    local width, height = 29, 25
    local heights = {}
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        heights[y * width + x + 1] = x > 10 and x < 16 and 0.20
          or (y < 8 and 0.70 or 0.52)
      end
    end
    local function base() return 104, 109, 105, 255 end
    local settings = {chips = 0, corrosion = 100, dirt = 80, moss = 80, trails = 100,
      rainStrength = 0, rainDuration = 100, seed = 219, heights = heights}
    local dry = Paint.render(width, height, settings, nil, base)
    settings.rainStrength = 100
    local wet = Paint.render(width, height, settings, nil, base)
    assert(not arrayEqual(dry.dirt, wet.dirt, width * height)
      and not arrayEqual(dry.moss, wet.moss, width * height), "both deposits respond to the water field")
    assert(next(wet.rust) == nil and next(wet.trails) == nil, "rain alone cannot create rust over intact paint")
    settings.effectMasks = {dirt = {}, moss = {}}
    local masked = Paint.render(width, height, settings, nil, base)
    assert(next(masked.dirt) == nil and next(masked.moss) == nil)
  end)

  test("edge wear can reveal metal while scuffs and fading stay on painted pixels", function()
    local width, height = 52, 36
    local footprint, heights = {}, {}
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local index = y * width + x + 1
        footprint[index] = x ~= 23 or y < 10 or y > 20
        heights[index] = y < 12 and 0.65 or 0.35
      end
    end
    local function base(x, y) return 80 + y * 2, 87 + y * 2, 99 + y * 2, 255 end
    local params = {edgeWear = 100, edgeWidth = 3, scuffs = 100, fading = 100,
      corrosion = 100, chips = 0, seed = 219, heights = heights}
    local geometry = Paint.generate(width, height, params, footprint)
    local mask = {[9 * width + 11] = 255}
    local result = Paint.render(width, height, params, footprint, base, geometry, mask)
    assert(next(result.scuff) and next(result.fading), "both rubbed and aged coats should render")
    local found = false
    for i, amount in ipairs(geometry.chips) do
      assert((geometry.unwornChips[i] or 0) == 0, "edge wear can age the metal without chips")
      if amount > 0 then found = true end
    end
    assert(found, "rim exposure should contribute to the procedural metal map")
    for _, pixels in ipairs({result.scuff, result.fading}) do
      for i, pixel in pairs(pixels) do
        assert(footprint[i] and result.paint[i] and alpha(pixel) <= alpha(result.paint[i]),
          "coat wear should use only the remaining paint coverage")
      end
    end
    local bare = 9 * width + 11
    assert(result.paint[bare] == nil and result.scuff[bare] == nil and result.fading[bare] == nil)
    assert(result.rust[bare], "an authored opening still oxidizes outside the procedural rim")
    params.effectMasks = {scuff = {}, fading = {}}
    local masked = Paint.render(width, height, params, footprint, base, geometry, mask)
    assert(next(masked.scuff) == nil and next(masked.fading) == nil)
    assert(arrayEqual(result.paint, masked.paint, width * height)
      and arrayEqual(result.rust, masked.rust, width * height))
  end)

  test("custom paint weathering palettes reach each color layer and keep the masks", function()
    local width, height = 48, 38
    local exposed = 3 * width + 21
    local function base(x, y)
      return 105, 122, 135, x == 9 and y > 20 and 0 or 255
    end
    local function rustAt(x, y)
      if y * width + x + 1 == exposed then return 174, 91, 48, 255 end
    end
    local params = {chips = 0, corrosion = 100, trails = 100, dirt = 100, moss = 100, soot = 100,
      scuffs = 100, fading = 100, seed = 219, rustAt = rustAt}
    local metal = {[exposed] = 255}
    local default = Paint.render(width, height, params, nil, base, nil, metal)
    assert(next(default.metal) == nil, "untinted metal keeps the exact underneath pixel")
    local palette = {}
    for _, effect in ipairs(PaintColors.definitions) do
      local value = PaintColors.get(nil, effect.id)
      local colors = effect.count == 1 and {value} or value
      for _, color in ipairs(colors) do color.r, color.g, color.b = 34, 202, 221 end
      palette[effect.id] = value
    end
    params.palette = PaintColors.normalize(palette)
    palette.rust[1].r = 99
    assert(params.palette.rust[1].r == 34, "saved sets own their swatches")
    local custom = Paint.render(width, height, params, nil, base, nil, metal)
    assert(next(custom.metal) == exposed and alpha(custom.metal[exposed]) == 255)
    for i = 1, width * height do
      assert(alpha(custom.paint[i]) == alpha(default.paint[i]), "recoloring keeps the paint cut")
    end
    for _, key in ipairs({"paint", "scuff", "fading", "rust", "trails", "dirt", "moss", "soot"}) do
      assert(next(default[key]) and not arrayEqual(custom[key], default[key], width * height),
        key .. " did not take its custom colors")
      for i = 1, width * height do
        assert(alpha(default[key][i]) == alpha(custom[key][i]), key .. " recolor changed opacity")
      end
    end
    for _, swatch in ipairs(params.palette.rust) do swatch.a = 0 end
    local invisible = Paint.render(width, height, params, nil, base, nil, metal)
    assert(next(invisible.rust) == nil and next(invisible.trails) == nil)
    local primer = custom.primer[exposed + 1]
    assert(primer and not custom.primer[exposed], "primer follows the painted lip of the chip")
    params.effectMasks = {primer = {}, soot = {}}
    local masked = Paint.render(width, height, params, nil, base, nil, metal)
    assert(next(masked.primer) == nil and next(masked.soot) == nil)
  end)
end
