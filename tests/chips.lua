local Chips = require("lib.chips")

local function fixture(width, height)
  local heights, mask = {}, {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local i = y * width + x + 1
      local hole = (x - width / 2)^2 + (y - height / 2)^2 < 25
      if not hole then
        mask[i] = true
        local band = y % 14
        heights[i] = band < 3 and 0.88 or (band < 10 and 0.15 or 0.64)
      end
    end
  end
  return heights, mask
end

return function(test)
  test("paint damage has soft edges, fresh steel and corrosion restricted to exposed metal", function()
    local width, height = 70, 56
    local heights, mask = fixture(width, height)
    local options = { seed = 919, density = 64, scale = 4, softness = 75, trails = 0,
      surface = { heights = heights, strength = 70 } }
    local samples = Chips.generate(width, height, options, mask)
    local alphas, clean, rust, removed = {}, 0, 0, 0
    for i, sample in ipairs(samples) do
      if not mask[i] then assert(sample == 0, "damage entered a transparent hole") end
      if sample > 0 then
        local oxide = (sample >> 16) & 255
        local exposed = (sample >> 24) & 255
        assert(oxide <= exposed, "oxide crossed into intact paint")
        local r, g, b, a, relief = Chips.sample(sample)
        assert(r and a > 0 and a <= 255)
        alphas[a] = true
        if oxide == 0 and exposed > 100 then
          assert(math.abs(r - b) <= 9, "fresh chip should show neutral steel")
          clean = clean + 1
        end
        if oxide > 110 then
          assert(r - b >= 10, "oxidized chip should have a warm rust color")
          rust = rust + 1
        end
        if relief < 0 then removed = removed + 1 end
      end
    end
    local steps = 0
    for _ in pairs(alphas) do steps = steps + 1 end
    assert(clean > 5 and rust > 5 and removed > 20 and steps > 10,
      "paint damage lacks readable steel, corrosion or soft edges")
    options.density = 0
    for _, sample in ipairs(Chips.generate(width, height, options, mask)) do assert(sample == 0) end
  end)

  test("retained moisture ages the same chips without adding new paint damage", function()
    local width, height = 72, 54
    local heights, mask = fixture(width, height)
    local options = { seed = 97, density = 69, scale = 4, runoff = 75, trails = 0 }
    local dry = Chips.generate(width, height, options, mask)
    options.surface = { heights = heights, strength = 0 }
    local wet = Chips.generate(width, height, options, mask)
    local affected = 0
    for i, sample in ipairs(dry) do
      assert((sample & 0xff00ffff) == (wet[i] & 0xff00ffff),
        "water must not change the paint damage mask or steel tone")
      local old, new = (sample >> 16) & 255, (wet[i] >> 16) & 255
      assert(new >= old, "added moisture reduced oxidation")
      if new > old + 12 then affected = affected + 1 end
    end
    assert(affected > 25, "retained moisture did not measurably age enough exposed chips")

    options.surface = nil
    options.runoff = 0
    local fresh = Chips.generate(width, height, options, mask)
    local ageInDryAir = 0
    for i, sample in ipairs(fresh) do
      assert(sample == (dry[i] & 0xff00ffff), "corrosion at zero must leave the same fresh steel")
      if dry[i] ~= sample then ageInDryAir = ageInDryAir + 1 end
    end
    assert(ageInDryAir > 25, "corrosion control has no effect without a height map")
  end)

  test("paint damage elongates along raised seams in either direction", function()
    local width, height = 92, 80
    for _, alongX in ipairs({ true, false }) do
      local heights = {}
      for y = 0, height - 1 do
        for x = 0, width - 1 do
          local band = (alongX and y or x) % 20
          heights[y * width + x + 1] = band == 7 and 0.80 or ((band == 8 or band == 6) and 0.49 or 0.31)
        end
      end
      local horizontal, vertical = 0, 0
      for _, seed in ipairs({ 41, 219, 487 }) do
        local samples = Chips.generate(width, height, {
          density = 48, seed = seed, trails = 0, runoff = 0,
          surface = { heights = heights, strength = 100 },
        })
        for y = 5, height - 6 do
          for x = 5, width - 6 do
            local band = (alongX and y or x) % 20
            local index = y * width + x + 1
            if band >= 5 and band <= 9 and (samples[index] & 255) > 42 then
              if (samples[index + 1] & 255) > 42 then horizontal = horizontal + 1 end
              if (samples[index + width] & 255) > 42 then vertical = vertical + 1 end
            end
          end
        end
      end
      local along, across = alongX and horizontal or vertical, alongX and vertical or horizontal
      assert(along > 100 and along > across * 1.35, "scrapes did not follow the seam rather than crossing it")
    end
  end)

  test("rust trails stain the paint without changing the original chip pixels", function()
    local width, height = 78, 52
    local heights, mask = fixture(width, height)
    local options = { seed = 219, density = 51, scale = 4, runoff = 95, trails = 0,
      surface = { heights = heights, strength = 55 } }
    local baseline = Chips.generate(width, height, options, mask)
    options.trails = 100
    local stained = Chips.generate(width, height, options, mask)
    local changed = 0
    for i, sample in ipairs(stained) do
      local stain = Chips.trail(sample)
      assert((sample & 0xffffffff) == baseline[i], "trails changed chip geometry or pigment")
      if stain > 0 then
        assert(mask[i] and baseline[i] == 0, "trail overlapped a hole or exposed metal")
        local r, g, b, a, relief = Chips.sample(sample)
        assert(r > g and g > b and a == stain and relief == 0,
          "the trail must tint paint with no change in relief")
        changed = changed + 1
      end
    end
    assert(changed > 30, "the selected oxidized chips did not produce visible runoff")

    options.runoff = 0
    for _, sample in ipairs(Chips.generate(width, height, options, mask)) do
      assert(Chips.trail(sample) == 0, "fresh steel produced a rust trail")
    end
  end)

  test("paint damage, rust trails and transparent holes repeat exactly in seamless crops", function()
    local width, height = 37, 26
    local heights, mask = fixture(width, height)
    local options = { seed = 487, density = 70, scale = 4, runoff = 100, bottom = 50, trails = 100,
      seamless = true, surface = { heights = heights } }
    local plain = Chips.generate(width, height, options, mask)
    local rect = { x = width - 5, y = -3, width = 11, height = 13 }
    local crop = Chips.generate(width, height, options, mask, rect)
    for y = 0, rect.height - 1 do
      for x = 0, rect.width - 1 do
        local wrapped = ((rect.y + y) % height) * width + (rect.x + x) % width + 1
        assert(crop[y * rect.width + x + 1] == plain[wrapped], "paint damage changed at a tile edge")
      end
    end
    local thin = Chips.generate(1, 7, options, nil)
    assert(#thin == 7, "a thin sprite should keep its requested dimensions")
  end)
end
