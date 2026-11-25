local Details = require("lib.prop_details")
local Alphas = require("lib.detail_alphas")

local function index(x, y, width)
  return y * width + x + 1
end

local function unchanged(a, b)
  for key, value in pairs(a) do if b[key] ~= value then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end

local function constant()
  return 100, 109, 117, 255
end

return function(test)
  test("alpha stamps change color independently of relief mode and retain selection", function()
    local width, height = 39, 27
    local entry = Details.new("Alpha Stamp")
    entry.width, entry.height, entry.alphaId = 86, 85, "horizontal-louvers"
    local mask = function(x, y) return x > 0 and x < 35 and y ~= 13 end
    local options = { entries = {entry}, mask = mask, seed = 552 }
    local luminance = require("lib.surface").luminance(constant())
    local function stamp(mode)
      entry.reliefMode = mode
      local result = Details.render(width, height, constant, options)
      assert(#result.layers == 1 and result.layers[1].name == Alphas.get(entry.alphaId).name)
      return result
    end
    local raised, cut, flat = stamp("Raised"), stamp("Recessed"), stamp("Color Only")
    local changed = 0
    for i, z in pairs(flat.heights) do
      assert(z == luminance)
      assert(raised.heights[i] >= z and cut.heights[i] <= z)
      if raised.heights[i] > z and cut.heights[i] < z then changed = changed + 1 end
    end
    assert(changed > 20)
    assert(unchanged(raised.layers[1].pixels, flat.layers[1].pixels))
    assert(unchanged(cut.layers[1].pixels, flat.layers[1].pixels))
    local other = Details.new("Alpha Stamp")
    other.width, other.height, other.alphaId = 86, 85, "branching-crack"
    assert(not unchanged(stamp("Auto").layers[1].pixels,
      Details.render(width, height, constant, { entries = {other}, mask = mask, seed = 552 }).layers[1].pixels))
    for i in pairs(flat.layers[1].pixels) do assert(mask((i - 1) % width, (i - 1) // width)) end
  end)

  test("prop detail presets expose independent controls and stable layer order", function()
    assert(#Details.names == 2 and #Details.kinds == 10)
    for _, kind in ipairs(Details.kinds) do
      local entry = Details.new(kind)
      assert(entry.kind == kind and entry.enabled and entry.x == 50 and entry.y == 50)
      assert(entry.strength > 0 and entry.width > 0 and entry.height > 0 and entry.color.a == 255)
    end
    for _, name in ipairs(Details.names) do
      local preset, copy = Details.preset(name), Details.preset(name)
      preset[1].color.r = 0
      assert(copy[1].color.r ~= preset[1].color.r)
      local result = Details.render(169, 63, constant, { entries = copy, seed = 137 })
      assert(#result.layers == #copy)
      for i, layer in ipairs(result.layers) do
        assert(layer.id == copy[i].id and layer.name == copy[i].name and next(layer.pixels))
      end
    end
    assert(Details.preset("unknown") == nil and Details.new("unknown") == nil)
  end)

  test("prop details respect the selected source silhouette and preserve untouched heights", function()
    local width, height = 38, 26
    local function source(x, y)
      return 81, 69, 60, x == 6 and 0 or (y > 4 and 157 or 255)
    end
    local function mask(x, y)
      return x >= 2 and y < 22 and x ~= 24
    end
    local heights = {}
    for y = 0, height - 1 do
      for x = 0, width - 1 do heights[index(x, y, width)] = 0.4 end
    end
    local panel = {
      id = "panel", kind = "Plate", x = 50, y = 55, width = 95, height = 76,
      strength = 100, text = "1",
    }
    local result = Details.render(width, height, source, { entries = { panel }, heights = heights, mask = mask })
    local layer = assert(result.layers[1])
    assert(layer.id == "panel" and layer.name == "Plate")
    assert(result.heights[index(7, 0, width)] == 0.4)
    assert(result.heights[index(19, 12, width)] > 0.4)
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local i, a = index(x, y, width), select(4, source(x, y))
        if not mask(x, y) or a == 0 then
          assert(layer.pixels[i] == nil and result.heights[i] == nil)
        elseif layer.pixels[i] then
          assert((layer.pixels[i] >> 24) <= a and result.heights[i] <= 1)
        end
        assert(heights[i] == 0.4, "input heights are not overwritten")
      end
    end
  end)

  test("stencils follow source light and use text, color and seed independently of relief", function()
    local width, height = 39, 12
    local function source(x)
      local luma = x < 16 and 53 or 187
      return luma, luma, luma, 255
    end
    local stencil = {
      kind = "Stencil", width = 100, height = 100, strength = 100, text = "HH",
      color = { r = 225, g = 211, b = 151, a = 240 },
    }
    local settings = { entries = { stencil }, seed = 123 }
    local first = Details.render(width, height, source, settings)
    local pixels = first.layers[1].pixels
    local dark, light = pixels[index(12, 1, width)], pixels[index(20, 1, width)]
    assert(dark and light and light & 255 > dark & 255)
    assert((dark >> 16) & 255 < dark & 255, "ink keeps its hue")
    local repeatRun = Details.render(width, height, source, settings)
    assert(unchanged(pixels, repeatRun.layers[1].pixels))
    settings.seed = 456
    assert(not unchanged(pixels, Details.render(width, height, source, settings).layers[1].pixels))
    settings.seed = 123
    stencil.text = "HI"
    assert(not unchanged(pixels, Details.render(width, height, source, settings).layers[1].pixels))
    assert(unchanged(first.heights, Details.render(width, height, source).heights), "lettering does not change relief")
  end)

  test("a dent depresses relief and bends an existing corrugated pattern", function()
    local width, height = 62, 34
    local heights = {}
    local function ribs(x)
      local level = x % 6 < 2 and 46 or 155
      return level, level, level, 255
    end
    local function flatCenter()
      return ribs(31)
    end
    for y = 0, height - 1 do
      for x = 0, width - 1 do heights[index(x, y, width)] = 0.52 end
    end
    local dent = { kind = "Dent", width = 70, height = 60, strength = 100 }
    local settings = { entries = { dent }, heights = heights, seed = 31 }
    local result = Details.render(width, height, ribs, settings)
    local plain = Details.render(width, height, flatCenter, settings)
    local center, corner = index(31, 17, width), index(0, 0, width)
    assert(plain.heights[center] < 0.43 and plain.heights[corner] == 0.52)
    assert(result.layers[1].pixels[center] ~= plain.layers[1].pixels[center], "the corrugation should shift within the dent")
    assert(result.layers[1].pixels[corner] == nil)
  end)

  test("fastener rows rotate around the center without adding or removing bolts", function()
    local width, height = 67, 67
    local bolts = { kind = "Fasteners", width = 70, height = 5, count = 3, strength = 100 }
    local options = { entries = { bolts } }
    local flat = Details.render(width, height, constant, options).layers[1].pixels
    bolts.rotation = 90
    local turned = Details.render(width, height, constant, options).layers[1].pixels
    local total, rotated = 0, 0
    for i in pairs(flat) do
      local y, x = (i - 1) // width, (i - 1) % width
      assert(y >= 32 and y <= 34 and turned[index(width - 1 - y, x, width)])
      total = total + 1
    end
    for _ in pairs(turned) do rotated = rotated + 1 end
    assert(total == 15 and total == rotated)
  end)

  test("detail passes handle thin sprites and ignore disabled or zero-strength entries", function()
    for _, kind in ipairs(Details.kinds) do
      local entry = Details.new(kind)
      entry.width, entry.height = 100, 100
      for _, shape in ipairs({ {1, 1}, {1, 20}, {20, 1} }) do
        local width, height = shape[1], shape[2]
        local result = Details.render(width, height, constant, { entries = { entry } })
        assert(#result.heights == width * height)
        for _, layer in ipairs(result.layers) do
          for at, pixel in pairs(layer.pixels) do
            assert(at >= 1 and at <= width * height and pixel > 0)
          end
        end
      end
    end
    local result = Details.render(20, 20, constant, {
      entries = { { kind = "Plate", enabled = false }, { kind = "Dent", strength = 0 } },
    })
    assert(#result.layers == 0 and unchanged(result.heights, Details.render(20, 20, constant).heights))
  end)
end
