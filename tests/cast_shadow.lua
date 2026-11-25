local CastShadow = require("lib.cast_shadow")

local function index(x, y, width)
  return y * width + x + 1
end

local function grid(width, height, valueAt)
  local values = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do values[index(x, y, width)] = valueAt(x, y) end
  end
  return values
end

return function(test)
  test("a height ridge casts a shadow away from the light without dimming the top", function()
    local width, height = 14, 12
    local heights = grid(width, height, function(x) return x == 9 and 0.72 or 0.12 end)
    local right = CastShadow.generate(width, height, heights,
      { angle = 0, elevation = 35, reach = 6, softness = 0 })
    local left = CastShadow.generate(width, height, heights,
      { angle = 180, elevation = 35, reach = 6, softness = 0 })
    assert(right[index(6, 5, width)] == 1 and left[index(6, 5, width)] == 0)
    assert(left[index(12, 5, width)] == 1 and right[index(12, 5, width)] == 0)
    assert(right[index(9, 5, width)] == 0 and left[index(9, 5, width)] == 0)
    assert(right[index(1, 5, width)] == 0, "shadow exceeds the projected ridge height")

    heights = grid(width, height, function(_, y) return y == 8 and 0.72 or 0.12 end)
    local below = CastShadow.generate(width, height, heights, { angle = 90, softness = 0 })
    assert(below[index(6, 7, width)] == 1 and below[index(6, 9, width)] == 0)
  end)

  test("lower light projects farther and zero relief yields a dense clear field", function()
    local width, height = 21, 4
    local heights = grid(width, height, function(x) return x == 15 and 0.7 or 0.14 end)
    local low = CastShadow.generate(width, height, heights,
      { angle = 0, elevation = 22, reach = 7, softness = 0 })
    local high = CastShadow.generate(width, height, heights,
      { angle = 0, elevation = 68, reach = 7, softness = 0 })
    assert(low[index(8, 2, width)] == 1 and high[index(8, 2, width)] == 0)
    assert(high[index(14, 2, width)] == 1)
    local zero = CastShadow.generate(width, height, heights, { reach = 0 })
    local missing = CastShadow.generate(width, height)
    assert(#zero == width * height and #missing == #zero)
    for i, coverage in ipairs(zero) do assert(coverage == 0 and missing[i] == 0) end
  end)

  test("flat height, holes and masked blockers leave the field unshadowed", function()
    local heights = { 0.6, 0.6, 0.6, nil, 0.6, 1, 0.6 }
    local mask = { true, true, true, true, true, 0, true }
    local settings = { angle = 0, elevation = 15, reach = 12, softness = 0 }
    local flat = CastShadow.generate(7, 1, heights, settings, mask)
    for _, coverage in ipairs(flat) do assert(coverage == 0) end

    mask[6] = true
    local open = CastShadow.generate(7, 1, heights, settings, mask)
    assert(open[3] == 1, "a shadow ray should pass across a hole to a real receiver")
    assert(open[4] == 0, "a missing receiver cannot display shadow")
    assert(open[6] == 0 and open[7] == 0)
    local selected = CastShadow.generate(7, 1, heights, settings, function(x) return x < 2 end)
    for _, coverage in ipairs(selected) do assert(coverage == 0) end
  end)

  test("shadow softness fades the far edge without washing out contact", function()
    local width, height = 16, 11
    local heights = grid(width, height, function(x) return x == 11 and 0.64 or 0.1 end)
    local hard = CastShadow.generate(width, height, heights,
      { angle = 0, elevation = 35, reach = 10, softness = 0 })
    local soft = CastShadow.generate(width, height, heights,
      { angle = 0, elevation = 35, reach = 10, softness = 100 })
    assert(soft[index(10, 5, width)] == 1 and hard[index(10, 5, width)] == 1)
    assert(soft[index(3, 5, width)] > 0 and soft[index(3, 5, width)] < 1)
    assert(soft[index(0, 5, width)] < 0.05 and soft[index(12, 5, width)] == 0)
    for i, coverage in ipairs(soft) do
      assert(coverage >= 0 and coverage <= 1)
      assert(hard[i] == 0 or hard[i] == 1)
    end
  end)

  test("seamless shadow rays wrap and cropped output matches the full tile", function()
    local width, height = 8, 5
    local heights = grid(width, height, function(x, y) return x == 0 and y < 3 and 0.8 or 0.2 end)
    local settings = { angle = 0, elevation = 35, reach = 10, softness = 30 }
    local unwrapped = CastShadow.generate(width, height, heights, settings)
    settings.seamless = true
    local tile = CastShadow.generate(width, height, heights, settings)
    assert(unwrapped[index(7, 1, width)] == 0 and tile[index(7, 1, width)] == 1)
    local rect = { x = -2, y = -1, width = 12, height = 7 }
    local repeated = CastShadow.generate(width, height, heights, settings, nil, rect)
    for y = 0, rect.height - 1 do
      for x = 0, rect.width - 1 do
        assert(repeated[index(x, y, rect.width)] ==
          tile[index((x + rect.x) % width, (y + rect.y) % height, width)])
      end
    end
    settings.angle = 360
    local rotated = CastShadow.generate(width, height, heights, settings)
    for i, coverage in ipairs(rotated) do assert(math.abs(coverage - tile[i]) < 1e-10) end
  end)
end
