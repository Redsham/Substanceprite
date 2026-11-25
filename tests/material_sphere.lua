local Sphere = require("lib.material_sphere")

local function at(pixels, size, x, y)
  return pixels[y * size + x + 1]
end

local function red(pixel)
  return pixel & 255
end

local function green(pixel)
  return (pixel >> 8) & 255
end

local function identical(a, b)
  if #a ~= #b then return false end
  for i, value in ipairs(a) do
    if value ~= b[i] then return false end
  end
  return true
end

return function(test)
  test("material spheres render a deterministic opaque disk with transparent corners", function()
    local size = 35
    local redTexture = { 0xad2021 }
    local pixels = Sphere.render(size, 1, 1, redTexture)
    assert(identical(pixels, Sphere.render(size, 1, 1, redTexture)))
    assert(#pixels == size * size and at(pixels, size, 0, 0) == 0)
    local midpoint = at(pixels, size, 17, 17)
    assert(midpoint >> 24 == 255 and red(midpoint) > green(midpoint) * 2, "RGBA packing or albedo is incorrect")
    local count = 0
    for _, pixel in ipairs(pixels) do
      if pixel ~= 0 then
        count = count + 1
        assert(pixel >> 24 == 255, "unexpected antialiasing in pixel sphere")
      end
    end
    assert(count > size * size * 0.69 and count < size * size * 0.81, "invalid sphere silhouette")
    assert(Sphere.render(2, 1, 1, redTexture)[1] >> 24 == 255, "tiny sphere disappears")
  end)

  test("sphere lighting uses the positive-Y-up direction convention", function()
    local color = { 0x84878a }
    local size = 41
    local function render(angle) return Sphere.render(size, 1, 1, color, nil, { angle = angle }) end
    local left, right, up, down = render(180), render(0), render(90), render(270)
    assert(red(at(left, size, 10, 20)) > red(at(left, size, 30, 20)) + 28)
    assert(red(at(right, size, 30, 20)) > red(at(right, size, 10, 20)) + 28)
    assert(red(at(up, size, 20, 10)) > red(at(up, size, 20, 30)) + 20)
    assert(red(at(down, size, 20, 30)) > red(at(down, size, 20, 10)) + 20)
    assert(identical(up, render(450)), "light azimuth should wrap")
  end)

  test("surface colors use longitude and shift when the sphere rotates", function()
    local colors = {}
    for i = 1, 16 do colors[i] = i <= 8 and 0xcc3527 or 0x2ac54e end
    local size = 41
    local front = Sphere.render(size, 16, 1, colors)
    local rotated = Sphere.render(size, 16, 1, colors, nil, { rotation = 180 })
    local lightLeft, lightRight = at(front, size, 11, 20), at(front, size, 29, 20)
    assert(red(lightLeft) > green(lightLeft) * 1.5 and green(lightRight) > red(lightRight) * 1.5)
    assert(green(at(rotated, size, 11, 20)) > red(at(rotated, size, 11, 20)) * 1.5)
    assert(identical(front, Sphere.render(size, 16, 1, colors, nil, { rotation = 360 })))
  end)

  test("surface relief changes local lighting and can be disabled", function()
    local size, width, height = 39, 16, 16
    local colors, heights = {}, {}
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local i = y * width + x + 1
        colors[i], heights[i] = 0x84997d, (x % 6 < 2 or y % 6 < 2) and 0.42 or 0.62
      end
    end
    local base = Sphere.render(size, width, height, colors)
    local bumped = Sphere.render(size, width, height, colors, heights)
    local disabled = Sphere.render(size, width, height, colors, heights, { relief = 0 })
    assert(identical(base, disabled), "zero relief must preserve base illumination exactly")
    local changes = 0
    for i, pixel in ipairs(base) do
      if pixel ~= bumped[i] then changes = changes + 1 end
      assert(pixel >> 24 == bumped[i] >> 24)
    end
    assert(changes > 100, "height map did not perturb the sphere normals")
  end)

  test("roughness and metalness change the studio highlight while sparse input keeps coverage", function()
    local size = 39
    local color = { 0x787f89 }
    local flat = Sphere.render(size, 1, 1, color, nil, { roughness = 0.92, metalness = 0 })
    local polished = Sphere.render(size, 1, 1, color, nil, { roughness = 0.12, metalness = 0.95 })
    assert(red(at(polished, size, 14, 14)) > red(at(flat, size, 14, 14)) + 10)
    local filled = Sphere.render(size, 2, 2, { -1, 0x787f89 })
    local reference = Sphere.render(size, 1, 1, color)
    assert(identical(filled, reference), "missing swatches should use the mean material color")
  end)
end
