local Normal = require("lib.normal")

local function pixelIndex(x, y, width)
  return y * width + x + 1
end

return function(test)
  test("normal maps encode flat surfaces and preserve missing pixels", function()
    local width, height = 7, 4
    local heights, mask = {}, {}
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local i = pixelIndex(x, y, width)
        if x ~= 3 then heights[i] = x > 3 and 0.75 or 0 end
        mask[i] = x ~= 6
      end
    end

    local pixels = Normal.generate(width, height, heights, { smoothing = 3 }, mask)
    assert(#pixels == width * height, "normal field must be dense")
    for i, pixel in ipairs(pixels) do
      local expected = heights[i] ~= nil and mask[i] and Normal.neutral or Normal.missing
      assert(pixel == expected, "blur must stop at transparent gaps")
    end
    local r, g, b = Normal.rgb(Normal.neutral)
    assert(r == 128 and g == 128 and b == 255, "incorrect neutral normal")
    assert(Normal.rgb(Normal.missing) == nil, "missing pixels should have no RGB value")
  end)

  test("the normal vector follows a ramp with Unity's positive Y convention", function()
    local width, height = 5, 4
    local heights = {}
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        heights[pixelIndex(x, y, width)] = (2 * x + y) / 16
      end
    end
    local normals = Normal.generate(width, height, heights)
    local flipped = Normal.generate(width, height, heights, { invertGreen = true })
    local r, g, b = Normal.rgb(normals[1])
    local flippedR, flippedG, flippedB = Normal.rgb(flipped[1])
    assert(r < 128 and g > 128 and b < 255, "wrong axis directions on a diagonal ramp")
    assert(flippedR == r and flippedG < 128 and flippedG + g == 255 and flippedB == b,
      "green-channel inversion changed a different component")
    for i, sample in ipairs(normals) do
      assert(sample == normals[1] and flipped[i] == flipped[1], "ramp changes at the canvas edge")
    end
    local x, y, z = 2 * r / 255 - 1, 2 * g / 255 - 1, 2 * b / 255 - 1
    assert(math.abs(math.sqrt(x * x + y * y + z * z) - 1) < 0.007, "normal is not unit length")
  end)

  test("normal strength and smoothing change slope without introducing outlines", function()
    local heights = { 0, 0, 0, 1, 1, 1, 1 }
    local disabled = Normal.generate(7, 1, heights, { strength = 0, smoothing = 3 })
    for _, pixel in ipairs(disabled) do assert(pixel == Normal.neutral, "zero strength must be flat") end

    local low = Normal.generate(7, 1, heights, { strength = 15 })
    local high = Normal.generate(7, 1, heights, { strength = 125 })
    local smoothed = Normal.generate(7, 1, heights, { strength = 125, smoothing = 2 })
    local lowR, highR, smoothR = Normal.rgb(low[3]), Normal.rgb(high[3]), Normal.rgb(smoothed[3])
    assert(highR < lowR and smoothR > highR, "normal slope does not respond to strength and smoothing")
    assert(high[2] == Normal.neutral and smoothed[2] ~= Normal.neutral,
      "smoothing should soften the transition over adjacent pixels")
  end)

  test("normal preview crops equal full bakes and repeat across both tile edges", function()
    local width, height = 11, 9
    local heights, mask = {}, {}
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local i = pixelIndex(x, y, width)
        if (x + 2 * y) % 11 ~= 0 then heights[i] = (x * 7 + y * 5) % 23 / 22 end
        mask[i] = (x - y) % 13 ~= 4
      end
    end
    local options = { strength = 80, smoothing = 3, seamless = true }
    local tile = Normal.generate(width, height, heights, options, mask)
    local rect = { x = -3, y = -2, width = width + 7, height = height + 5 }
    local crop = Normal.generate(width, height, heights, options, mask, rect)
    for y = 0, rect.height - 1 do
      for x = 0, rect.width - 1 do
        local expected = tile[pixelIndex((x + rect.x) % width, (y + rect.y) % height, width)]
        assert(crop[pixelIndex(x, y, rect.width)] == expected, "cyclic preview changed a normal")
      end
    end

    options.seamless = false
    local plain = Normal.generate(width, height, heights, options, mask)
    crop = Normal.generate(width, height, heights, options, mask, rect)
    for y = 0, rect.height - 1 do
      for x = 0, rect.width - 1 do
        local sx, sy = x + rect.x, y + rect.y
        local expected = Normal.missing
        if sx >= 0 and sy >= 0 and sx < width and sy < height then
          expected = plain[pixelIndex(sx, sy, width)]
        end
        assert(crop[pixelIndex(x, y, rect.width)] == expected, "clipped preview changed a normal")
      end
    end
  end)

  test("normals support single pixels, thin strips and empty maps", function()
    for _, seamless in ipairs({ false, true }) do
      local settings = { seamless = seamless, smoothing = 3 }
      local single = Normal.generate(1, 1, { 0.6 }, settings)
      assert(#single == 1 and single[1] == Normal.neutral, "a singleton does not have a slope")
      local line = Normal.generate(1, 3, { 0, 0.5, 1 }, settings)
      for _, pixel in ipairs(line) do
        assert(Normal.rgb(pixel) == 128, "thin column has no horizontal gradient")
      end
    end
    local empty = Normal.generate(2, 3, {}, { smoothing = 3 })
    for _, pixel in ipairs(empty) do assert(pixel == Normal.missing, "empty map has no valid pixels") end
    assert(#empty == 6 and #Normal.generate(0, 1, {}) == 0, "invalid dense or zero-length result")
  end)
end
