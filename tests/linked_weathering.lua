local Chips = require("lib.chips")
local Linked = require("lib.linked_weathering")

local width, height = 8, 12
local function index(x, y) return y * width + x + 1 end
local function alpha(value) return value >> 24 end
local function paint() return 84, 91, 78, 255 end

local function controlledMasks()
  local masks = { chips = {}, rust = {}, trails = {}, tones = {} }
  for i = 1, width * height do
    masks.chips[i], masks.rust[i], masks.trails[i], masks.tones[i] = 0, 0, 255, 0
  end
  local origin = index(2, 1)
  masks.chips[origin], masks.rust[origin] = 255, 255
  return masks, origin
end

local function render(masks, params, mask, base)
  return Linked.render(width, height, params, mask, base or paint, masks, masks.tones)
end

local stages = { "chips", "rust", "trails" }

return function(test)
  test("linked weathering preserves seeded chip geometry and records independent mask bytes", function()
    local w, h = 58, 38
    local footprint = {}
    for y = 0, h - 1 do
      for x = 0, w - 1 do footprint[y * w + x + 1] = x >= 2 and x < w - 2 and y ~= 19 end
    end
    local options = { density = 92, intensity = 87, seed = 384, runoff = 100, trails = 0 }
    local legacy = Chips.generate(w, h, options, footprint)
    options.trails = 90
    local generated = Linked.generate(w, h, options, footprint)
    local replay = Linked.generate(w, h, options, function(x, y) return footprint[y * w + x + 1] end)
    local chipped, oxidized = false, false
    for i, sample in ipairs(legacy) do
      assert(generated.chips[i] == (sample & 255) and generated.rust[i] == ((sample >> 16) & 255))
      assert(generated.trails[i] == (footprint[i] and 255 or 0), "the trail permission must follow the footprint")
      for _, name in ipairs(stages) do assert(generated[name][i] == replay[name][i]) end
      assert(generated.tones[i] == replay.tones[i])
      if sample & 255 > 0 then
        chipped = true
        assert(generated.tones[i] > 0, "0 is reserved for newly painted metal")
      end
      if generated.rust[i] > 0 then oxidized = true end
    end
    assert(chipped and oxidized, "a seeded material should contain exposed and oxidized metal")
  end)

  test("painting the linked rust mask adds oxidation and spawns trails without rewriting the steel", function()
    local masks, origin = controlledMasks()
    local before = render(masks, { lighting = 0 })
    local below = index(2, 2)
    assert(alpha(before.chips[origin]) > 0 and alpha(before.rust[origin]) == 255)
    assert(before.trails[origin] == 0 and alpha(before.trails[below]) > 0)

    masks.chips[below], masks.rust[below] = 128, 227
    local painted = render(masks, { lighting = 0 })
    assert(alpha(painted.rust[below]) == 114, "rust must be gated by soft chip coverage")
    assert(painted.trails[below] == 0, "a trail must stay on intact paint")

    masks.chips[below], masks.rust[below], masks.rust[origin] = 0, 0, 0
    masks.rust[index(5, 1)] = 255
    local cleaned = render(masks, { lighting = 0 })
    assert(cleaned.chips[origin] == before.chips[origin], "removing oxide altered the metal")
    for i = 1, width * height do
      assert(cleaned.rust[i] == 0 and cleaned.trails[i] == 0, "rust was not backed by exposed metal")
    end
  end)

  test("trail permission, height channels and native stage opacity affect only downstream weathering", function()
    local masks, origin = controlledMasks()
    local below, groove = index(2, 2), index(3, 2)
    local flat = render(masks, { lighting = 0 })
    local heights = {}
    for y = 0, height - 1 do
      for x = 0, width - 1 do heights[index(x, y)] = x == 3 and y >= 2 and 0.25 or 0.82 end
    end
    local settings = { lighting = 0, surface = { heights = heights } }
    local routed = render(masks, settings)
    assert(alpha(flat.trails[below]) > alpha(flat.trails[groove]) * 5)
    assert(alpha(routed.trails[groove]) > alpha(routed.trails[below]) * 2)
    assert(flat.chips[origin] == routed.chips[origin] and flat.rust[origin] == routed.rust[origin])

    masks.trails[groove] = 128
    local softened = render(masks, settings)
    assert(math.abs(alpha(softened.trails[groove]) * 2 - alpha(routed.trails[groove])) <= 1)
    masks.trails[groove] = 0
    local clipped = render(masks, settings)
    assert(clipped.trails[groove] == 0 and clipped.trails[index(3, 3)] == routed.trails[index(3, 3)])

    local dimmed = render(masks, { lighting = 0, opacity = { rust = 100 } })
    local hidden = render(masks, { lighting = 0, enabled = { rust = false } })
    assert(dimmed.rust[origin] == flat.rust[origin] and hidden.rust[origin] == flat.rust[origin],
      "native rust opacity should not be applied twice")
    assert(alpha(dimmed.trails[below]) < alpha(flat.trails[below]) and hidden.trails[below] == 0)
    local hiddenSteel = render(masks, { lighting = 0, enabled = { chips = false } })
    assert(hiddenSteel.chips[origin] == flat.chips[origin])
    assert(hiddenSteel.rust[origin] == 0 and hiddenSteel.trails[below] == 0)
  end)

  test("repainting source colors relights the three layers and retaining opacity leaves their masks stable", function()
    local masks, origin = controlledMasks()
    local below = index(2, 2)
    local before = render(masks, {})
    local after = render(masks, {}, nil, function(_, y)
      if y < 8 then return 208, 218, 198, 255 end
      return paint()
    end)
    for _, name in ipairs(stages) do
      local at = name == "trails" and below or origin
      assert(before[name][at] ~= after[name][at], name .. " kept stale lighting")
      for i = 1, width * height do
        assert(alpha(before[name][i]) == alpha(after[name][i]), "repainting should only change weathering RGB")
      end
    end
  end)

  test("source transparency and the persistent selection still gate linked masks", function()
    local masks, origin = controlledMasks()
    local faded = render(masks, { lighting = 0 }, nil, function(x, y)
      if index(x, y) == origin then return 84, 91, 78, 128 end
      return paint()
    end)
    assert(alpha(faded.rust[origin]) == 128)
    local cleared = render(masks, {}, function(_, y) return y ~= 4 end, function(_, y)
      if y == 2 then return 84, 91, 78, 0 end
      return paint()
    end)
    assert(cleared.chips[origin] ~= 0 and cleared.rust[origin] ~= 0)
    for y = 2, height - 1 do
      for x = 0, width - 1 do assert(cleared.trails[index(x, y)] == 0, "a stain crossed clear pixels") end
    end
    local excluded = render(masks, {}, function(x, y) return index(x, y) ~= origin end)
    for _, name in ipairs(stages) do
      for i = 1, width * height do assert(excluded[name][i] == 0, "effect leaked outside the selection") end
    end
  end)

  test("linked rust supplies seam-crossing trails only when tiling is enabled", function()
    local masks, origin = controlledMasks()
    masks.chips[origin], masks.rust[origin] = 0, 0
    local seam = index(width - 1, height - 1)
    masks.chips[seam], masks.rust[seam] = 255, 255
    local flat = render(masks, { trails = 100, lighting = 0 })
    local tile = render(masks, { trails = 100, lighting = 0, seamless = true })
    local wrap = index(width - 1, 0)
    assert(flat.trails[wrap] == 0 and alpha(tile.trails[wrap]) > 0)
    assert(tile.rust[seam] == flat.rust[seam] and tile.trails[seam] == 0)
  end)
end
