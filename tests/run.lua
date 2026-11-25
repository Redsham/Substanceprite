local testsDirectory = arg[0]:match("^(.*[/\\])") or ""
package.path = testsDirectory .. "../?.lua;" .. package.path

local Color = require("lib.color")
local Material = require("lib.material")
local Surface = require("lib.surface")
local Texture = require("lib.texture")

local tests = {}

local function test(name, check)
  tests[#tests + 1] = {name = name, check = check}
end

local function checkEqual(actual, expected, context)
  assert(actual == expected, string.format("%s: expected %s, got %s",
    context, tostring(expected), tostring(actual)))
end

local function sameArray(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

local function sameRamp(a, b)
  for i = 1, #a do
    for _, channel in ipairs({"r", "g", "b", "a"}) do
      if a[i][channel] ~= b[i][channel] then return false end
    end
  end
  return true
end

local function pixelIndex(x, y, width)
  return y * width + x + 1
end

local function checkTexture(pixels, size)
  checkEqual(#pixels, size, "texture length")
  for i = 1, size do
    local level = pixels[i]
    assert(type(level) == "number" and level == math.floor(level)
      and level >= 0 and level <= 3, "invalid ink level at index " .. i)
  end
end

test("color presets are distinct and independently editable", function()
  local names = {"Neutral", "Warm", "Cold", "Industrial", "Cartoon"}
  assert(sameArray(Color.presets, names), "unexpected color preset list")
  local ramps = {}
  local base = {r = 127, g = 89, b = 66, a = 255}
  for i, name in ipairs(names) do
    local settings = Color.preset(name)
    local shift = settings.hueShift
    settings.hueShift = shift + 1
    checkEqual(Color.preset(name).hueShift, shift, name .. " preset was mutated")
    local ramp = Color.generate(base, Color.preset(name))
    for _, previous in ipairs(ramps) do
      assert(not sameRamp(ramp, previous), name .. " repeats another preset")
    end
    ramps[i] = ramp
  end
end)

test("all ramp controls affect a representative base color", function()
  local base = {r = 163, g = 95, b = 78, a = 190}
  local settings = {hueShift = 0, saturation = 0, lightness = 22, contrast = 45}
  local reference = Color.generate(base, settings)
  for key, value in pairs({hueShift = 42, saturation = 85, lightness = 42, contrast = 95}) do
    local changed = {}
    for field, original in pairs(settings) do changed[field] = original end
    changed[key] = value
    assert(not sameRamp(reference, Color.generate(base, changed)), key .. " had no effect")
  end
end)

test("ramps preserve the original swatch, alpha and perceptual lightness order", function()
  local names = {"Deep Shadow", "Shadow", "Base", "Light", "Highlight"}
  local colors = {
    {0, 0, 0}, {255, 255, 255}, {2, 3, 4}, {250, 253, 251}, {128, 128, 128},
    {255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 0}, {0, 255, 255}, {255, 0, 255},
    {84, 123, 165}, {242, 163, 117}, {17, 50, 33},
  }
  for _, preset in ipairs(Color.presets) do
    for _, rgb in ipairs(colors) do
      local base = {r = rgb[1], g = rgb[2], b = rgb[3], a = 167}
      local context = string.format("%s (%d, %d, %d)", preset, base.r, base.g, base.b)
      local ramp = Color.generate(base, Color.preset(preset))
      checkEqual(#ramp, #names, context .. " ramp length")
      for _, channel in ipairs({"r", "g", "b"}) do
        checkEqual(ramp[3][channel], base[channel], context .. " base " .. channel)
      end
      local previousLightness = -1
      for i, swatch in ipairs(ramp) do
        checkEqual(swatch.name, names[i], context .. " swatch name")
        checkEqual(swatch.a, base.a, context .. " swatch alpha")
        for _, channel in ipairs({"r", "g", "b"}) do
          local value = swatch[channel]
          assert(value >= 0 and value <= 255 and value == math.floor(value),
            context .. " has an invalid " .. channel .. " channel")
        end
        local lightness = Color.lightness(swatch)
        assert(lightness + 1e-6 >= previousLightness, context .. " reversed at " .. swatch.name)
        previousLightness = lightness
      end
    end
  end
end)

test("every texture style produces a distinct, repeatable pattern", function()
  local styles = {"Noise", "Dirt", "Rust", "Dust", "Moss", "Scratches", "Wear"}
  local width, height = 47, 39
  assert(sameArray(Texture.styles, styles), "unexpected texture style list")
  local patterns = {}
  for _, style in ipairs(styles) do
    local options = {style = style, seed = 540, density = 55}
    local first = Texture.generate(width, height, options)
    checkTexture(first, width * height)
    assert(sameArray(first, Texture.generate(width, height, options)), style .. " is not repeatable")
    local count = 0
    for _, level in ipairs(first) do
      if level > 0 then count = count + 1 end
    end
    assert(count > 0 and count < #first, style .. " did not leave patterned coverage")
    for _, previous in ipairs(patterns) do
      assert(not sameArray(first, previous), style .. " duplicates another style")
    end
    patterns[#patterns + 1] = first
    options.seed = 541
    assert(not sameArray(first, Texture.generate(width, height, options)), style .. " ignores seed")
  end
end)

test("density and intensity control coverage and ink levels", function()
  local width, height = 37, 32
  local function generate(density, intensity)
    return Texture.generate(width, height, {style = "Rust", seed = 917,
      density = density, intensity = intensity})
  end
  local emptyDensity, emptyIntensity = generate(0, 100), generate(100, 0)
  local low, high = generate(20, 80), generate(80, 80)
  local lightInk, heavyInk = generate(50, 17), generate(50, 100)
  local lowCount, highCount = 0, 0
  for i = 1, width * height do
    checkEqual(emptyDensity[i], 0, "zero density")
    checkEqual(emptyIntensity[i], 0, "zero intensity")
    if low[i] > 0 then
      lowCount = lowCount + 1
      assert(high[i] > 0, "higher density removed an existing mark")
    end
    if high[i] > 0 then highCount = highCount + 1 end
  end
  assert(lowCount < highCount, "raising density did not raise coverage")
  assert(not sameArray(lightInk, heavyInk), "texture ignores changes in intensity")
end)

test("the shape mask preserves holes and disconnected islands", function()
  local width, height = 31, 22
  local mask = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local firstIsland = x >= 2 and x < 14 and y >= 2 and y < 18
      local hole = x >= 5 and x < 9 and y >= 6 and y < 13
      local secondIsland = x >= 19 and x < 28 and y >= 9 and y < 18
      mask[pixelIndex(x, y, width)] = (firstIsland and not hole) or secondIsland
    end
  end
  for _, style in ipairs(Texture.styles) do
    local levels = Texture.generate(width, height, {
      style = style, seed = 731, density = 100, edge = 70, bottom = 40,
    }, mask)
    checkTexture(levels, #mask)
    local hit = false
    for i, allowed in ipairs(mask) do
      if allowed then
        hit = hit or levels[i] > 0
      else
        checkEqual(levels[i], 0, style .. " painted through the mask at " .. i)
      end
    end
    assert(hit, style .. " filled neither island")
  end
end)

test("preview crops use the same space as full-resolution generation", function()
  local width, height = 37, 34
  local options = {style = "Scratches", seed = 196, density = 75, edge = 45, bottom = 50}
  local mask = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      mask[pixelIndex(x, y, width)] = (x + 2 * y) % 13 ~= 0
    end
  end
  local full = Texture.generate(width, height, options, mask)
  local region = {x = 13, y = 9, width = 15, height = 11}
  local crop = Texture.generate(width, height, options, mask, region)
  checkTexture(crop, region.width * region.height)
  for y = 0, region.height - 1 do
    for x = 0, region.width - 1 do
      checkEqual(crop[pixelIndex(x, y, region.width)],
        full[pixelIndex(x + region.x, y + region.y, width)], "preview pixel differs")
    end
  end
  local exterior = Texture.generate(width, height, options, mask, {
    x = width, y = 0, width = 3, height = height,
  })
  checkTexture(exterior, 3 * height)
  for _, level in ipairs(exterior) do checkEqual(level, 0, "out-of-bounds pixel") end
end)

test("seamless patterns repeat exactly across both axes", function()
  local width, height = 29, 37
  local crossing = {x = width - 4, y = height - 5, width = 11, height = 12}
  for _, style in ipairs(Texture.styles) do
    local options = {style = style, density = 64, seed = -939, scale = 7, seamless = true,
      edge = 55, bottom = 50}
    local full = Texture.generate(width, height, options)
    local crop = Texture.generate(width, height, options, nil, crossing)
    local shifted = Texture.generate(width, height, options, nil, {
      x = -2 * width, y = height, width = width, height = height,
    })
    checkTexture(crop, crossing.width * crossing.height)
    assert(sameArray(full, shifted), style .. " changed after a whole tile offset")
    for y = 0, crossing.height - 1 do
      for x = 0, crossing.width - 1 do
        local wrappedX, wrappedY = (crossing.x + x) % width, (crossing.y + y) % height
        checkEqual(crop[pixelIndex(x, y, crossing.width)],
          full[pixelIndex(wrappedX, wrappedY, width)], style .. " seam pixel differs")
      end
    end
  end
end)

test("edge and bottom controls favor their own zones", function()
  local width, height = 64, 68
  local mask, left, right, top, bottom = {}, 5, 58, 7, 60
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      mask[pixelIndex(x, y, width)] = x >= left and x <= right and y >= top and y <= bottom
    end
  end
  local function generate(edge, floor)
    return Texture.generate(width, height, {style = "Dirt", seed = 136,
      density = 36, clustering = 35, edge = edge, bottom = floor}, mask)
  end
  local base, edging, grounding = generate(0, 0), generate(100, 0), generate(0, 100)
  local function averageGain(levels, inZone)
    local gain, size = 0, 0
    for y = top, bottom do
      for x = left, right do
        if inZone(x, y) then
          local i = pixelIndex(x, y, width)
          gain, size = gain + levels[i] - base[i], size + 1
        end
      end
    end
    return gain / size
  end
  local nearEdge = averageGain(edging, function(x, y)
    return math.min(x - left, right - x, y - top, bottom - y) <= 2
  end)
  local interior = averageGain(edging, function(x, y)
    return math.min(x - left, right - x, y - top, bottom - y) >= 10
  end)
  local lower = averageGain(grounding, function(_, y) return y > bottom - 12 end)
  local upper = averageGain(grounding, function(_, y) return y < top + 12 end)
  assert(nearEdge > 0 and nearEdge > interior, "the edge control did not favor the contour")
  assert(lower > 0 and lower > upper, "the bottom control did not favor lower pixels")
end)

test("texture controls change pixel structure and favor clusters", function()
  local width, height = 79, 63
  local function dirt(scale, clustering)
    return Texture.generate(width, height, {style = "Dirt", seed = 145,
      density = 45, scale = scale, clustering = clustering})
  end
  local tight, loose, larger = dirt(3, 90), dirt(3, 0), dirt(8, 90)
  assert(not sameArray(tight, loose), "texture ignores clustering")
  assert(not sameArray(tight, larger), "texture ignores scale")
  local neighborCount, occupied = 0, 0
  for y = 0, height - 2 do
    for x = 0, width - 2 do
      local i = pixelIndex(x, y, width)
      if tight[i] > 0 then
        occupied = occupied + 1
        if tight[i + 1] > 0 then neighborCount = neighborCount + 1 end
        if tight[i + width] > 0 then neighborCount = neighborCount + 1 end
      end
    end
  end
  local coverage = occupied / ((width - 1) * (height - 1))
  local conditionalCoverage = neighborCount / (2 * occupied)
  assert(conditionalCoverage > coverage, "dirt has no spatial clustering")
end)

test("tiny and thin texture domains work in both tiling modes", function()
  for _, style in ipairs(Texture.styles) do
    for _, dimensions in ipairs({{1, 1}, {1, 8}, {9, 1}, {2, 3}}) do
      local width, height = dimensions[1], dimensions[2]
      for _, seamless in ipairs({false, true}) do
        local pixels = Texture.generate(width, height, {style = style, density = 80,
          edge = 60, bottom = 80, scale = 16, seamless = seamless})
        checkTexture(pixels, width * height)
      end
    end
  end
end)

test("height extraction preserves grayscale and holes, and supports alpha and inversion", function()
  local pixels = {
    {0, 0, 0, 255}, {255, 255, 255, 255}, {113, 113, 113, 76},
    {255, 0, 0, 255}, {0, 255, 0, 255}, {255, 255, 255, 0},
  }
  local function reader(x, y)
    return table.unpack(pixels[pixelIndex(x, y, 3)])
  end
  local heights, count = Surface.build(3, 2, reader, {channel = "Luminance"})
  local inverse = Surface.build(3, 2, reader, {channel = "Luminance", invert = true})
  local alpha = Surface.build(3, 2, reader, {channel = "Alpha"})
  checkEqual(count, 5, "visible samples")
  assert(math.abs(heights[1]) < 1e-8, "black should produce the lowest height")
  assert(math.abs(heights[2] - 1) < 1e-8, "white should produce the highest height")
  assert(math.abs(heights[3] - 113 / 255) < 1e-8, "gray should round-trip")
  assert(heights[5] > heights[4], "height extraction ignored relative color luminance")
  assert(math.abs(alpha[3] - 76 / 255) < 1e-8, "alpha extraction ignored partial pixel alpha")
  for i = 1, 5 do
    assert(math.abs(inverse[i] + heights[i] - 1) < 1e-8, "height inversion changed magnitude")
  end
  checkEqual(heights[6], nil, "transparent source has no height")
  checkEqual(inverse[6], nil, "inverting a transparent pixel must not make it a peak")
  checkEqual(alpha[6], nil, "transparent source is missing in alpha mode")
end)

local function steppedSurface(width, height, boundary)
  return Surface.build(width, height, function(x)
    local value = x < boundary and 35 or 220
    return value, value, value, 255
  end, {channel = "Luminance"})
end

test("surface placement distinguishes the low side, high side and slope of a ledge", function()
  local width, height = 20, 12
  local heights = steppedSurface(width, height, 10)
  local recess = Surface.sampler(width, height, heights, false, "Recesses", "Rust")
  local ridge = Surface.sampler(width, height, heights, false, "Ridges", "Wear")
  local slope = Surface.sampler(width, height, heights, false, "Slopes", "Rust")
  assert(recess(9, 5) > recess(10, 5), "recesses did not favor the low side")
  assert(ridge(10, 5) > ridge(9, 5), "ridges did not favor the high side")
  assert(slope(9, 5) > slope(2, 5), "slopes did not favor the ledge")
  assert(slope(10, 5) > slope(16, 5), "slope is not detected from the high side")
  local rust = Surface.sampler(width, height, heights, false, "Material", "Rust")
  local wear = Surface.sampler(width, height, heights, false, "Material", "Wear")
  assert(rust(9, 5) > rust(10, 5), "material-aware rust does not prefer the recess")
  assert(wear(10, 5) > wear(9, 5), "material-aware wear does not prefer the ridge")
end)

test("missing height data and flat areas do not produce false ledges", function()
  local width, height = 8, 8
  local heights = Surface.build(width, height, function(x, y)
    local alpha = (x == 3 and y == 3) and 0 or 255
    return 77, 77, 77, alpha
  end, {channel = "Luminance"})
  for _, placement in ipairs({"Material", "Recesses", "Ridges", "Slopes"}) do
    for _, seamless in ipairs({false, true}) do
      local sample = Surface.sampler(width, height, heights, seamless, placement, "Rust")
      for y = 0, height - 1 do
        for x = 0, width - 1 do
          local coverage, tone = sample(x, y)
          assert(math.abs(coverage) < 1e-8 and math.abs(tone) < 1e-8,
            placement .. " introduced a false ledge on a plane")
        end
      end
    end
  end
end)

test("surface-guided rust gains coverage on the low side without altering disabled output", function()
  local width, height = 48, 44
  local heights = steppedSurface(width, height, width // 2)
  local options = {style = "Rust", seed = 917, density = 48, scale = 4}
  local plain = Texture.generate(width, height, options)
  options.surface = {heights = heights, strength = 0, placement = "Recesses"}
  assert(sameArray(plain, Texture.generate(width, height, options)),
    "surface at zero strength changed the original procedural output")
  options.surface.strength = 100
  local guided = Texture.generate(width, height, options)
  assert(sameArray(guided, Texture.generate(width, height, options)), "guided output changed with the same seed")
  local lowGain, highGain = 0, 0
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local index = pixelIndex(x, y, width)
      local occupied = (guided[index] > 0 and 1 or 0) - (plain[index] > 0 and 1 or 0)
      if x < width // 2 then lowGain = lowGain + occupied else highGain = highGain + occupied end
    end
  end
  assert(lowGain > 0 and lowGain > highGain, "rust did not concentrate in the recess")
end)

test("guided textures keep preview, mask and tile repetition consistent", function()
  local width, height = 29, 25
  local mask = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do mask[pixelIndex(x, y, width)] = (x + 2 * y) % 17 ~= 0 end
  end
  local heights = Surface.build(width, height, function(x, y)
    local heightValue = (12 * x + 19 * y) % 256
    return heightValue, heightValue, heightValue, (x + 3 * y) % 19 == 0 and 0 or 255
  end, {channel = "Luminance"})
  local crop = {x = width - 7, y = height - 8, width = 15, height = 14}
  for _, style in ipairs({"Rust", "Moss", "Scratches", "Wear"}) do
    local options = {style = style, scale = 4, density = 70, seed = 701,
      edge = 35, bottom = 60, seamless = true,
      surface = {heights = heights, strength = 80, placement = "Material"}}
    local full = Texture.generate(width, height, options, mask)
    local tile = Texture.generate(width, height, options, mask, crop)
    for i = 1, #mask do
      if not mask[i] then checkEqual(full[i], 0, style .. " exceeded the material mask") end
    end
    for y = 0, crop.height - 1 do
      for x = 0, crop.width - 1 do
        local index = pixelIndex((crop.x + x) % width, (crop.y + y) % height, width)
        checkEqual(tile[pixelIndex(x, y, crop.width)], full[index], style .. " preview/tiling pixel differs")
      end
    end
  end
end)

local function finishValues(samples, settings, red, green, blue)
  local values = {}
  for i, sample in ipairs(samples) do
    local r, g, b = Material.shade(red, green, blue, sample, settings)
    for _, channel in ipairs({r, g, b}) do
      assert(math.type(channel) == "integer" and channel >= 0 and channel <= 255,
        "material shading produced an invalid channel at " .. i)
    end
    values[i] = 65536 * r + 256 * g + b
  end
  return values
end

test("material styles give different reproducible finishes on the same base", function()
  local width, height = 46, 39
  local styles = {"Brushed Steel", "Aged Paint", "Oxidized Copper", "Tarnished Iron"}
  assert(sameArray(Material.styles, styles), "unexpected material style list")
  local previous = {}
  for _, style in ipairs(styles) do
    local options = {style = style, seed = 831, density = 65, intensity = 55, scale = 5}
    local first = Material.generate(width, height, options)
    checkEqual(#first, width * height, style .. " material field size")
    for i, sample in ipairs(first) do
      assert(math.type(sample) == "integer" and sample >= 0,
        style .. " produced an invalid material sample at " .. i)
    end
    assert(sameArray(first, Material.generate(width, height, options)), style .. " changed with the same seed")
    local colored = finishValues(first, options, 105, 94, 79)
    for _, pattern in ipairs(previous) do
      assert(not sameArray(colored, pattern), style .. " looks identical to another style")
    end
    previous[#previous + 1] = colored
    options.seed = 832
    local changed = finishValues(Material.generate(width, height, options), options, 105, 94, 79)
    assert(not sameArray(colored, changed), style .. " ignores the seed")
  end
end)

test("a material finish respects holes, crops and both seamless tile periods", function()
  local width, height = 43, 25
  local mask = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      mask[pixelIndex(x, y, width)] = x >= 2 and x < width - 2
        and ((x < 10 or x > 18) or y < 6 or y > 13)
    end
  end
  local heights = steppedSurface(width, height, 17)
  local crop = {x = -8, y = height - 9, width = 19, height = 16}
  for _, style in ipairs(Material.styles) do
    local options = {style = style, seed = 918, intensity = 58, scale = 6, density = 85,
      direction = "Vertical", form = "Horizontal Round", seamless = true, edge = 45, bottom = 50,
      surface = {heights = heights, strength = 80, placement = "Slopes"}}
    local full = Material.generate(width, height, options, mask)
    local detail = Material.generate(width, height, options, mask, crop)
    for i, allowed in ipairs(mask) do
      if not allowed then checkEqual(full[i], 0, style .. " drew beyond the mask") end
    end
    local repeated = Material.generate(width, height, options, mask, {
      x = crop.x + 2 * width, y = crop.y - height, width = crop.width, height = crop.height,
    })
    assert(sameArray(detail, repeated), style .. " did not repeat across tile boundaries")
    for y = 0, crop.height - 1 do
      for x = 0, crop.width - 1 do
        local index = pixelIndex((crop.x + x) % width, (crop.y + y) % height, width)
        checkEqual(detail[pixelIndex(x, y, crop.width)], full[index], style .. " preview sample differs")
      end
    end
  end
end)

test("a disabled finish and a zero material sample preserve the source", function()
  local width, height = 33, 27
  local options = {style = "Tarnished Iron", seed = 831, intensity = 0, density = 100,
    form = "Beveled Panel"}
  for i, sample in ipairs(Material.generate(width, height, options)) do
    checkEqual(sample, 0, "zero intensity material sample " .. i)
  end
  local r, g, b = Material.shade(46, 47, 59, 0, options)
  checkEqual(r, 46, "no-op red")
  checkEqual(g, 47, "no-op green")
  checkEqual(b, 59, "no-op blue")
end)

test("material marks stay coherent and retain broad painted light and shadow", function()
  local width, height = 62, 43
  local function luma(r, g, b)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  end
  for _, style in ipairs(Material.styles) do
    local options = {style = style, seed = 613, intensity = 45, density = 70, scale = 6}
    local samples = Material.generate(width, height, options)
    local deltas = {}
    local lightened, darkened = 0, 0
    for i, sample in ipairs(samples) do
      local r, g, b = Material.shade(99, 96, 91, sample, options)
      local delta = luma(r, g, b) - luma(99, 96, 91)
      deltas[i] = delta
      if delta > 1 then lightened = lightened + 1 end
      if delta < -1 then darkened = darkened + 1 end
      assert(math.abs(delta) < 42, style .. " obscures existing shading at moderate intensity")
      local shadowR, shadowG, shadowB = Material.shade(52, 49, 44, sample, options)
      local lightR, lightG, lightB = Material.shade(151, 148, 143, sample, options)
      assert(luma(lightR, lightG, lightB) > luma(shadowR, shadowG, shadowB) + 60,
        style .. " erased the broad contrast between the original tones")
    end
    assert(lightened > 0 and darkened > 0, style .. " did not give signed tonal variations")
    local nearby, distant, count = 0, 0, 0
    for y = 0, height - 9 do
      for x = 0, width - 9 do
        local first = deltas[pixelIndex(x, y, width)]
        nearby = nearby + math.abs(first - deltas[pixelIndex(x + 1, y, width)])
        nearby = nearby + math.abs(first - deltas[pixelIndex(x, y + 1, width)])
        distant = distant + math.abs(first - deltas[pixelIndex(x + 8, y, width)])
        distant = distant + math.abs(first - deltas[pixelIndex(x, y + 8, width)])
        count = count + 2
      end
    end
    assert(nearby / count < distant / count, style .. " flattened its clusters into pixel speckle")
  end
end)

test("direction changes the grain and a round form adds a matching highlight band", function()
  local width, height = 59, 45
  local options = {style = "Brushed Steel", seed = 918, scale = 5,
    density = 95, intensity = 85, clustering = 40, form = "Keep Lighting", direction = "Horizontal"}
  local plain = Material.generate(width, height, options)
  options.direction = "Vertical"
  local verticalGrain = Material.generate(width, height, options)
  assert(not sameArray(plain, verticalGrain), "changing direction did not change the grain")
  options.direction = "Horizontal"

  local function compareForm(form, crossAxis, span)
    options.form = form
    local shaped = Material.generate(width, height, options)
    local center, outside, centerCount, outsideCount = 0, 0, 0, 0
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local i = pixelIndex(x, y, width)
        local base = Material.shade(101, 103, 108, plain[i], options)
        local result = Material.shade(101, 103, 108, shaped[i], options)
        local delta = result - base
        local coord = crossAxis(x, y)
        if coord >= span * 0.4 and coord < span * 0.6 then
          center, centerCount = center + delta, centerCount + 1
        elseif coord < span * 0.12 or coord >= span * 0.88 then
          outside, outsideCount = outside + delta, outsideCount + 1
        end
      end
    end
    assert(center / centerCount > outside / outsideCount, form .. " is missing a center light band")
  end
  compareForm("Horizontal Round", function(_, y) return y end, height)
  compareForm("Vertical Round", function(x) return x end, width)
end)

test("a height map affects a finish without changing a zero-strength result", function()
  local width, height = 41, 37
  local options = {style = "Oxidized Copper", seed = 223, intensity = 55, density = 75, scale = 5}
  local heights = steppedSurface(width, height, 15)
  local plain = Material.generate(width, height, options)
  options.surface = {heights = heights, strength = 0, placement = "Recesses"}
  assert(sameArray(plain, Material.generate(width, height, options)), "zero surface strength changed the finish")
  options.surface.strength = 100
  local withRecess = finishValues(Material.generate(width, height, options), options, 139, 82, 50)
  options.surface.placement = "Ridges"
  local withRidges = finishValues(Material.generate(width, height, options), options, 139, 82, 50)
  assert(not sameArray(withRecess, finishValues(plain, options, 139, 82, 50)), "height guidance had no visible effect")
  assert(not sameArray(withRidges, withRecess), "ridge and recess guidance are identical")
end)

require("tests.normal")(test)
require("tests.composer")(test)
require("tests.weather")(test)
require("tests.soft_deposits")(test)
require("tests.chips")(test)
require("tests.streaks")(test)
require("tests.lighting")(test)
require("tests.linked_weathering")(test)
require("tests.cast_shadow")(test)
require("tests.material_sample")(test)
require("tests.material_sphere")(test)
require("tests.paint_stack")(test)
require("tests.paint_wear")(test)
require("tests.rain")(test)
require("tests.generator_registry")(test)
require("tests.ambient_occlusion")(test)
require("tests.prop_details")(test)
require("tests.detail_alphas")(test)
require("tests.scene_lighting")(test)

test("the Rust preset shares the red-orange Substanceprite palette across both tools", function()
  local Composer = require("lib.composer")
  local Catalog = require("lib.material_catalog")
  local generic = Texture.defaultColors("Rust")
  local stack = Composer.newLayer("Deposits", "Rust").colors
  local expected = { 0x633225, 0xAB492B, 0xDC763E }
  for i, hex in ipairs(expected) do
    for _, palette in ipairs({ generic, stack }) do
      local color = palette[i]
      checkEqual(Composer.pack(color.r, color.g, color.b), hex, "Rust RGB level " .. i)
    end
  end
  generic[1].r = 0
  checkEqual(Texture.defaultColors("Rust")[1].r, 0x63, "customizing a swatch leaves the default intact")
  checkEqual(Catalog.recipe("Painted Metal").layers[1].style,
    "Paint Chips", "painted preset uses exposed-metal corrosion")
end)

test("soft Rust interpolates tones and fades while preserving the mask", function()
  local width, height = 70, 44
  local options = {seed = 219, density = 55, intensity = 72, scale = 5, softness = 95}
  local mask = {}
  for i = 1, width * height do
    local x = (i - 1) % width
    mask[i] = x < 30 or x > 36
  end
  local tones, alphas, unpainted = {}, {}, 0
  for i, sample in ipairs(Texture.generateRust(width, height, options, mask)) do
    if not mask[i] then checkEqual(sample, 0, "soft rust keeps holes") end
    local r, g, b, a = Texture.rustSample(sample)
    if r then
      assert(r >= 0x63 and r <= 0xDC and r > g and g > b and a > 0 and a <= 255)
      tones[(r << 16) | (g << 8) | b], alphas[a] = true, true
    else
      unpainted = unpainted + 1
    end
  end
  local function count(values)
    local n = 0
    for _ in pairs(values) do n = n + 1 end
    return n
  end
  assert(count(tones) >= 12 and count(alphas) >= 10, "rust did not use enough intermediate steps")
  assert(unpainted > 0, "the material needs unpainted zones")
end)

test("runoff changes the Rust footprint and keeps its tiled crops exact", function()
  local width, height = 54, 41
  local heights = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      heights[y * width + x + 1] = y < 13 and 0.82 or (x > 12 and x < 25 and 0.12 or 0.55)
    end
  end
  local options = {seed = 823, density = 44, softness = 83, seamless = true,
    surface = {heights = heights, strength = 0}, runoff = 0}
  local dry = Texture.generateRust(width, height, options)
  options.runoff = 90
  local wet = Texture.generateRust(width, height, options)
  local changed = 0
  for i, sample in ipairs(wet) do
    if (sample ~= 0) ~= (dry[i] ~= 0) then changed = changed + 1 end
  end
  assert(changed > 0, "runoff only changed tone, not position")
  local rect = {x = width - 4, y = height - 5, width = 9, height = 11}
  local crop = Texture.generateRust(width, height, options, nil, rect)
  for y = 0, rect.height - 1 do
    for x = 0, rect.width - 1 do
      local source = ((y + rect.y) % height) * width + ((x + rect.x) % width) + 1
      checkEqual(crop[y * rect.width + x + 1], wet[source], "rainy rust crop period")
    end
  end
end)

test("Substanceprite material stacks add rust streak color without changing the relief", function()
  local Composer = require("lib.composer")
  local width, height, heights = 54, 40, {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      heights[y * width + x + 1] = y < 14 and 0.78 or (x > 16 and x < 27 and 0.27 or 0.53)
    end
  end
  local layer = Composer.newLayer("Deposits", "Paint Chips")
  layer.trails, layer.runoff, layer.density, layer.intensity = 0, 100, 72, 95
  local options = { layers = { layer }, heights = heights, seed = 219, captureRelief = true }
  local function paint() return 64, 76, 72, 255 end
  local before, original = Composer.render(width, height, options, nil, nil, paint)
  layer.trails = 100
  local after, stained = Composer.render(width, height, options, nil, nil, paint)
  assert(not sameArray(before, after), "the stack discarded Rust Trails")
  assert(sameArray(original.heights, stained.heights), "surface pigment must not displace the paint")
end)

test("the same Substanceprite deposit stack can inherit light without changing its mask or relief", function()
  local Composer = require("lib.composer")
  local width, height = 55, 30
  local base = function(x, y)
    local value = y == 14 and 31 or (y <= 15 and 196 or 68)
    return value, value, value, 255
  end
  local layer = Composer.newLayer("Deposits", "Rust")
  layer.density, layer.intensity, layer.amount, layer.lighting = 100, 95, 100, 0
  local options = {layers = {layer}, seed = 219, captureRelief = true}
  local plain, plainDetails = Composer.render(width, height, options, nil, nil, base)
  layer.lighting = 85
  local matched, matchedDetails = Composer.render(width, height, options, nil, nil, base)
  assert(not sameArray(plain, matched), "the stack skipped lighting match")
  assert(sameArray(plainDetails.heights, matchedDetails.heights), "lighting match changed the relief")
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local i = y * width + x + 1
      if plainDetails.heights[i] == 0.5 then
        checkEqual(matched[i], Composer.pack(base(x, y)), "untouched paint retains its original color")
      end
    end
  end
end)

local failed = 0
for _, entry in ipairs(tests) do
  local ok, detail = pcall(entry.check)
  if ok then
    print("PASS " .. entry.name)
  else
    failed = failed + 1
    io.stderr:write("FAIL ", entry.name, "\n  ", tostring(detail), "\n")
  end
end
print(string.format("%d/%d checks passed", #tests - failed, #tests))
if failed > 0 then os.exit(1) end
