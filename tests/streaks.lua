local Streaks = require("lib.streaks")
local Rain = require("lib.rain")

local function grid(width, height, valueAt)
  local result = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do result[y * width + x + 1] = valueAt(x, y) end
  end
  return result
end

local function source(col, row, oxide, tone)
  return function(x, y)
    if x == col and y == row then return oxide, tone end
    return 0
  end
end

return function(test)
  test("rust trails originate at oxide and fade downward on flat surfaces", function()
    local width, height = 9, 14
    local guide = grid(width, height, function(_, y) return y < 4 and 0.8 or 0.2 end)
    local dry = Streaks.sampler(width, height, guide, nil, false, function() return 0 end)
    local disabled = Streaks.sampler(width, height, guide, nil, false, function()
      error("an inactive trail should not sample oxide")
    end, {strength = 0})
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        assert(dry(x, y) == 0 and disabled(x, y) == 0, "height alone made a rust trail")
      end
    end

    local trail = Streaks.sampler(width, height, nil, nil, false, source(4, 2, 0.83, 0.77))
    assert(trail(4, 1) == 0 and trail(4, 2) == 0, "pigment appeared above or on its own source")
    local start, tone = trail(4, 3)
    local tail = trail(4, 9)
    assert(start > 0.10 and tail > 0 and tail < start * 0.4, "trail did not taper down from the source")
    assert(trail(3, 3) < start * 0.2 and trail(5, 3) < start * 0.2, "flat runoff spread too far sideways")
    assert(math.abs(tone - 0.77) < 1e-8, "the source pigment lost its tone on flat terrain")
  end)

  test("a height guide turns rust into lower channels and retains pigment behind a lip", function()
    local width, height = 8, 12
    local oxidized = source(2, 1, 0.90, 0.63)
    local guide = grid(width, height, function(x, y)
      if x == 3 and y >= 2 then return 0.25 end
      return 0.82
    end)
    local flat = Streaks.sampler(width, height, nil, nil, false, oxidized)
    local groove = Streaks.sampler(width, height, guide, nil, false, oxidized)
    local pool = Streaks.sampler(width, height, grid(width, height, function(x, y)
      if x == 3 and y >= 2 and y < 6 then return 0.25 end
      return 0.82
    end), nil, false, oxidized)
    assert(flat(2, 2) > flat(3, 2) * 5, "the base trail must start directly below its origin")
    assert(groove(3, 2) > groove(2, 2) * 2 and groove(3, 4) > 0.05,
           "the lower channel failed to collect downstream pigment")
    local stain, tone = pool(3, 5)
    local openStain, openTone = groove(3, 5)
    assert(stain > openStain * 1.15 and tone < openTone, "the rising lip should darken retained pigment")
    assert(pool(3, 6) == 0, "pigment crossed a retaining lip uphill")
  end)

  test("rust trails stop at mask holes and do not receive pigment from outside the silhouette", function()
    local width, height = 7, 10
    local mask = grid(width, height, function(x, y) return y ~= 4 and not (x == 4 and y == 2) end)
    local trail = Streaks.sampler(width, height, nil, mask, false, function(x, y)
      if x == 2 and y == 1 then return 0.86 end
      if x == 4 and y == 2 then return 1 end
      return 0
    end)
    assert(trail(2, 3) > 0.05, "the last valid parts should still stain")
    assert(trail(4, 2) == 0 and trail(4, 3) < 0.01, "a masked chip sourced pigment")
    for y = 4, height - 1 do
      for x = 0, width - 1 do assert(trail(x, y) == 0, "pigment crossed a transparent gap") end
    end
  end)

  test("rust pigment follows the rain bypass and cannot enter a blocked uphill route", function()
    local width, height = 13, 18
    local guide = grid(width, height, function(x, y)
      return x >= 5 and x <= 7 and y >= 6 and y <= 10 and 0.59 or 0.5
    end)
    local _, routes = Rain.sampler(width, height, guide, false, nil, {contour = true, wrapY = false})
    local left, middle, right = routes(5, 5)
    assert(left == 1 and middle == 0 and right == 0)
    local oxide = source(5, 5, 0.8, 0.71)
    local trail = Streaks.sampler(width, height, guide, nil, false, oxide, {routes = routes})
    assert(trail(4, 6) > 0.1 and trail(5, 6) == 0 and trail(6, 6) == 0,
      "the stain must use the same open branch as the rain particle")
    assert(trail(4, 8) > 0.05 and trail(5, 8) == 0, "the trail should continue around the buildup")
  end)

  test("seamless rust trails cross tile boundaries and compare exactly in different sampling orders", function()
    local width, height = 11, 9
    local guide = grid(width, height, function(x, y)
      return (x == 10 and y == 8) and 0.83 or 0.30
    end)
    local oxidized = source(10, 8, 0.76, 0.81)
    local first = Streaks.sampler(width, height, guide, nil, true, oxidized)
    local crop = Streaks.sampler(width, height, guide, nil, true, oxidized)
    assert(first(10, 0) > 0.10 and first(0, 0) > 0, "pigment did not cross the tile seam")
    for y = height - 1, 0, -1 do
      for x = width - 1, 0, -1 do
        local stain, hue = first(x, y)
        local cropStain, cropHue = crop(x - width, y + 2 * height)
        assert(stain == cropStain and hue == cropHue, "tile crop or sample order changed the trail")
        assert(stain >= 0 and stain <= 1 and hue >= 0 and hue <= 1, "trail samples must be normalized")
      end
    end

    local thin = Streaks.sampler(1, 6, nil, nil, false, source(0, 1, 0.8))
    assert(thin(0, 2) > thin(0, 4) and thin(0, 4) > 0, "one-pixel-wide surfaces should carry a trail")
    local single = Streaks.sampler(1, 1, nil, nil, true, source(0, 0, 1))
    assert(single(0, 0) == 0, "a one-row tile must not drain into itself")
  end)
end
