local Texture = require("lib.texture")
local Weather = require("lib.weather")

local width, height = 69, 51

local function fixture()
  local mask, guide = {}, {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local i = y * width + x + 1
      mask[i] = x < 30 or x > 34
      if x < 30 then
        guide[i] = y < 8 and 0.85 or math.max(0.12, 0.62 - 0.017 * (y - 8))
      elseif x > 34 then
        guide[i] = y < 10 and 0.84 or (y < 18 and 0.16 or 0.78)
      end
    end
  end
  return mask, guide
end

local function options(style, guide)
  return {
    style = style, seed = 5, scale = 5, density = 48, intensity = 70,
    softness = Texture.defaultSoftness(style), runoff = 100,
    surface = { heights = guide, strength = 0 },
  }
end

local function count(set)
  local n = 0
  for _ in pairs(set) do n = n + 1 end
  return n
end

return function(test)
  test("soft dirt follows moving runoff while moss favors retained moisture", function()
    local mask, guide = fixture()
    local weather = Weather.sampler(width, height, guide, false, mask, 5)
    local stream, pool = {}, {}
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local _, flow, retention = weather(x, y)
        local i = y * width + x + 1
        if flow > 0.2 and flow > retention * 1.75 then stream[#stream + 1] = i end
        if retention > 0.28 and retention > flow * 1.40 then pool[#pool + 1] = i end
      end
    end
    assert(#stream > 0 and #pool > 0, "height fixture needs a stream and a pool")

    local function response(style)
      local movingGain, retainedGain = 0, 0
      local settings = options(style, guide)
      local seeds = { 3, 18, 37 }
      for _, seed in ipairs(seeds) do
        settings.seed, settings.runoff = seed, 0
        local dry = Texture.generateSoftDeposit(width, height, settings, mask)
        settings.runoff = 100
        local wet = Texture.generateSoftDeposit(width, height, settings, mask)
        for _, i in ipairs(stream) do movingGain = movingGain + (wet[i] & 255) - (dry[i] & 255) end
        for _, i in ipairs(pool) do retainedGain = retainedGain + (wet[i] & 255) - (dry[i] & 255) end
      end
      return movingGain / (#seeds * #stream), retainedGain / (#seeds * #pool)
    end

    local dirtStream, dirtPool = response("Dirt")
    local mossStream, mossPool = response("Moss")
    assert(dirtStream > 10 and dirtStream > dirtPool + 10, "dirt should follow the stream")
    assert(mossPool > 20 and mossPool > mossStream + 30, "moss should favor lingering moisture")
  end)

  test("soft dirt and moss use intermediate steps and keep tile crops exact", function()
    local mask, guide = fixture()
    local rect = { x = -3, y = height - 5, width = 12, height = 11 }
    for _, style in ipairs({ "Dirt", "Moss" }) do
      local settings = options(style, guide)
      settings.seamless = true
      local colors = Texture.defaultColors(style)
      local full = Texture.generateSoftDeposit(width, height, settings, mask)
      local crop = Texture.generateSoftDeposit(width, height, settings, mask, rect)
      local tones, alphas = {}, {}
      for i, sample in ipairs(full) do
        if not mask[i] then assert(sample == 0, style .. " painted outside the silhouette") end
        local r, g, b, a = Texture.softDepositSample(sample, colors)
        if r then tones[(r << 16) | (g << 8) | b], alphas[a] = true, true end
      end
      assert(count(tones) >= 12 and count(alphas) >= 12, style .. " needs intermediate color and opacity")
      for y = 0, rect.height - 1 do
        for x = 0, rect.width - 1 do
          local src = ((y + rect.y) % height) * width + (x + rect.x) % width + 1
          assert(crop[y * rect.width + x + 1] == full[src], style .. " crop differs from the wrapped tile")
        end
      end
    end
  end)

  test("soft rust has pronounced cores, intermediate tones and faint edges", function()
    local mask = fixture()
    local settings = { seed = 5, scale = 5, density = 65, intensity = 70, softness = 75, runoff = 0 }
    local peak, faint = 0, 0
    local tones = {}
    for _, sample in ipairs(Texture.generateRust(width, height, settings, mask)) do
      local coverage = sample & 255
      peak = math.max(peak, coverage)
      if coverage > 0 then
        tones[sample >> 8] = true
        if coverage < 28 then faint = faint + 1 end
      end
    end
    assert(peak >= 157 and count(tones) >= 20 and faint >= 15,
      "rust should have solid interiors, color variation and soft edges")
  end)
end
