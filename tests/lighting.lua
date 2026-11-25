local Lighting = require("lib.lighting")
local Surface = require("lib.surface")

local function irradiated(sampler, x, y, swatch, underlay, opacity, match)
  return { Lighting.tint(swatch[1], swatch[2], swatch[3],
    underlay[1], underlay[2], underlay[3], opacity, sampler(x, y), match) }
end

local function luma(rgb)
  return Surface.luminance(table.unpack(rgb))
end

local function overlay(source, pigment, opacity)
  return {
    math.floor(source[1] + (pigment[1] - source[1]) * opacity + 0.5),
    math.floor(source[2] + (pigment[2] - source[2]) * opacity + 0.5),
    math.floor(source[3] + (pigment[3] - source[3]) * opacity + 0.5),
  }
end

local function equalColor(a, b)
  return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

return function(test)
  test("lighting match at zero uses the exact base pigment and ignores empty pixels", function()
    local sampler = Lighting.sampler(3, 1, function(x)
      if x == 0 then return 70, 82, 84, 0 end
      return 100, 115, 112, 255
    end, {true, false, true})
    local paint, source = {167, 116, 86}, {100, 115, 112}
    assert(not sampler(0, 0) and not sampler(1, 0), "transparent/masked pixels have no lighting")
    assert(equalColor(irradiated(sampler, 2, 0, paint, source, 1, 0), paint), "zero match changed the pigment")
    assert(equalColor(irradiated(sampler, 0, 0, paint, source, 1, 100), paint), "empty pixels lost the pigment fallback")
  end)

  test("dense rust retains shadows and highlights while tinting the midtones", function()
    local width, height = 21, 7
    local function reader(x)
      local gray = x == 4 and 28 or (x == 14 and 218 or 104)
      return gray, gray, gray, 255
    end
    local sampler = Lighting.sampler(width, height, reader)
    local paint = {167, 116, 86}
    local outputs, raw = {}, {}
    for i, x in ipairs({4, 8, 14}) do
      local source = { reader(x) }
      source[4] = nil
      outputs[i] = overlay(source, irradiated(sampler, x, 3, paint, source, 0.88), 0.88)
      raw[i] = overlay(source, paint, 0.88)
    end
    assert(luma(outputs[1]) < 0.22 and luma(outputs[3]) > 0.76, "a deep seam or highlight was replaced by pigment")
    assert(luma(outputs[3]) - luma(outputs[1]) > (luma(raw[3]) - luma(raw[1])) * 4, "dense layers still flatten the paint")
    assert(outputs[2][1] - outputs[2][3] >= 38, "the rust tint disappeared on the midtone")
    assert(outputs[3][1] - outputs[3][3] < outputs[2][1] - outputs[2][3], "gloss lost its neutral color")
  end)

  test("lighting follows the same source cues across dense stacked effects", function()
    local width, height = 24, 6
    local function reader(x)
      local gray = x == 6 and 15 or (x == 17 and 215 or 90)
      return gray, gray + 3, gray + 4
    end
    local sampler = Lighting.sampler(width, height, reader)
    local surfaces = { {reader(6)}, {reader(17)} }
    for _, paint in ipairs({ {167, 116, 86}, {55, 83, 47}, {120, 78, 49} }) do
      for index, x in ipairs({6, 17}) do
        local source = surfaces[index]
        local lit = irradiated(sampler, x, 3, paint, source, 0.72, 100)
        surfaces[index] = overlay(source, lit, 0.72)
      end
    end
    assert(luma(surfaces[2]) - luma(surfaces[1]) > 0.64, "multiple materials obscured the original relief")
  end)

  test("local exposure cannot cross transparent gaps", function()
    local function reader(farSide)
      return function(x, y)
        if x == 8 and y == 4 then return 255, 255, 255, 0 end
        if x == 9 and y == 4 then return farSide, farSide, farSide, 255 end
        return 100, 110, 115, 255
      end
    end
    local first = Lighting.sampler(22, 10, reader(5))
    local second = Lighting.sampler(22, 10, reader(255))
    local paint, source = {169, 113, 75}, {100, 110, 115}
    assert(equalColor(irradiated(first, 7, 4, paint, source, 0.8),
      irradiated(second, 7, 4, paint, source, 0.8)), "exposure crossed a one-pixel hole")
  end)

  test("lighting has exact repeat coordinates and is independent of crop sample order", function()
    local width, height = 13, 11
    local function reader(x, y)
      local value = 12 + (x * 17 + y * 29) % 176
      return value + 2, value + 5, value, ((x + y) % 6 == 0) and 0 or 255
    end
    local full = Lighting.sampler(width, height, reader, nil, true)
    local cropped = Lighting.sampler(width, height, reader, nil, true)
    for y = height + 2, -3, -1 do
      for x = width + 3, -4, -1 do
        assert(cropped(x, y) == full(x % width, y % height), "crop or wrapping changed a lighting context")
      end
    end
    local nonperiodic = Lighting.sampler(width, height, reader)
    assert(not nonperiodic(-1, 0) and not nonperiodic(width, 0), "non-seamless context crossed the canvas")
  end)
end
