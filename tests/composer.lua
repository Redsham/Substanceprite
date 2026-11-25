local Composer = require("lib.composer")
local Surface = require("lib.surface")

local function color(x, y)
  return 48 + (7 * x + 3 * y) % 143, 58 + (5 * x + 2 * y) % 129,
         65 + (3 * x + 5 * y) % 121, 255
end

local function checkArray(a, b)
  assert(#a == #b, "pixel counts differ")
  for i = 1, #a do
    assert(a[i] == b[i], "different pixel at position " .. i)
  end
end

local function makeGuide(width, height)
  local heights = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do heights[y * width + x + 1] = x < width // 2 and 0.24 or 0.78 end
  end
  return heights
end

return function(test)
  test("the material stack preserves source pixels at zero opacity and respects both holes", function()
    local width, height = 7, 5
    local mask = {}
    for i = 1, width * height do mask[i] = i ~= 9 end
    local zero = Composer.newLayer("Deposits", "Dirt")
    zero.amount = 0
    local muted = Composer.newLayer("Finish", "Oxidized Copper")
    muted.enabled = false
    local function read(x, y)
      local r, g, b = color(x, y)
      return r, g, b, x == 3 and y == 2 and 0 or 255
    end

    local pixels, details = Composer.render(width, height,
      { layers = { zero, muted }, captureLayers = true, captureRelief = true }, mask, nil, read)
    assert(#pixels == width * height and #details.stages == 0)
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local i = y * width + x + 1
        if i == 9 or i == 18 then
          assert(pixels[i] == Composer.emptyPixel and details.heights[i] == nil)
        else
          assert(pixels[i] == Composer.pack(color(x, y)) and details.heights[i] == 0.5)
        end
      end
    end
  end)

  test("palette matching keeps original lightness and captures the palette stage", function()
    local palette = { { r = 189, g = 148, b = 119 }, { r = 65, g = 39, b = 33 } }
    local options = { palette = palette, paletteName = "Warm Metal", paletteAmount = 100, captureLayers = true }
    local function read(x) return x * 17, x * 17, x * 17, 255 end
    local pixels, details = Composer.render(16, 1, options, nil, nil, read)
    assert(details.stages[1].kind == "Palette" and details.stages[1].name == "Warm Metal")
    assert(details.stages[1].index == 0 and palette[1].r == 189)
    checkArray(pixels, details.stages[1].pixels)
    for i, pixel in ipairs(pixels) do
      local luma = Surface.luminance(Composer.rgb(pixel)) * 255
      assert(math.abs(luma - (i - 1) * 17) < 0.75, "palette moved lightness")
    end
    local r, g, b = Composer.rgb(pixels[8])
    assert(r > g and g > b, "palette chroma was not applied")
  end)

  test("a fitted palette uses project shades while keeping the source lightness order", function()
    local palette = { { r = 38, g = 44, b = 35 }, { r = 84, g = 92, b = 71 } }
    local function read(x)
      local n = 131 + x * 4
      return n, n, n, 255
    end
    local range = Composer.paletteRange(13, 1, nil, read)
    assert(range.low == 135 and range.high == 175)
    local options = { palette = palette, paletteRange = range, paletteAmount = 100 }
    local pixels = Composer.render(13, 1, options, nil, nil, read)
    assert(pixels[1] == Composer.pack(38, 44, 35) and pixels[13] == Composer.pack(84, 92, 71))
    for i = 2, #pixels do
      local low = Surface.luminance(Composer.rgb(pixels[i - 1]))
      local high = Surface.luminance(Composer.rgb(pixels[i]))
      assert(high >= low, "fitted palette reversed the source shades")
    end
    local function flat() return 173, 173, 173, 255 end
    options.paletteRange = Composer.paletteRange(1, 1, nil, flat)
    local uniform = Composer.render(1, 1, options, nil, nil, flat)
    assert(uniform[1] == Composer.pack(61, 68, 53), "flat source did not use the midpoint")
    assert(Composer.paletteRange(1, 1, { false }, flat) == nil)
  end)

  test("layer order affects color, and each captured stage matches its own prefix", function()
    local width, height = 37, 29
    local finish = Composer.newLayer("Finish", "Oxidized Copper")
    local rust = Composer.newLayer("Deposits", "Rust")
    rust.name, rust.density, rust.amount = "Pitting", 97, 87
    local first = { layers = { finish, rust }, captureLayers = true, seed = 41 }
    local pixels, details = Composer.render(width, height, first, nil, nil, color)
    local standalone = Composer.render(width, height, { layers = { finish }, seed = 41 }, nil, nil, color)
    assert(#details.stages == 2 and details.stages[2].name == "Pitting")
    assert(details.stages[1].index == 1 and details.stages[2].index == 2)
    checkArray(standalone, details.stages[1].pixels)
    checkArray(pixels, details.stages[2].pixels)

    local reversed = Composer.render(width, height, { layers = { rust, finish }, seed = 41 }, nil, nil, color)
    local changed = 0
    for i = 1, #pixels do if pixels[i] ~= reversed[i] then changed = changed + 1 end end
    assert(changed > width * height / 10, "layer order did not substantially change the result")
  end)

  test("a relief mask gates a coating to the requested side of the guide", function()
    local width, height = 40, 24
    local finish = Composer.newLayer("Finish", "Aged Paint")
    finish.mask = "Ridges"
    local guide = makeGuide(width, height)
    local options = { layers = { finish }, heights = guide, captureRelief = true }
    local pixels, details = Composer.render(width, height, options, nil, nil, color)
    local changed = { 0, 0 }
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local i = y * width + x + 1
        if pixels[i] ~= Composer.pack(color(x, y)) then
          local side = x < width // 2 and 1 or 2
          changed[side] = changed[side] + 1
        end
        assert(details.heights[i] >= 0 and details.heights[i] <= 1)
      end
    end
    assert(changed[1] == 0 and changed[2] > 20, "ridge mask did not separate high and low sides")
    options.heights = nil
    local missing = Composer.render(width, height, options, nil, nil, color)
    local plain = Composer.render(width, height, nil, nil, nil, color)
    checkArray(missing, plain)
  end)

  test("surface normal detail uses the same procedural marks and their opacity", function()
    local width, height = 43, 33
    local dirt = Composer.newLayer("Deposits", "Dirt")
    local scratches = Composer.newLayer("Deposits", "Scratches")
    dirt.density, scratches.density = 100, 100
    dirt.amount, scratches.amount = 100, 100
    for _, layer in ipairs({ dirt, scratches }) do
      local options = { layers = { layer }, captureRelief = true }
      local pixels, details = Composer.render(width, height, options, nil, nil, color)
      local painted = 0
      for y = 0, height - 1 do
        for x = 0, width - 1 do
          local i = y * width + x + 1
          local depth = details.heights[i]
          if pixels[i] ~= Composer.pack(color(x, y)) then
            painted = painted + 1
            if layer.style == "Dirt" then
              assert(depth > 0.5, "a deposit did not add height")
            else
              assert(depth < 0.5, "a scratch did not reduce height")
            end
          else
            assert(depth == 0.5, "relief appeared outside a procedural mark")
          end
        end
      end
      assert(painted > 5, "the test did not produce enough marks")
    end
  end)

  test("dirt and moss relief follow mask and source coverage without changing the guide", function()
    local width, height = 46, 34
    local guide, footprint, feather = makeGuide(width, height), {}, {}
    for i = 1, width * height do
      footprint[i] = (i - 1) % width ~= 5
      feather[i] = 0.5
    end
    local function base(x, y)
      local r, g, b = color(x, y)
      return r, g, b, x == 4 and 0 or 255
    end
    local function translucent(x, y)
      local r, g, b, a = base(x, y)
      return r, g, b, a == 0 and 0 or 128
    end
    for _, style in ipairs({"Dirt", "Moss"}) do
      local layer = Composer.newLayer("Deposits", style)
      layer.id, layer.amount, layer.density, layer.intensity = style, 100, 100, 95
      local options = {layers = {layer}, heights = guide, seed = 219, captureRelief = true}
      local function render(reader)
        local _, details = Composer.render(width, height, options, footprint, nil, reader)
        return details.heights
      end
      local normal = render(base)
      local faded = render(translucent)
      options.masks = {[style] = feather}
      local masked = render(base)
      options.masks = nil
      for _, swatch in ipairs(layer.colors) do swatch.a = 0 end
      local invisible = render(base)
      local raised = 0
      for i = 1, width * height do
        local x = (i - 1) % width
        assert(guide[i] == (x < width // 2 and 0.24 or 0.78), "render mutated the authored guide")
        if x == 4 or not footprint[i] then
          assert(normal[i] == nil and faded[i] == nil and masked[i] == nil and invisible[i] == nil)
        else
          local depth = normal[i] - guide[i]
          assert(depth >= 0 and depth <= 0.12, "deposits only add shallow relief")
          assert(math.abs(faded[i] - guide[i] - depth * 128 / 255) < 1e-9)
          assert(math.abs(masked[i] - guide[i] - depth * 0.5) < 1e-9)
          assert(invisible[i] == guide[i], "transparent deposit pigment added relief")
          if depth > 0 then raised = raised + 1 end
        end
      end
      assert(raised > 20, "too few visible " .. style .. " pixels to measure relief")
    end
  end)

  test("a tiled material stack repeats its colors, stages and relief exactly across crops", function()
    local width, height = 19, 11
    local finish = Composer.newLayer("Finish", "Brushed Steel")
    finish.form, finish.surfaceStrength = "Vertical Round", 80
    local wear = Composer.newLayer("Deposits", "Wear")
    wear.mask = "Slopes"
    local options = {
      layers = { finish, wear }, heights = makeGuide(width, height), seamless = true,
      captureLayers = true, captureRelief = true, seed = 3963,
    }
    local pixels, details = Composer.render(width, height, options, nil, nil, color)
    local crop = { x = -4, y = 7, width = 31, height = 14 }
    local cropped, croppedDetails = Composer.render(width, height, options, nil, crop, color)
    for y = 0, crop.height - 1 do
      for x = 0, crop.width - 1 do
        local i = y * crop.width + x + 1
        local j = ((crop.y + y) % height) * width + (crop.x + x) % width + 1
        assert(cropped[i] == pixels[j])
        assert(croppedDetails.heights[i] == details.heights[j])
        for k = 1, #details.stages do assert(croppedDetails.stages[k].pixels[i] == details.stages[k].pixels[j]) end
      end
    end
  end)
end
