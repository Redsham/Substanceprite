local Deposits = require("lib.deposits")
local Effects = require("lib.effect_registry")
local Masks = require("lib.mask_registry")
local Surface = require("lib.surface")

local function at(width, x, y)
  return y * width + x + 1
end

return function(test)
  test("effect registry preserves existing procedural samples and isolates color ramps", function()
    local settings = { seed = 19 }
    for _, name in ipairs(Deposits.styles) do
      local fromRegistry = Effects.generator(name)(16, 12, settings)
      local fromDeposits = Deposits.generator(name)(16, 12, { seed = 19, style = name })
      assert(#fromRegistry == 192)
      for i = 1, #fromRegistry do assert(fromRegistry[i] == fromDeposits[i], name) end
      local colors = Effects.defaultColors(name)
      local red = colors[1].r
      colors[1].r = 999
      assert(Effects.defaultColors(name)[1].r == red)
    end
    assert(settings.style == nil)
    assert(not Effects.register { name = "Soot" })
    assert(not Effects.register { name = "Missing fields" })
  end)

  test("Soot rises from its source, keeps a soft boundary and respects shape and crop", function()
    local width, height = 41, 36
    local generate = Effects.generator("Soot")
    local settings = { seed = 413, density = 68 }
    local footprint = {}
    for y = 3, height - 4 do
      for x = 2, width - 3 do
        footprint[at(width, x, y)] = x < 15 or x > 18 or y < 12 or y > 16
      end
    end
    local samples = generate(width, height, settings, footprint)
    local bottom, top, different = 0, 0, 0
    local shades = {}
    local alternate = generate(width, height, { seed = 414, density = 68 }, footprint)
    for i, pixel in ipairs(samples) do
      local y, coverage = (i - 1) // width, pixel & 255
      if not footprint[i] then assert(pixel == 0) end
      if y < 12 then top = top + coverage end
      if y > 23 then bottom = bottom + coverage end
      if coverage > 0 then shades[coverage] = true end
      if alternate[i] ~= pixel then different = different + 1 end
    end
    local distinct = 0
    for _ in pairs(shades) do distinct = distinct + 1 end
    assert(bottom > 1000 and bottom > top * 2, "expected smoke to be denser toward its source")
    assert(distinct > 24 and different > 40, "expected softly changing seeded coverage")
    local rect = { x = 4, y = 8, width = 25, height = 15 }
    local clipped = generate(width, height, settings, footprint, rect)
    for y = 0, rect.height - 1 do
      for x = 0, rect.width - 1 do
        assert(clipped[at(rect.width, x, y)] == samples[at(width, x + rect.x, y + rect.y)])
      end
    end
    local empty = generate(width, height, { intensity = 0 })
    for _, pixel in ipairs(empty) do assert(pixel == 0) end
  end)

  test("Soot tiles without a horizontal seam from the source plume", function()
    local width, height = 28, 26
    local settings = { seed = 289, seamless = true, density = 92 }
    local generate = Effects.generator("Soot")
    local samples = generate(width, height, settings)
    local repeatTile = generate(width, height, settings, nil, {
      x = -width, y = height, width = width, height = height,
    })
    local sawSoot = false
    for i, value in ipairs(samples) do
      assert(value == repeatTile[i])
      if value > 0 then sawSoot = true end
    end
    assert(sawSoot)
    for x = 0, width - 1 do
      assert(samples[at(width, x, 0)] == 0)
      assert(samples[at(width, x, height - 1)] == 0)
    end
  end)

  test("registered relief masks retain the original signed surface guide", function()
    local heights = { 0, 0.4, 0, 0.6, 1, 0, 0, 0, 0.4 }
    for _, name in ipairs({ "Recesses", "Ridges", "Slopes" }) do
      assert(Masks.get(name).requiresHeight and not Masks.get(name).direct)
      assert(not Masks.sampler(name, 3, 3))
      local registered = Masks.sampler(name, 3, 3, { heights = heights })
      local original = Surface.sampler(3, 3, heights, false, name)
      for y = 0, 2 do
        for x = 0, 2 do assert(registered(x, y) == original(x, y)) end
      end
    end
    assert(not Masks.sampler("Whole Surface", 3, 3))
  end)

  test("edges and upper and lower masks respect transparency and tile boundaries", function()
    local width, height = 11, 11
    local function footprint(x, y)
      return x >= 2 and x <= 9 and y >= 1 and y <= 9 and (x ~= 8 or y ~= 5)
    end
    local edges = Masks.sampler("Edges", width, height, {}, footprint, { maskWidth = 2 })
    assert(edges(2, 1) == 1 and edges(7, 5) == 1 and edges(8, 5) == 0)
    assert(edges(5, 5) == 0 and edges(3, 6) == 0.5)
    local seamless = Masks.sampler("Edges", width, height, { seamless = true })
    assert(seamless(0, 0) == 0 and seamless(-1, 5) == 0)
    local top = Masks.sampler("Top", width, height, {}, footprint)
    local bottom = Masks.sampler("Bottom", width, height, {}, footprint)
    assert(top(3, 1) == 1 and top(3, 9) == 0 and top(3, 5) == 0.5)
    assert(bottom(3, 1) == 0 and bottom(3, 9) == 1 and bottom(3, 5) == 0.5)
    assert(top(8, 5) == 0 and bottom(1, 3) == 0)
    local tiledTop = Masks.sampler("Top", 8, 32, { seamless = true })
    assert(tiledTop(0, 8) > tiledTop(0, 23))
    assert(math.abs(tiledTop(0, 0) - tiledTop(0, 31)) < 0.10)
    assert(tiledTop(0, 0) == tiledTop(0, 32))
  end)

  test("painted masks read per-effect data and optional generator modules register once", function()
    local footprint = { true, true, false, true }
    local options = { masks = { example = { 0.27, true, 1 } } }
    local painted = Masks.sampler("Painted Mask", 2, 2, options, footprint, { id = "example" })
    assert(painted(0, 0) == 0.27 and painted(1, 0) == 1)
    assert(painted(0, 1) == 0 and painted(1, 1) == 0)
    local calculator = Masks.sampler("Painted Mask", 2, 2, {}, footprint, {
      maskValues = function(x) return x * 2 end,
    })
    assert(calculator(0, 0) == 0 and calculator(1, 0) == 1)
    require("generators.example")(Effects, Masks)
    assert(Masks.get("Example Upper Third").direct and Effects.get("Example Flecks"))
    assert(Masks.sampler("Example Upper Third", 9, 9)(0, 3) == 0)
    assert(not Masks.register { name = "Example Upper Third", sampler = function() end })
    assert(not Masks.register { name = "Invalid mask", direct = "maybe", sampler = function() end })
    local samples = Effects.generator("Example Flecks")(9, 9, { seed = 27, density = 100 })
    assert(#samples == 81)
  end)
end
