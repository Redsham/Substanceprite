local Lighting = require("lib.material_lighting")
local Scene = require("lib.scene_lighting")

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

local function byte(value)
  return math.floor(math.min(255, math.max(0, value)) + 0.5)
end

local function composite(r, g, b, overlay)
  if not overlay then return r, g, b end
  local a = (overlay >> 24) / 255
  return byte(r + ((overlay & 255) - r) * a),
    byte(g + (((overlay >> 8) & 255) - g) * a),
    byte(b + (((overlay >> 16) & 255) - b) * a)
end

local function renderOptions()
  return {
    directLight = true, lightAngle = 0, lightStrength = 78, lightElevation = 41,
    lightColor = { r = 248, g = 181, b = 120, a = 255 }, normalStrength = 64,
    ao = true, aoStrength = 67, aoRadius = 6,
    shadows = true, shadowStrength = 71, shadowReach = 12, shadowSoftness = 18,
  }
end

return function(test)
  test("separate scene-light layers reproduce shaded colors without replacing the underlying art", function()
    local width, height = 23, 17
    local heights = grid(width, height, function(x, y)
      if x == 12 then return 0.84 end
      return 0.12 + 0.018 * x + 0.011 * y
    end)
    local function art(x, y)
      return 38 + 9 * (x % 14), 34 + 7 * (y % 15), 90 + 9 * ((x + y) % 10), 255
    end
    local options = renderOptions()
    local straight = Lighting.shader(width, height, heights, options, nil)
    local result = Scene.render(width, height, heights, options, nil, art)
    assert(next(result.light) and next(result.ao) and next(result.shadows))
    assert(#result.aoMap == width * height and #result.shadowMap == width * height)

    local lit, darkened, partial = 0, 0, 0
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local i = index(x, y, width)
        local r, g, b = art(x, y)
        local rr, gg, bb = straight(r, g, b, i)
        local dr, dg, db = composite(r, g, b, result.light[i])
        if dr > r then lit = lit + 1 end
        if db < b then darkened = darkened + 1 end
        if result.light[i] and result.light[i] >> 24 < 255 then partial = partial + 1 end
        dr, dg, db = composite(dr, dg, db, result.ao[i])
        dr, dg, db = composite(dr, dg, db, result.shadows[i])
        assert(math.abs(dr - byte(rr)) <= 2 and math.abs(dg - byte(gg)) <= 2 and math.abs(db - byte(bb)) <= 2)
      end
    end
    assert(lit > 0 and darkened > 0 and partial > width)
  end)

  test("scene overlays are independent and raw diagnostic maps ignore effect opacity", function()
    local width, height = 18, 10
    local relief = grid(width, height, function(x) return x == 11 and 0.82 or 0.12 end)
    local function art() return 100, 117, 139 end
    local settings = { ao = true, aoStrength = 100, shadows = true, shadowStrength = 0, lightAngle = 0 }
    local result = Scene.render(width, height, relief, settings, nil, art)
    assert(next(result.ao) and next(result.light) == nil and next(result.shadows) == nil)
    assert(result.aoMap and not result.shadowMap)
    local shadowMap = Scene.map(width, height, relief, settings, nil, art, nil, Lighting.shadowChannel)
    local receiver = index(9, 5, width)
    assert(shadowMap[receiver] > 0.95)

    settings.ao, settings.shadowStrength = false, 100
    result = Scene.render(width, height, relief, settings, nil, art)
    assert(not result.aoMap and not next(result.ao) and not next(result.light))
    local shadow = result.shadows[receiver]
    assert(shadow & 0xffffff == 0 and result.shadowMap[receiver] == shadowMap[receiver])
    settings.shadowStrength = 50
    local softened = Scene.render(width, height, relief, settings, nil, art).shadows[receiver]
    assert(math.abs((shadow >> 24) - 2 * (softened >> 24)) <= 1)
  end)

  test("scene lighting skips transparent and partial-alpha pixels as receivers and blockers", function()
    local width, height = 17, 9
    local heights = grid(width, height, function(x) return x == 10 and 0.86 or 0.16 end)
    local function art(x, y)
      if x == 10 then return 50, 43, 40, y % 2 == 0 and 0 or 125 end
      return 100, 110, 120, 255
    end
    local function mask(x, y) return x >= 2 and y < 8 end
    local result = Scene.render(width, height, heights, renderOptions(), mask, art)
    assert(not next(result.ao) and not next(result.shadows))
    assert(next(result.light), "warm direct light should reach the flat opaque areas")
    for i in pairs(result.light) do
      local x, y = (i - 1) % width, (i - 1) // width
      assert(mask(x, y) and x ~= 10)
    end
    for i = 1, width * height do assert(result.aoMap[i] == 0 and result.shadowMap[i] == 0) end

    local function blackRidge(x, y)
      if x == 10 then return 0, 0, 0 end
      return art(x, y)
    end
    local map = Scene.map(width, height, heights, {}, mask, blackRidge, nil, Lighting.aoChannel)
    assert(map[index(9, 5, width)] > 0, "opaque black pixels with omitted alpha can still occlude")
  end)

  test("scene preview crops are exact and use full geometry even outside the displayed crop", function()
    local width, height = 21, 13
    local heights = grid(width, height, function(x, y)
      return x == 15 and y > 2 and 0.9 or 0.1
    end)
    local function art(x, y)
      return 93 + x, 120 + y, 148, 255
    end
    local options = renderOptions()
    options.seamless = true
    local full = Scene.render(width, height, heights, options, nil, art)
    local rect = { x = 6, y = -2, width = 8, height = 9 }
    local crop = Scene.render(width, height, heights, options, nil, art, rect)
    assert(next(crop.shadows), "the ridge outside the preview crop should still cast into it")
    for _, layer in ipairs({ "light", "ao", "shadows", "aoMap", "shadowMap" }) do
      for y = 0, rect.height - 1 do
        for x = 0, rect.width - 1 do
          assert(crop[layer][index(x, y, rect.width)] ==
            full[layer][index((x + rect.x) % width, (y + rect.y) % height, width)])
        end
      end
    end
  end)

  test("disabled and neutral scene lighting leaves sparse overlays empty", function()
    local width, height = 14, 9
    local heights = grid(width, height, function() return 0.4 end)
    local function art() return 93, 120, 148 end
    local disabled = Scene.render(width, height, heights, {}, nil, art)
    assert(not next(disabled.light) and not next(disabled.ao) and not next(disabled.shadows))
    local neutral = Scene.render(width, height, heights, {
      directLight = true, ao = true, shadows = true,
    }, nil, art)
    assert(not next(neutral.light) and not next(neutral.ao) and not next(neutral.shadows))
  end)
end
