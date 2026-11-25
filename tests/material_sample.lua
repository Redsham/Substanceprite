local Catalog = require("lib.material_catalog")
local Sample = require("lib.material_sample")
local Surface = require("lib.surface")

local function pixel(reader, x, y)
  local r, g, b, a = reader(x, y)
  return (r << 24) | (g << 16) | (b << 8) | a
end

return function(test)
  test("catalog exposes seven material categories with independent editable presets", function()
    local names = { "Bark", "Wood Planks", "Metal", "Painted Metal", "Plastic", "Stone", "Concrete" }
    local ids = { "bark", "wood-planks", "metal", "painted-metal", "plastic", "stone", "concrete" }
    assert(#Catalog.names == #names)
    for i, name in ipairs(names) do
      assert(Catalog.names[i] == name)
      local preset = Catalog.recipe(name)
      local other = Catalog.recipeById(ids[i])
      assert(preset.id == ids[i] and other.name == name)
      assert(#preset.palette == 5 and #preset.layers >= 1)
      local red = other.palette[1].r
      preset.palette[1].r = (red + 1) % 256
      preset.layers[1].amount = -42
      assert(other.palette[1].r == red and other.layers[1].amount >= 0)
    end
    assert(Catalog.recipe("unknown-material") == nil)
  end)

  test("each material sample has repeatable colors, heights and individual surface response", function()
    local width, height = 61, 41
    local responses, colors = {}, {}
    for _, name in ipairs(Catalog.names) do
      local a, aHeights, response = Sample.generate(width, height, name, 17)
      local b, bHeights = Sample.generate(width, height, name, 17)
      local low, high = 1, 0
      local colorSet, signature = {}, 0
      assert(#aHeights == width * height and #bHeights == #aHeights)
      for y = 0, height - 1 do
        for x = 0, width - 1 do
          local i = y * width + x + 1
          local color = pixel(a, x, y)
          local level = aHeights[i]
          assert(color == pixel(b, x, y) and color & 255 == 255)
          assert(level == bHeights[i] and level >= 0 and level <= 1)
          low, high = math.min(low, level), math.max(high, level)
          colorSet[color] = true
          signature = ((signature ~ color) * 16777619) & 0xffffffff
        end
      end
      local count = 0
      for _ in pairs(colorSet) do count = count + 1 end
      assert(count > 15, name .. " should have an actual range of albedo values")
      assert(high - low > 0.055, name .. " should have usable procedural relief")
      assert(not colors[signature], "duplicate material substrate")
      colors[signature] = true
      assert(response.roughness >= 0 and response.roughness <= 1)
      assert(response.metalness >= 0 and response.metalness <= 1)
      assert(response.relief > 0)
      responses[name] = response
    end
    assert(responses.Metal.roughness < responses.Bark.roughness)
    assert(responses.Metal.metalness > responses["Painted Metal"].metalness)
    assert(responses.Plastic.metalness == 0 and responses["Wood Planks"].metalness == 0)
  end)

  test("sample seed and scale change the surface and integer readers wrap on both axes", function()
    local width, height = 49, 33
    for _, name in ipairs(Catalog.names) do
      local a, heights = Sample.generate(width, height, name, 11)
      local b, other = Sample.generate(width, height, name, -12)
      local larger, scaled = Sample.generate(width, height, name, 11, { patternScale = 175 })
      local differences, resized = 0, 0
      for y = 0, height - 1 do
        for x = 0, width - 1 do
          local i = y * width + x + 1
          local color = pixel(a, x, y)
          assert(color == pixel(a, x - width, y + 2 * height), name .. " seamless addressing")
          if color ~= pixel(b, x, y) and heights[i] ~= other[i] then differences = differences + 1 end
          if color ~= pixel(larger, x, y) and heights[i] ~= scaled[i] then resized = resized + 1 end
        end
      end
      assert(differences > width * height / 2, name .. " should respond to the seed")
      assert(resized > width * height / 2, name .. " should respond to the chosen scale")
    end
  end)

  test("stone has deep joined fractures and concrete has sparse fine pores", function()
    local width, height = 100, 70
    local function measure(name)
      local _, relief, response = Sample.generate(width, height, name, 31)
      local deep, connected = 0, 0
      for y = 0, height - 1 do
        for x = 0, width - 1 do
          local i = y * width + x + 1
          if relief[i] < 0.42 then
            deep = deep + 1
            if x > 0 and relief[i - 1] < 0.42 then connected = connected + 1 end
          end
        end
      end
      return deep, connected, response
    end

    local fractures, joined, stone = measure("Stone")
    local pores, grouped, concrete = measure("Concrete")
    assert(pores > 0 and pores < width * height / 20)
    assert(fractures > 3 * pores and joined > 3 * grouped)
    assert(stone.relief > concrete.relief and concrete.roughness > stone.roughness)
    assert(stone.metalness == 0 and concrete.metalness == 0)
  end)

  test("bark fissures and board grain retain their predominantly vertical direction", function()
    local width, height = 72, 56
    local function gradients(name, direction)
      local _, heights = Sample.generate(width, height, name, 82, { patternDirection = direction })
      local dx, dy = 0, 0
      for y = 0, height - 2 do
        for x = 0, width - 2 do
          local i = y * width + x + 1
          dx = dx + math.abs(heights[i] - heights[i + 1])
          dy = dy + math.abs(heights[i] - heights[i + width])
        end
      end
      return dx, dy
    end
    for _, name in ipairs({ "Bark", "Wood Planks" }) do
      local dx, dy = gradients(name)
      assert(dx > 1.5 * dy, name .. " grain should run vertically")
      dx, dy = gradients(name, "Horizontal")
      assert(dy > 1.5 * dx, name .. " grain should turn when requested")
    end
  end)

  test("applying a material preserves authored light, mask, alpha and relief", function()
    local w, h = 36, 28
    local function source(x, y)
      if x == 0 then return 255, 255, 255, 0 end
      local level = y < h // 2 and 58 or 196
      return level + 18, level, level - 6, x == 1 and 154 or 255
    end
    local mask, authored = {}, {}
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local i = y * w + x + 1
        mask[i] = x == 2 and 0 or x ~= 3
        authored[i] = (x + 2) / (w + 4)
      end
    end
    local none, unchanged = Sample.forArtwork(w, h, "Bark", 143, source, mask, {
      patternAmount = 0, heights = authored,
    })
    local lit, raised = Sample.forArtwork(w, h, "Bark", 143, source, mask, {
      lighting = 100, heights = authored,
    })
    local unlit = Sample.forArtwork(w, h, "Bark", 143, source, mask, { lighting = 0 })
    local changes = 0
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local i = y * w + x + 1
        local r, g, b, a = lit(x, y)
        if x == 0 or x == 2 or x == 3 then
          assert(r == nil and raised[i] == nil and unchanged[i] == nil)
        else
          assert(a == (x == 1 and 154 or 255))
          assert(pixel(none, x, y) == pixel(source, x, y) and unchanged[i] == authored[i])
          assert(raised[i] >= 0 and raised[i] <= 1)
          if raised[i] ~= authored[i] then changes = changes + 1 end
          local bright = Surface.luminance(r, g, b)
          local flat = Surface.luminance(unlit(x, y))
          if y < h // 2 then assert(bright < flat) else assert(bright > flat) end
        end
      end
    end
    assert(changes > 0.8 * w * h)
    assert(lit(-1, 0) == nil and lit(w, 0) == nil and lit(0, h) == nil)
  end)

  test("a custom recipe can reuse a pattern and set its own albedo", function()
    local vanilla, expected = Sample.generate(31, 27, "wood-planks", 4)
    local custom, heights, profile = Sample.generate(31, 27, {
      id = "custom-boards", pattern = "wood-planks", palette = { { r = 71, g = 62, b = 94 } },
      roughness = 0.62, metalness = 0, relief = 1.1,
    }, 4)
    assert(profile.roughness == 0.62 and profile.metalness == 0 and profile.relief == 1.1)
    for y = 0, 26 do
      for x = 0, 30 do
        local i = y * 31 + x + 1
        assert(heights[i] == expected[i])
        assert(pixel(custom, x, y) == 0x473e5eff and pixel(custom, x, y) ~= pixel(vanilla, x, y))
      end
    end
  end)
end
