local AO = require("lib.ambient_occlusion")

local function index(x, y, width)
  return y * width + x + 1
end

local function grid(width, height, sample)
  local values = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do values[index(x, y, width)] = sample(x, y) end
  end
  return values
end

local function clear(values, count)
  assert(#values == count)
  for _, value in ipairs(values) do assert(value == 0) end
end

return function(test)
  test("ambient occlusion stays clear on flat shapes, convex crests and quantized slopes", function()
    local width, height = 15, 11
    local mask = function(x, y) return x < 13 and y > 0 and not (x == 6 and y >= 4) end
    local flat = grid(width, height, function() return 0.3 end)
    local slope = grid(width, height, function(x, y)
      return math.floor((0.09 + 0.034 * x + 0.022 * y) * 255 + 0.5) / 255
    end)
    local crest = grid(width, height, function(x, y)
      if x < 3 then return 0.95 end
      return 0.69 - 0.014 * (math.abs(x - 8) + math.abs(y - 5))
    end)
    clear(AO.generate(width, height, flat, nil, mask), width * height)
    clear(AO.generate(width, height, slope, { radius = 11 }, mask), width * height)
    assert(AO.generate(width, height, crest, { radius = 4 })[index(8, 5, width)] == 0)
    clear(AO.generate(width, height), width * height)
    clear(AO.generate(width, height, slope, { radius = 0 }), width * height)
  end)

  test("ambient occlusion favors enclosed recesses over nearby raised surfaces", function()
    local width, height = 19, 19
    local heights = grid(width, height, function(x, y)
      local distance = math.max(math.abs(x - 9), math.abs(y - 9))
      return distance <= 2 and 0.14 or 0.78
    end)
    local close = AO.generate(width, height, heights, { radius = 2 })
    local far = AO.generate(width, height, heights, { radius = 7 })
    assert(close[index(9, 9, width)] == 0 and far[index(9, 9, width)] > 0.4)
    assert(far[index(7, 9, width)] > far[index(9, 9, width)])
    assert(far[index(7, 9, width)] == far[index(11, 9, width)])
    assert(far[index(5, 9, width)] == 0 and far[index(0, 0, width)] == 0)
    for _, coverage in ipairs(far) do assert(coverage >= 0 and coverage <= 1) end
  end)

  test("ambient occlusion supports mask holes and stops at disconnected blockers", function()
    local width, height = 15, 9
    local heights = grid(width, height, function(x) return x < 5 and 0.82 or 0.14 end)
    local mask = grid(width, height, function(x) return x == 5 and 0 or true end)
    local continuous = AO.generate(width, height, heights, { radius = 6 })
    assert(continuous[index(7, 4, width)] > 0)
    clear(AO.generate(width, height, heights, { radius = 6 }, mask), width * height)
    for y = 0, height - 1 do heights[index(5, y, width)] = nil end
    clear(AO.generate(width, height, heights, { radius = 6 }), width * height)
  end)

  test("ambient occlusion crops preserve geometry and wrap exactly with seamless enabled", function()
    local width, height = 9, 7
    local heights = grid(width, height, function(x, y)
      return x == 0 and y > 0 and y < 6 and 0.86 or 0.23
    end)
    local normal = AO.generate(width, height, heights, { radius = 4 })
    local settings = { radius = 4, seamless = true }
    local wrapped = AO.generate(width, height, heights, settings)
    assert(normal[index(8, 3, width)] == 0 and wrapped[index(8, 3, width)] > 0)
    local rect = { x = -3, y = -2, width = 12, height = 10 }
    local repeated = AO.generate(width, height, heights, settings, nil, rect)
    local trimmed = AO.generate(width, height, heights, { radius = 4 }, nil, rect)
    for y = 0, rect.height - 1 do
      for x = 0, rect.width - 1 do
        local u, v = x + rect.x, y + rect.y
        local at = index(x, y, rect.width)
        assert(repeated[at] == wrapped[index(u % width, v % height, width)])
        local inside = u >= 0 and u < width and v >= 0 and v < height
        assert(trimmed[at] == (inside and normal[index(u, v, width)] or 0))
      end
    end
  end)
end
