local Wear = require("lib.paint_wear")

local function total(values)
  local sum = 0
  for _, value in ipairs(values) do sum = sum + value end
  return sum
end

local function directionalChange(values, width, height)
  local xChange, yChange = 0, 0
  for y = 0, height - 2 do
    for x = 0, width - 2 do
      local i = y * width + x + 1
      xChange = xChange + math.abs(values[i + 1] - values[i])
      yChange = yChange + math.abs(values[i + width] - values[i])
    end
  end
  return xChange, yChange
end

return function(test)
  test("paint wear settings produce deterministic coverage and retain zero-effect defaults", function()
    local width, height = 63, 43
    local function sample(amount, seed)
      return Wear.generate(width, height, {
        edgeWear = amount, scuffs = amount, fading = amount, seed = seed,
      })
    end
    local clean = Wear.generate(width, height)
    local mild, strong, repeatStrong = sample(28, 421), sample(82, 421), sample(82, 421)
    local changedSeed = sample(82, 412)
    for name, values in pairs(clean) do
      assert(#values == width * height and total(values) == 0, name)
      local difference = false
      for i, value in ipairs(strong[name]) do
        assert(value == repeatStrong[name][i] and value >= 0 and value <= 255, name)
        if value ~= changedSeed[name][i] then difference = true end
      end
      assert(difference == (name ~= "bevel"), name)
    end
    for _, name in ipairs({ "edge", "scuff", "fading" }) do
      assert(total(strong[name]) > total(mild[name]), name)
    end
  end)

  test("edge wear is broken along the silhouette and clips around transparent holes", function()
    local width, height = 52, 44
    local function visible(x, y)
      return x >= 3 and x <= 48 and y >= 3 and y <= 40
        and not (x >= 18 and x <= 22 and y >= 16 and y <= 22)
    end
    local settings = { edgeWear = 100, scuffs = 100, fading = 100, edgeWidth = 1, seed = 123 }
    local narrow = Wear.generate(width, height, settings, visible)
    settings.edgeWidth = 4
    local broad = Wear.generate(width, height, settings, visible)
    local outside, holeRim, exposed, rim = 0, 0, 0, 0
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local i = y * width + x + 1
        if not visible(x, y) then
          for _, values in pairs(broad) do assert(values[i] == 0) end
        elseif x == 3 or x == 48 or y == 3 or y == 40 then
          rim = rim + 1
          if narrow.edge[i] > 0 then exposed = exposed + 1 end
        elseif x == 17 and y >= 16 and y <= 22 then
          holeRim = holeRim + narrow.edge[i]
        else
          outside = outside + broad.edge[i] - narrow.edge[i]
        end
        if x == 36 and y == 22 then assert(broad.edge[i] == 0, "flat interior has no edge") end
      end
    end
    assert(exposed > 0 and exposed < rim, "wear follows portions of the contour without tracing it continuously")
    assert(holeRim > 0, "inner rim rubs where the cutout exposes it")
    assert(outside > 0 and total(broad.edge) > total(narrow.edge), "wider edge wear reaches farther inland")
  end)

  test("relief wear picks a raised lip and leaves a flat seamless tile unmarked", function()
    local width, height = 48, 36
    local elevations = {}
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        elevations[y * width + x + 1] = x >= 15 and x <= 24 and 0.84 or 0.25
      end
    end
    local settings = { edgeWear = 100, edgeWidth = 1, seamless = true, seed = 678 }
    assert(total(Wear.generate(width, height, settings).edge) == 0, "tile edges are not outside borders")
    settings.surface = { heights = elevations }
    local edge = Wear.generate(width, height, settings).edge
    local lip = 0
    for y = 0, height - 1 do
      local first = y * width + 1
      lip = lip + edge[first + 15] + edge[first + 24]
      assert(edge[first + 12] == 0 and edge[first + 25] == 0 and edge[first + 20] == 0)
    end
    assert(lip > 0, "only the high sides of a raised lip are exposed")
  end)

  test("bevel wear detects convex shoulders without marking ramps, recess floors or missing relief", function()
    local width, height = 54, 40
    local raised, linear, flat = {}, {}, {}
    local shoulder = {[17] = 0.33, [18] = 0.62, [19] = 0.82, [20] = 0.90, [21] = 0.93}
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local i = y * width + x + 1
        raised[i] = shoulder[x] or (x > 21 and x < 42 and 0.93 or 0.18)
        if x >= 32 and x <= 40 then raised[i] = 0.33 + math.abs(x - 36) * 0.11 end
        linear[i] = 0.15 + 0.7 * x / (width - 1)
        flat[i] = 0.66
      end
    end
    for _, map in ipairs({flat, linear}) do
      local wear = Wear.generate(width, height, {bevelWear = 100, bevelWidth = 6, heights = map})
      assert(total(wear.bevel) == 0)
    end
    assert(total(Wear.generate(width, height, {bevelWear = 100}).bevel) == 0)
    assert(total(Wear.generate(width, height, {heights = raised}).bevel) == 0)

    local settings = {bevelWear = 100, heights = raised, seed = 42}
    local bevel = Wear.generate(width, height, settings).bevel
    local repeatBevel = Wear.generate(width, height, settings).bevel
    for i, value in ipairs(bevel) do assert(value == repeatBevel[i]) end
    settings.bevelWear = 50
    assert(total(Wear.generate(width, height, settings).bevel) < total(bevel))
    local upper = 0
    for y = 0, height - 1 do
      local row = y * width + 1
      upper = upper + bevel[row + 18] + bevel[row + 19]
      assert(bevel[row + 17] == 0 and bevel[row + 26] == 0 and bevel[row + 36] == 0)
    end
    assert(upper > 0, "convex rounded shoulder should expose paint")
  end)

  test("bevel width stays on the raised surface and wraps only in seamless mode", function()
    local width, height = 54, 40
    local highs, tile = {}, {}
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local i = y * width + x + 1
        highs[i] = x >= 16 and x <= 34 and 0.86 or 0.19
        tile[i] = x <= 8 and 0.86 or 0.19
      end
    end
    local settings = {bevelWear = 100, bevelWidth = 1, heights = highs, seed = 42}
    local narrow = Wear.generate(width, height, settings).bevel
    settings.bevelWidth = 6
    local wide = Wear.generate(width, height, settings).bevel
    local cut = Wear.generate(width, height, settings, function(x) return x ~= 19 end).bevel

    settings.heights, settings.bevelWidth = tile, 1
    local unwrapped = Wear.generate(width, height, settings).bevel
    settings.seamless = true
    local wrapped = Wear.generate(width, height, settings).bevel
    local inner, tiledRim, full, broken = 0, 0, false, false
    for y = 0, height - 1 do
      local row = y * width + 1
      local shoulder = narrow[row + 16]
      full, broken = full or shoulder == 255, broken or shoulder < 128
      inner = inner + wide[row + 20]
      tiledRim = tiledRim + wrapped[row]
      assert(narrow[row + 20] == 0 and wide[row + 15] == 0)
      assert(cut[row + 19] == 0 and cut[row + 20] == 0 and unwrapped[row] == 0)
      assert(wrapped[row + width - 1] == 0, "low side of a wrapped ridge remains covered")
    end
    assert(inner > 0 and tiledRim > 0 and full and broken)
  end)

  test("scuff direction turns the marks and fading remains a broad surface effect", function()
    local width, height = 72, 64
    local settings = { scuffs = 90, fading = 85, seed = 711, scuffDirection = "Horizontal" }
    local horizontal = Wear.generate(width, height, settings)
    settings.scuffDirection = "Vertical"
    local vertical = Wear.generate(width, height, settings)
    local hx, hy = directionalChange(horizontal.scuff, width, height)
    local vx, vy = directionalChange(vertical.scuff, width, height)
    assert(hx * 2 < hy and vy * 2 < vx, "scuffs should be elongated along the chosen axis")
    local betweenNeighbors, betweenPatches = 0, 0
    for y = 0, height - 1 do
      for x = 0, width - 13 do
        local i = y * width + x + 1
        assert(horizontal.fading[i] == vertical.fading[i], "fading is independent of scuff direction")
        betweenNeighbors = betweenNeighbors + math.abs(horizontal.fading[i] - horizontal.fading[i + 1])
        betweenPatches = betweenPatches + math.abs(horizontal.fading[i] - horizontal.fading[i + 12])
      end
    end
    assert(betweenNeighbors * 5 < betweenPatches)
  end)

  test("scuff clusters have long cores and partially covered tips", function()
    local width, height = 80, 52
    local result = Wear.generate(width, height, {
      scuffs = 90, seed = 711, scuffDirection = "Horizontal", seamless = true,
    })
    local strongRuns, longRuns, softenedRuns = 0, 0, 0
    for y = 0, height - 1 do
      local runLength = 0
      for x = 0, width - 1 do
        local i = y * width + x + 1
        if result.scuff[i] > 70 then
          runLength = runLength + 1
        elseif runLength > 0 then
          strongRuns = strongRuns + 1
          if runLength >= 8 then longRuns = longRuns + 1 end
          if result.scuff[i] > 0 then softenedRuns = softenedRuns + 1 end
          runLength = 0
        end
      end
    end
    assert(strongRuns > 20 and longRuns > strongRuns * 0.4)
    assert(softenedRuns > strongRuns * 0.8, "most marks have a gradual tip")
  end)

  test("raised detail protects lower paint from scuffs and fades more on upward slopes", function()
    local width, height = 80, 52
    local ledge = {}
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        ledge[y * width + x + 1] = y >= 20 and y <= 38 and 0.82 or 0.18
      end
    end
    local settings = {
      edgeWear = 100, edgeWidth = 4, scuffs = 90, fading = 100,
      seed = 42, scuffDirection = "Horizontal", seamless = true,
    }
    local flat = Wear.generate(width, height, settings)
    settings.heights = ledge
    local raised = Wear.generate(width, height, settings)
    local up, down, scuffed, protected = 0, 0, 0, 0
    local tangentChange, outwardChange = 0, 0
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local i = y * width + x + 1
        if y >= 18 and y <= 21 then up = up + raised.fading[i] - flat.fading[i] end
        if y >= 37 and y <= 40 then down = down + raised.fading[i] - flat.fading[i] end
        if (y == 19 or y == 39) and flat.scuff[i] > 25 then
          scuffed = scuffed + 1
          if raised.scuff[i] < flat.scuff[i] * 0.5 then protected = protected + 1 end
        end
        if x < width - 1 and y >= 20 and y <= 22 then
          tangentChange = tangentChange + math.abs(raised.edge[i + 1] - raised.edge[i])
          outwardChange = outwardChange + math.abs(raised.edge[i + width] - raised.edge[i])
        end
      end
    end
    assert(up > 0 and down < 0, "upward-facing paint weathers more than the sheltered underside")
    assert(scuffed > 0 and protected > scuffed * 0.8, "contact does not scrape through a recess")
    assert(outwardChange > 2 * tangentChange, "wear extends along the ledge and falls off inward")
  end)
end
