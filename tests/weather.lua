local Weather = require("lib.weather")

local function guide(width, height, sample)
  local heights = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do heights[y * width + x + 1] = sample(x, y) end
  end
  return heights
end

local function ledge(x, y)
  if x >= 2 and x <= 6 and (y == 2 or y == 3) then return 0.82 end
  return 0.26
end

return function(test)
  test("rainfall is neutral on missing and flat height guides", function()
    local flat = guide(7, 5, function(x) if x ~= 3 then return 0.4 end end)
    for _, sample in ipairs({
      Weather.sampler(7, 5, nil),
      Weather.sampler(7, 5, {}),
      Weather.sampler(7, 5, flat, true),
    }) do
      for y = 0, 4 do
        for x = 0, 6 do
          local bias, flow, retained, sediment = sample(x, y)
          assert(bias == 0 and flow == 0 and retained == 0 and sediment == 0,
                 "flat guides must not add an artificial drip or edge")
        end
      end
    end
  end)

  test("moisture persists in shelters while sediment follows and settles from runoff", function()
    local width, height = 12, 14
    local open = Weather.sampler(width, height, guide(width, height, ledge))
    local pocket = Weather.sampler(width, height, guide(width, height, function(x, y)
      if x >= 2 and x <= 6 and y == 7 then return 0.75 end
      return ledge(x, y)
    end))
    local _, openFlow, openMoisture, openSediment = open(4, 6)
    local _, pocketFlow, pocketMoisture, pocketSediment = pocket(4, 6)
    assert(math.abs(openFlow - pocketFlow) < 1e-8, "a lower lip cannot create an upstream inflow")
    assert(pocketMoisture > openMoisture + 0.25, "a damp pocket should stay wetter than a drain")
    assert(pocketSediment > openSediment, "sediment should settle as a track reaches a lower lip")

    local slope = Weather.sampler(width, height, guide(width, height, function(x, y)
      if x >= 2 and x <= 6 then return math.max(0.18, 0.96 - y * 0.086) end
      return 0.26
    end))
    local _, slopeFlow, slopeMoisture, slopeSediment = slope(4, 5)
    assert(slopeFlow > 0.1 and slopeSediment > 0.08, "the slope should carry sediment with passing water")
    assert(slopeMoisture < 0.05, "a draining slope should not be mistaken for a stagnant pool")
  end)

  test("rain runs down from a ledge and accumulates where lower relief retains it", function()
    local root = Weather.sampler(12, 14, guide(12, 14, ledge))
    local basin = Weather.sampler(12, 14, guide(12, 14, function(x, y)
      if x >= 2 and x <= 6 and y == 7 then return 0.75 end
      return ledge(x, y)
    end))
    local dip, flow = root(4, 4)
    local farther, fartherFlow = root(4, 10)
    assert(dip > 0.35 and flow > 0.3, "the area immediately below the ledge receives runoff")
    local _, aboveFlow = root(4, 1)
    assert(root(4, 3) < 0 and aboveFlow == 0, "water should not travel up the exposed ledge")
    assert(root(10, 4) < 0.03 and farther < dip * 0.3 and fartherFlow < flow,
           "runoff remains local and fades as it travels")
    assert(basin(4, 6) > root(4, 6) + 0.12, "the lower lip should retain runoff")
  end)

  test("rainfall follows a lower diagonal route and stops at a disconnected gap", function()
    local diagonal = Weather.sampler(8, 8, guide(8, 8, function(x, y)
      if x == 4 and y >= 3 then return 0.24 end
      return 0.82
    end))
    local _, onChannel = diagonal(4, 4)
    local _, onPlate = diagonal(3, 4)
    assert(onChannel > onPlate + 0.1, "a shallow neighboring route should collect runoff")

    local mask = guide(12, 14, function(_, y) return y ~= 5 end)
    local clipped = Weather.sampler(12, 14, guide(12, 14, ledge), false, mask)
    local _, aboveGap = clipped(4, 4)
    assert(aboveGap > 0.3, "clipping must retain the last valid wet pixel")
    for y = 5, 10 do
      local bias, flow, retained, sediment = clipped(4, y)
      assert(bias == 0 and flow == 0 and retained == 0 and sediment == 0,
             "a transparent gap cannot act as a basin or route")
    end
  end)

  test("tiled rainfall is independent of sample order and repeats through both edges", function()
    local width, height = 12, 14
    local heights = guide(width, height, function(x, y)
      if x >= 2 and x <= 6 and y == height - 1 then return 0.82 end
      return 0.26
    end)
    local sample = Weather.sampler(width, height, heights, true)
    local crop = Weather.sampler(width, height, heights, true)
    local bias, acrossSeam = sample(4, 0)
    assert(bias > 0 and acrossSeam > 0.3, "rain from the last tile row should reach the first")
    for y = height - 1, 0, -1 do
      for x = 0, width - 1 do
        local values = { sample(x, y) }
        local wrapped = { crop(x - width, y + 2 * height) }
        assert(#values == 4, "a sample must have all four weather channels")
        for i, value in ipairs(values) do
          assert(value == wrapped[i], "wrap or sample order changed weather")
          assert(value >= (i == 1 and -1 or 0) and value <= 1,
                 "weather output must stay in range")
        end
      end
    end

    local thin = Weather.sampler(1, 4, { 0.8, 0.8, 0.3, 0.3 })
    local _, thinFlow = thin(0, 2)
    assert(thinFlow > 0, "one-pixel tracks can still carry rain")
  end)
end
