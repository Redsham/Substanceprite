local Surface = {}

Surface.placements = { "Material", "Recesses", "Ridges", "Slopes" }

local materialPlacement = {
  Noise = "Slopes",
  Scratches = "Ridges",
  Wear = "Ridges",
}

local abs, max, min = math.abs, math.max, math.min

local function clampSigned(value)
  return max(-1, min(1, value))
end

function Surface.luminance(r, g, b)
  return (2126 * r + 7152 * g + 722 * b) / 2550000
end

-- The reader uses 0-based coordinates and returns 8-bit RGBA. Transparent
-- pixels are left undefined so holes don't become trenches in the relief.
function Surface.build(width, height, reader, options)
  options = options or {}
  local fromAlpha = options.channel == "Alpha"
  local invert = options.invert == true
  local heights, count = {}, 0
  for y = 0, height - 1 do
    local row = y * width + 1
    for x = 0, width - 1 do
      local r, g, b, a = reader(x, y)
      if a and a > 0 then
        local value = fromAlpha and a / 255 or Surface.luminance(r, g, b)
        heights[row + x] = invert and 1 - value or value
        count = count + 1
      end
    end
  end
  return heights, count
end

local function neutral()
  return 0, 0
end

function Surface.sampler(width, height, heights, seamless, placement, style)
  if not heights or width < 1 or height < 1 then return neutral end
  if placement == nil or placement == "Material" then
    placement = materialPlacement[style] or "Recesses"
  end

  local lowest, highest, total, count = 1, 0, 0, 0
  for _, value in pairs(heights) do
    lowest, highest = min(lowest, value), max(highest, value)
    total, count = total + value, count + 1
  end
  if count == 0 or highest == lowest then return neutral end

  local range, middle = highest - lowest, total / count
  local heightGain = 2.5 / (1 + range * 1.25)
  local plainPenalty = min(range * 0.43, 0.24)

  local function at(x, y)
    if seamless then
      x, y = x % width, y % height
    elseif x < 0 or x >= width or y < 0 or y >= height then
      return nil
    end
    return heights[y * width + x + 1]
  end

  return function(x, y)
    local center = at(x, y)
    if not center then return 0, 0 end

    local left, right, top, bottom = at(x - 1, y), at(x + 1, y), at(x, y - 1), at(x, y + 1)
    -- Only look past a neighbor when it exists. A ledge can influence two
    -- pixels on either side, but the influence stops at holes and cutouts.
    local farLeft = left and at(x - 2, y) or left or center
    local farRight = right and at(x + 2, y) or right or center
    local farTop = top and at(x, y - 2) or top or center
    local farBottom = bottom and at(x, y + 2) or bottom or center
    left, right, top, bottom = left or center, right or center, top or center, bottom or center

    local rise = max(center, left, right, top, bottom) - center
    local fall = center - min(center, left, right, top, bottom)
    local farRise = max(center, farLeft, farRight, farTop, farBottom) - center
    local farFall = center - min(center, farLeft, farRight, farTop, farBottom)
    local curvature = (left + right + top + bottom) * 0.25 - center
    local elevation = (center - middle) * heightGain

    if placement == "Slopes" then
      local slope = max(rise, fall, abs(right - left) * 0.65, abs(bottom - top) * 0.65)
      local cover = slope * 1.42 + max(farRise, farFall) * 0.42 - plainPenalty
      local directionalLight = (left - right + top - bottom) * 0.34
      return clampSigned(cover), clampSigned(elevation * 0.43 + directionalLight)
    end

    local cover = 0.39 * elevation + fall - rise * 0.9 +
      0.28 * (farFall - farRise) - 0.40 * curvature
    local tone = 0.52 * elevation + 0.72 * fall - 0.26 * rise
    if placement == "Recesses" then
      return clampSigned(-cover), clampSigned(0.55 * elevation + 0.92 * rise - 0.30 * fall)
    end
    return clampSigned(cover), clampSigned(tone)
  end
end

return Surface
