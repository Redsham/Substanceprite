local Rain = require("lib.rain")

local function field(width, height, valueAt)
  local result = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      result[y * width + x + 1] = valueAt(x, y)
    end
  end
  return result
end

return function(test)
  test("rain intensity increases water and duration makes it travel farther", function()
    local w, h = 5, 14
    local function sample(intensity, duration)
      return Rain.sampler(w, h, nil, false, nil, {intensity = intensity, duration = duration})
    end
    local light, heavy, long = sample(25, 25), sample(85, 25), sample(25, 90)
    local function downstreamShare(at)
      return at(2, 9) / at(2, 0)
    end
    assert(heavy(2, 0) > light(2, 0))
    assert(heavy(2, 9) > light(2, 9))
    assert(long(2, 9) > light(2, 9))
    assert(downstreamShare(long) > downstreamShare(light) * 1.35)
    for _, dry in ipairs({sample(0, 100), sample(100, 0)}) do
      local flow, retained, exposure = dry(2, 3)
      assert(flow == 0 and retained == 0 and exposure == 0)
    end
  end)

  test("top-facing crests catch descending rain and shelter lower rows", function()
    local w, h = 5, 12
    local raised = field(w, h, function(_, y) return (y == 1 or y == 7) and 0.91 or 0.20 end)
    local before = field(w, h, function(_, y) return y == 1 and 0.91 or 0.20 end)
    local options = { intensity = 70, duration = 70 }
    local at = Rain.sampler(w, h, raised, false, nil, options)
    local original = Rain.sampler(w, h, before, false, nil, options)
    local _, _, top = at(2, 0)
    local _, _, crest = at(2, 1)
    local flow, _, rainShadow = at(2, 2)
    local _, pond = at(2, 6)
    local _, withoutLip = original(2, 6)
    assert(top == 1 and crest > 0.8 and rainShadow < 0.04)
    assert(flow > 0.3 and flow > at(2, 5), "water reaching under a crest continues down the face")
    assert(pond > withoutLip * 2, "the downstream lip retains water")
    for y = 0, 5 do
      assert(at(2, y) == original(2, y), "a lower ledge cannot send water uphill")
    end
  end)

  test("the height field diverts flow into lower channels without crossing holes", function()
    local w, h = 7, 10
    local relief = field(w, h, function(x, y)
      if y == 0 then return 0.65 end
      if x == 2 then return 0.16 end
      if x == 3 then return 0.8 end
      return 0.5
    end)
    local mask = field(w, h, function(x, y) return x == 5 and y == 4 and 0 or true end)
    local at = Rain.sampler(w, h, relief, false, mask, {intensity = 70, duration = 70})
    local flow, retained, exposure = at(2, 2)
    local ridgeFlow, ridgeRetained = at(3, 2)
    assert(flow > ridgeFlow * 3 and retained > ridgeRetained * 3)
    assert(exposure < 0.025)
    local holeFlow, holeRetained, holeExposure = at(5, 4)
    assert(holeFlow == 0 and holeRetained == 0 and holeExposure == 0)
    local _, _, reopened = at(5, 5)
    assert(reopened == 1, "an exposed ledge below a gap catches fresh rain")
  end)

  test("seamless rainfall remains periodic with no artificial top seam", function()
    local w, h = 4, 11
    local at = Rain.sampler(w, h, nil, true, nil, {intensity = 72, duration = 84})
    local tail, retained = at(2, h - 1)
    local head, startRetained = at(2, 0)
    assert(math.abs(tail - head) < 0.00001)
    assert(math.abs(retained - startRetained) < 0.00001)
    for y = 0, h - 1 do
      local a, b, c = at(2, y)
      local x, r, t = at(2 - w, y + h)
      assert(a == x and b == r and c == t and a > 0)
    end
  end)

  test("corner-only contacts across transparency do not transport water", function()
    local function corner(x, y) return (x == 0 and y == 0) or (x == 1 and y == 1) end
    local function alone(x, y) return x == 1 and y == 1 end
    local a = Rain.sampler(3, 3, nil, false, corner)
    local b = Rain.sampler(3, 3, nil, false, alone)
    local flow, retained = a(1, 1)
    local direct, directRetained = b(1, 1)
    assert(flow == direct and retained == directRetained and flow > 0)
  end)

  test("contour routes steer around shallow deposits and retain water at their upstream edge", function()
    local w, h = 13, 18
    local flat = field(w, h, function() return 0.5 end)
    local raised = field(w, h, function(x, y)
      return flat[y * w + x + 1] + ((x >= 5 and x <= 7 and y >= 6 and y <= 10) and 0.063 or 0)
    end)
    local settings = {intensity = 88, duration = 91, contour = true, wrapY = false}
    local flatWater, flatRoutes = Rain.sampler(w, h, flat, false, nil, settings)
    local water, routes = Rain.sampler(w, h, raised, false, nil, settings)
    local flatLeft, flatDown, _, flatPool = flatRoutes(5, 5)
    local left, down, right, pool = routes(5, 5)
    assert(math.abs(left + down + right - 1) < 1e-9, "route fractions must account for all outgoing water")
    assert(flatDown > 0.9 and left > 0.8 and down < flatDown * 0.2)
    assert(routes(5, 4) > flatLeft, "water starts turning before it reaches the deposit")
    local _, flatHeld = flatWater(5, 5)
    local _, held = water(5, 5)
    assert(pool > flatPool and held > 1.25 * flatHeld, "a raised lip holds water before the bypass")

    local _, dryRoutes = Rain.sampler(w, h, raised, false, nil, {intensity = 0, contour = true})
    local a, b, c, p = dryRoutes(5, 5)
    assert(a == 0 and b == 0 and c == 0 and p == 0, "dry weather has no particle routes")
  end)

  test("a horizontal repeat can keep a physical rain inlet at the top", function()
    local w, h = 5, 10
    local first = Rain.sampler(w, h, nil, true, nil, { wrapY = false })
    local raisedBottom = field(w, h, function(_, y) return y == h - 1 and 1 or 0.5 end)
    local second = Rain.sampler(w, h, raisedBottom, true, nil, { wrapY = false })
    assert(second(2, h - 1) > 0)
    local flow, _, exposure = second(2, 0)
    local wrapped, _, wrappedExposure = second(2 - w, 0)
    assert(exposure == 1 and flow == first(2, 0))
    assert(flow == wrapped and exposure == wrappedExposure)
    assert(second(2, -1) == 0 and second(2, h) == 0)
  end)
end
