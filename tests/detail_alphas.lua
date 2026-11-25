local Alphas = require("lib.detail_alphas")

local function rows(sample, width, height)
  local coverage, depth, tone = {}, {}, {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local a, z, t = sample(x, y)
      coverage[#coverage + 1] = string.char(math.floor(a * 255 + 0.5))
      depth[#depth + 1] = string.char(math.floor((z + 1) * 127.5 + 0.5))
      tone[#tone + 1] = string.char(math.floor((t + 1) * 127.5 + 0.5))
    end
  end
  return table.concat(coverage), table.concat(depth), table.concat(tone)
end

return function(test)
  test("detail alpha catalog has stable categories and independent metadata", function()
    local categories = { "Damage", "Grilles", "Hardware" }
    local counts = { 10, 8, 6 }
    local all, offset, seen = Alphas.list(), 0, {}
    for i, name in ipairs(categories) do
      assert(Alphas.categories[i] == name)
      local masks = Alphas.list(name)
      assert(#masks == counts[i])
      for j, mask in ipairs(masks) do
        assert(mask.category == name and mask.id == all[offset + j].id)
        assert(mask.id:match("^[a-z][a-z%-]+[a-z]$") and not seen[mask.id])
        seen[mask.id] = true
        local lookup = Alphas.get(mask.id)
        assert(lookup.name == mask.name and lookup.category == name)
        lookup.name = ""
        assert(Alphas.get(mask.id).name == mask.name)
      end
      offset = offset + #masks
    end
    assert(#all == 24 and all[1].id == Alphas.default)
    assert(not Alphas.get("unknown") and #Alphas.list("unknown") == 0)
    assert(not Alphas.sampler("unknown", 12, 12, 1) and not Alphas.sampler(Alphas.default, 0, 12, 1))
  end)

  test("every detail alpha has a different silhouette and renders at small pixel scales", function()
    local seen = {}
    for _, mask in ipairs(Alphas.list()) do
      local sample = Alphas.sampler(mask.id, 48, 32, 17)
      local cover = rows(sample, 48, 32)
      assert(not seen[cover], ("%s repeats %s"):format(mask.id, seen[cover] or "another mask"))
      seen[cover] = mask.id
      local a, z, t = sample(48, 32)
      assert(a == 0 and z == 0 and t == 0)
      a, z, t = sample(-1, 0)
      assert(a == 0 and z == 0 and t == 0)
      for _, dimensions in ipairs({ {18, 12}, {1, 13}, {15, 1}, {1, 1} }) do
        local width, height = dimensions[1], dimensions[2]
        local small = Alphas.sampler(mask.id, width, height, 19)
        local marked = 0
        for y = 0, height - 1 do
          for x = 0, width - 1 do
            a, z, t = small(x, y)
            assert(a >= 0 and a <= 1 and z >= -1 and z <= 1 and t >= -1 and t <= 1, mask.id)
            if a >= 0.25 then marked = marked + 1 end
            if a == 0 then assert(z == 0 and t == 0) end
          end
        end
        if width > 1 and height > 1 then assert(marked >= 8 and marked < width * height, mask.id) end
      end
    end
  end)

  test("irregular damage masks have repeatable geometry and respond to the seed", function()
    local width, height = 43, 29
    for _, mask in ipairs({ "chip-cluster", "branching-crack", "scratch-bundle", "puncture", "pitted-corrosion" }) do
      local a, z, t = rows(Alphas.sampler(mask, width, height, 53), width, height)
      local ra, rz, rt = rows(Alphas.sampler(mask, width, height, 53), width, height)
      local other = rows(Alphas.sampler(mask, width, height, -271), width, height)
      assert(a == ra and z == rz and t == rt and a ~= other, mask)
    end
  end)

  test("detail relief separates cavities and welded hardware from flat paint", function()
    local width, height = 48, 32
    local dent = Alphas.sampler("impact-dent", width, height, 83)
    local a, z = dent(23, 15)
    assert(a > 0.9 and z < -0.8)
    local bolt = Alphas.sampler("hex-bolt", width, height, 83)
    a, z = bolt(23, 15)
    assert(a > 0.9 and z > 0.22)
    local fan = Alphas.sampler("radial-fan", width, height, 83)
    local recess, raised = 0, 0
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        a, z = fan(x, y)
        if a > 0 and z > 0.35 then raised = raised + 1 end
        if a > 0 and z < -0.4 then recess = recess + 1 end
      end
    end
    assert(raised > 50 and recess > 30)
  end)

  test("dent edges, screw slots and hinge joints remain visible in coverage-only exports", function()
    local width, height, seed = 48, 32, 83
    local dent = Alphas.sampler("impact-dent", width, height, seed)
    assert(dent(23, 15) > 0.90 and dent(24, 4) < 0.65)
    local _, rim = dent(24, 4)
    assert(rim > 0)
    local screw = Alphas.sampler("countersunk-screw", width, height, seed)
    assert(screw(23, 15) < 0.5 and screw(24, 10) > 0.88)
    local hinge = Alphas.sampler("hinge", width, height, seed)
    assert(hinge(24, 10) < 0.5 and hinge(24, 22) < 0.6 and hinge(24, 14) > 0.9)
  end)
end
