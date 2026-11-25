local Surface = require("lib.surface")
local Weather = require("lib.weather")
local Texture = {}

Texture.styles = { "Noise", "Dirt", "Rust", "Dust", "Moss", "Scratches", "Wear" }
Texture.defaultSurfaceStrength = 65
Texture.defaultRustSoftness = 75
Texture.defaultRustRunoff = 65
Texture.defaults = {
  style = "Dirt",
  density = 45,
  scale = 4,
  intensity = 70,
  clustering = 60,
  edge = 0,
  bottom = 0,
  seamless = false,
  seed = 1,
  softness = Texture.defaultRustSoftness,
  runoff = Texture.defaultRustRunoff,
}

local depositColors = {
  Noise     = { 0x44475890, 0x848391BC, 0xD1C9BBEA },
  Dirt      = { 0x48382E9C, 0x826047D8, 0xBC9563FA },
  Rust      = { 0x633225BD, 0xAB492BEA, 0xDC763EFF },
  Dust      = { 0x93816F78, 0xBBAB91C0, 0xE8D7B5EE },
  Moss      = { 0x37422CCD, 0x5C7441EE, 0xA0B15FFF },
  Scratches = { 0x383643A0, 0x89928ECE, 0xDCE5DDFA },
  Wear      = { 0x4B433A98, 0xA78E70CE, 0xDCCCABF0 },
}

function Texture.defaultColors(style)
  local colors = {}
  for i, value in ipairs(depositColors[style] or depositColors.Dirt) do
    colors[i] = {
      r = (value >> 24) & 255, g = (value >> 16) & 255,
      b = (value >> 8) & 255, a = value & 255,
    }
  end
  return colors
end

local floor, min, max, abs = math.floor, math.min, math.max, math.abs

local function getNumber(options, key, lower, upper)
  local value = tonumber(options[key])
  if not value or value ~= value then value = Texture.defaults[key] end
  return max(lower, min(upper, value))
end

local function hash(x, y, seed)
  local value = ((x * 0x9e3779b1) ~ (y * 0x85ebca77) ~ seed) & 0xffffffff
  value = ((value ~ (value >> 16)) * 0x7feb352d) & 0xffffffff
  value = ((value ~ (value >> 15)) * 0x846ca68b) & 0xffffffff
  return (value ~ (value >> 16)) / 4294967296
end

local function smooth(value)
  return value * value * (3 - 2 * value)
end

local function gridSpacing(size, step, seamless)
  if not seamless then return step, nil end
  local cells = max(1, floor(size / step + 0.5))
  return size / cells, cells
end

local function axisSamples(step)
  local samples = {}
  return function(position)
    local sample = samples[position]
    if not sample then
      local scaled = position / step
      local cell = floor(scaled)
      sample = { cell, smooth(scaled - cell) }
      samples[position] = sample
    end
    return sample[1], sample[2]
  end
end

local function fieldSpacing(size, step, seamless)
  -- Give small motifs room to vary when a coarse field exceeds the tile.
  if size >= 6 then step = min(step, size / 2) end
  return gridSpacing(size, step, seamless)
end

-- The lattice spans exactly one tile in seamless mode. Only the current
-- lattice row is cached, so memory does not grow with the area of the sprite.
local function makeField(width, height, stepX, stepY, seed, seamless)
  local spacingX, periodX = fieldSpacing(width, stepX, seamless)
  local spacingY, periodY = fieldSpacing(height, stepY, seamless)
  local sampleX, sampleY = axisSamples(spacingX), axisSamples(spacingY)
  local cachedY, row, y0, y1

  return function(x, y)
    local cellX, u = sampleX(x)
    local cellY, v = sampleY(y)
    if cellY ~= cachedY then
      cachedY, row = cellY, {}
      y0, y1 = cellY, cellY + 1
      if periodY then y0, y1 = y0 % periodY, y1 % periodY end
    end

    local cell = row[cellX]
    if not cell then
      local x0, x1 = cellX, cellX + 1
      if periodX then x0, x1 = x0 % periodX, x1 % periodX end
      local a, b = hash(x0, y0, seed), hash(x0, y1, seed)
      cell = { a, hash(x1, y0, seed) - a, b, hash(x1, y1, seed) - b }
      row[cellX] = cell
    end

    local top = cell[1] + cell[2] * u
    local bottom = cell[3] + cell[4] * u
    return top + (bottom - top) * v
  end
end

local scratchDirections = {
  { 0.894, -0.447 },
  { 0.949, -0.316 },
  { 0.970, -0.243 },
  { 0.996, 0.087 },
  { 0.800, 0.600 },
}

local function makeScratches(width, height, scale, seed, seamless, clustering)
  local step = max(5, scale * 3)
  local spacingX, periodX = gridSpacing(width, step, seamless)
  local spacingY, periodY = gridSpacing(height, step, seamless)
  local clusterField = makeField(width, height, step * 2, step * 2, seed + 53, seamless)
  local longestStroke = min(spacingX, spacingY) * 0.9
  local cachedY, strokeRows

  local function strokeAt(cells, cellX, cellY)
    local stroke = cells[cellX]
    if stroke then return stroke end

    local keyX, keyY = cellX, cellY
    if seamless then keyX, keyY = cellX % periodX, cellY % periodY end
    local x = (cellX + 0.13 + 0.74 * hash(keyX, keyY, seed + 13)) * spacingX
    local y = (cellY + 0.16 + 0.68 * hash(keyX, keyY, seed + 27)) * spacingY
    local direction = scratchDirections[1 + floor(hash(keyX, keyY, seed + 41) * #scratchDirections)]
    local length = max(1, longestStroke * (0.32 + 0.68 * hash(keyX, keyY, seed + 59)))
    stroke = { x, y, direction[1], direction[2], length, hash(keyX, keyY, seed + 67) }
    cells[cellX] = stroke
    return stroke
  end

  return function(x, y)
    local cellX, cellY = floor(x / spacingX), floor(y / spacingY)
    if cellY ~= cachedY then
      cachedY, strokeRows = cellY, { {}, {}, {} }
    end

    local bestScore, bestDepth = 0, 0
    for offsetY = -1, 1 do
      local cells = strokeRows[offsetY + 2]
      for neighborX = cellX - 1, cellX + 1 do
        local stroke = strokeAt(cells, neighborX, cellY + offsetY)
        local dx, dy = x + 0.5 - stroke[1], y + 0.5 - stroke[2]
        local along = dx * stroke[3] + dy * stroke[4]
        local cross = dy * stroke[3] - dx * stroke[4]
        local length = stroke[5]
        if along >= -length * 0.42 and along <= length * 0.58 then
          local quality = stroke[6]
          local coreWidth = 0.57 + min(0.35, scale * 0.018)
          local score, depth = 0, 0
          if abs(cross) <= coreWidth then
            score = 0.52 + quality * 0.46
            depth = 0.48 + 0.46 * (1 - abs(cross) / coreWidth)
          elseif cross <= coreWidth + 0.91 and cross > coreWidth and
                 along > -length * 0.2 and along < length * 0.34 and length > 3 then
            score = 0.44 + quality * 0.31
            depth = 0.18
          end
          if score > bestScore then bestScore, bestDepth = score, depth end
        end
      end
    end
    if bestScore == 0 then return 0, 0 end
    return bestScore + (clusterField(x, y) - 0.5) * clustering * 0.44, bestDepth
  end
end

local materialSalts = {
  Noise = 0x2059,
  Rust = 0x1c13,
  Dust = 0x70bd,
  Moss = 0x14eb,
  Scratches = 0x5940,
  Wear = 0x4e69,
}

local function makeMaterial(width, height, style, scale, seed, seamless, clustering)
  seed = seed ~ (materialSalts[style] or 0)
  if style == "Scratches" then
    return makeScratches(width, height, scale, seed, seamless, clustering)
  end

  local broad = makeField(width, height, scale * 3.4, scale * 2.8, seed + 11, seamless)
  local medium = makeField(width, height, scale * 1.2, scale, seed + 23, seamless)
  local fineStep = max(1.7, scale * 0.45)
  local fine = makeField(width, height, fineStep, fineStep, seed + 37, seamless)

  if style == "Noise" then
    return function(x, y)
      local grain = hash(x, y, seed + 71)
      local weight = 0.76 * clustering
      local cloud = medium(x, y) * 0.64 + broad(x, y) * 0.36
      local groupedTone = grain * (1 - weight * 0.62) + cloud * weight * 0.62
      return grain * (1 - weight) + cloud * weight, 0.2 + groupedTone * 0.8
    end
  elseif style == "Rust" then
    return function(x, y)
      local mass, chips = broad(x, y), fine(x, y)
      local crust = mass * (0.52 + 0.28 * clustering) +
        medium(x, y) * (0.35 - 0.20 * clustering) + chips * (0.13 - 0.08 * clustering)
      -- Narrow light transitions sit between the broken lip and dark pits.
      local lip = max(0, 1 - abs(crust - 0.70) * 6.4)
      local pit = chips < 0.22 and 0.16 or 0
      return crust - pit, 0.14 + lip * 0.59 + chips * 0.24 - pit
    end
  elseif style == "Dust" then
    local drift = makeField(width, height, scale * 4.8, scale * 0.86, seed + 47, seamless)
    return function(x, y)
      local wisps, clumps = drift(x, y), fine(x, y)
      local grains = max(hash(x, y, seed + 79) * 0.87, clumps * 0.96)
      local driftWeight = 0.26 + 0.52 * clustering
      return wisps * driftWeight + grains * (1 - driftWeight),
        0.08 + wisps * 0.26 + grains * grains * 0.46 + clumps * 0.13
    end
  elseif style == "Moss" then
    return function(x, y)
      local mass, buds = broad(x, y), fine(x, y)
      local threads = 1 - abs(medium(x, y) * 0.73 + buds * 0.27 - 0.5) * 2
      local massWeight = 0.48 + 0.28 * clustering
      local score = mass * massWeight + threads * (0.82 - massWeight) + buds * 0.18 - 0.09
      local depth = (mass - 0.38) * 0.9 + threads * 0.28 + buds * 0.4
      if buds > 0.57 and hash(x, y, seed + 97) > 0.87 then
        score, depth = score + 0.05, depth + 0.05
      end
      return score, depth
    end
  elseif style == "Wear" then
    local drag = makeField(width, height, scale * 4.1, scale * 0.8, seed + 61, seamless)
    return function(x, y)
      local plane, grit = broad(x, y), fine(x, y)
      local streak = drag(x, y)
      local planeWeight = 0.28 + 0.43 * clustering
      local score = plane * planeWeight + streak * (0.82 - planeWeight) + grit * 0.18
      -- Flat rubbed areas stay quiet, with brighter chips along their contour.
      local ring = max(0, 1 - abs(streak - 0.69) * 5.9)
      return score, 0.14 + ring * grit * 0.64 + streak * 0.23
    end
  end

  return function(x, y)
    local mass, flecks = broad(x, y), fine(x, y)
    local massWeight = 0.37 + 0.42 * clustering
    local score = mass * massWeight + medium(x, y) * (0.79 - massWeight) + flecks * 0.21
    return score, 0.09 + mass * 0.53 + flecks * 0.38
  end
end

local function makeMask(width, height, mask, seamless)
  return function(x, y)
    if seamless then
      x, y = x % width, y % height
    elseif x < 0 or x >= width or y < 0 or y >= height then
      return false
    end
    return not mask or mask[y * width + x + 1]
  end
end

-- Padded chamfer distance keeps an output crop identical to a crop of the
-- full result. The padding uses the same clipping or tiling as the material.
local function makeEdgeMap(allowed, x, y, width, height, radius)
  local stride, rows = width + 2 * radius, height + 2 * radius
  local limit, distances = radius * 2, {}
  for row = 1, rows do
    local sourceY = y + row - radius - 1
    local previous = (row - 2) * stride
    local start = previous + stride
    for column = 1, stride do
      local index = start + column
      if allowed(x + column - radius - 1, sourceY) then
        local left = column > 1 and distances[index - 1] or limit
        local up = distances[previous + column] or limit
        local upperLeft = column > 1 and distances[previous + column - 1] or limit
        local upperRight = column < stride and distances[previous + column + 1] or limit
        distances[index] = min(limit, left + 2, up + 2, upperLeft + 3, upperRight + 3)
      else
        distances[index] = 0
      end
    end
  end
  for row = rows, 1, -1 do
    local start = (row - 1) * stride
    local nextRow = start + stride
    for column = stride, 1, -1 do
      local index = start + column
      local current = distances[index]
      if current > 2 then
        local right = column < stride and distances[index + 1] or limit
        local down = distances[nextRow + column] or limit
        local lowerLeft = column > 1 and distances[nextRow + column - 1] or limit
        local lowerRight = column < stride and distances[nextRow + column + 1] or limit
        distances[index] = min(current, right + 2, down + 2, lowerLeft + 3, lowerRight + 3)
      end
    end
  end
  return function(column, row)
    local distance = distances[(row + radius) * stride + column + radius + 1]
    return 1 - max(0, distance - 2) / (limit - 2)
  end
end

local function makeBottomField(width, height, mask, seamless)
  local columns = {}
  return function(x, y)
    local span = columns[x]
    if not span then
      local first, last = 0, height - 1
      if mask then
        while first < last and not mask[first * width + x + 1] do first = first + 1 end
        while last > first and not mask[last * width + x + 1] do last = last - 1 end
      end
      span = { first, last }
      columns[x] = span
    end
    if seamless and span[1] == 0 and span[2] == height - 1 then
      local distance = abs(y + 0.5 - height * 0.76)
      distance = min(distance, height - distance)
      return smooth(max(0, 1 - distance / (height * 0.50)))
    end
    if span[1] == span[2] then return 1 end
    return smooth((y - span[1]) / (span[2] - span[1]))
  end
end

local densityRanges = {
  Noise = { 0.00, 1.00 },
  Dirt = { 0.31, 0.84 },
  Rust = { 0.38, 0.85 },
  Dust = { 0.42, 0.94 },
  Moss = { 0.36, 0.88 },
  Scratches = { 0.38, 0.89 },
  Wear = { 0.38, 0.85 },
}

-- The two tones mark the transitions at the default intensity. Giving each
-- material its own transitions leaves room for both subdued and bright pixels.
local toneRanges = {
  Noise = { 0.66, 0.88 },
  Dirt = { 0.68, 0.80 },
  Rust = { 0.62, 0.83 },
  Dust = { 0.58, 0.70 },
  Moss = { 0.83, 0.94 },
  Scratches = { 0.52, 0.84 },
  Wear = { 0.30, 0.60 },
}

-- The mask uses full-image row-major coordinates. The optional rectangle
-- selects the output coordinates, and may cross the boundaries of a tile.
function Texture.generate(width, height, options, mask, rect)
  options = options or {}
  width, height = floor(width), floor(height)
  rect = rect or { x = 0, y = 0, width = width, height = height }
  local outWidth, outHeight = floor(rect.width), floor(rect.height)
  local outX, outY = floor(rect.x), floor(rect.y)
  local result = {}
  if outWidth < 1 or outHeight < 1 then return result end

  local density = getNumber(options, "density", 0, 100) / 100
  local intensity = getNumber(options, "intensity", 0, 100) / 100
  if width < 1 or height < 1 or density == 0 or intensity == 0 then
    for index = 1, outWidth * outHeight do result[index] = 0 end
    return result
  end

  local style = options.style or Texture.defaults.style
  local seamless = options.seamless == true
  local scale = getNumber(options, "scale", 1, 64)
  local seed = floor(getNumber(options, "seed", -2147483648, 4294967295))
  local clustering = getNumber(options, "clustering", 0, 100) / 100
  local edge = getNumber(options, "edge", 0, 100) / 100
  local bottom = getNumber(options, "bottom", 0, 100) / 100
  local range = densityRanges[style] or densityRanges.Dirt
  local tones = toneRanges[style] or toneRanges.Dirt
  local threshold = range[2] + (range[1] - range[2]) * density
  if style ~= "Noise" then
    -- Small sprites sample few material cells. Loosen the cut slightly so a
    -- coherent mark can survive even when its center falls outside the sprite.
    threshold = threshold - max(0, 1 - width * height / 1024) * density * 0.15
  end
  local sample = makeMaterial(width, height, style, scale, seed, seamless, clustering)
  local allowed = makeMask(width, height, mask, seamless)
  local radius = max(3, min(16, floor(scale * 1.85 + 0.5)))
  local edgeMap = edge > 0 and makeEdgeMap(allowed, outX, outY, outWidth, outHeight, radius)
  local bottomField = bottom > 0 and makeBottomField(width, height, mask, seamless)
  local intensityGain = 0.30 + intensity
  local toneScale = 0.26 / (tones[2] - tones[1])
  local toneOffset = 0.42 - tones[1] * toneScale

  local surfaceSampler, surfaceCoverage, surfaceTone
  local surface = options.surface
  if type(surface) == "table" and type(surface.heights) == "table" then
    local strength = tonumber(surface.strength) or Texture.defaultSurfaceStrength
    if strength > 0 then
      local blend = min(100, strength) / 100
      surfaceSampler = Surface.sampler(width, height, surface.heights,
                                       seamless, surface.placement, style)
      surfaceCoverage = blend * (0.30 + 0.08 * density)
      surfaceTone = blend * 0.18
    end
  end

  local index = 1
  for row = 0, outHeight - 1 do
    local rawY = outY + row
    local y = seamless and rawY % height or rawY
    for column = 0, outWidth - 1 do
      local rawX = outX + column
      local level = 0
      if allowed(rawX, rawY) then
        local x = seamless and rawX % width or rawX
        local score, depth = sample(x, y)
        if style ~= "Scratches" or score > 0 then
          if edgeMap then score = score + (edgeMap(column, row) - 0.38) * edge * 0.56 end
          if bottomField then score = score + (bottomField(x, y) - 0.48) * bottom * 0.49 end
          local toneBias = 0
          if surfaceSampler and score + surfaceCoverage >= threshold then
            local coverage, tone = surfaceSampler(x, y)
            score = score + coverage * surfaceCoverage
            toneBias = tone * surfaceTone
          end
          if score >= threshold then
            local tone = min(1, depth * toneScale + toneOffset + toneBias) * intensityGain
            level = tone >= 0.68 and 3 or (tone >= 0.42 and 2 or 1)
          end
        end
      end
      result[index] = level
      index = index + 1
    end
  end
  return result
end

local function clampUnit(value)
  return max(0, min(1, value))
end

local function depositByte(value)
  -- Quantize the interpolated values without reducing them to three flat inks.
  return floor(floor(clampUnit(value) * 48 + 0.5) * (255 / 48) + 0.5)
end

local function softFields(width, height, style, scale, seed, seamless, clustering)
  seed = seed ~ (materialSalts[style] or 0x4a27)
  local broad = makeField(width, height, scale * 3.4, scale * 2.8, seed + 11, seamless)
  local middle = makeField(width, height, scale * 1.2, scale, seed + 23, seamless)
  local grainSize = max(1.7, scale * 0.45)
  local grain = makeField(width, height, grainSize, grainSize, seed + 37, seamless)
  if style == "Dirt" then
    local wash = makeField(width, height, max(1.6, scale * 0.56), scale * 4.3, seed + 59, seamless)
    return function(x, y)
      local mass, silty, specks = broad(x, y), middle(x, y), grain(x, y)
      local streak = wash(x, y)
      local massWeight = 0.32 + 0.22 * clustering
      local score = mass * massWeight + streak * 0.34 + silty * (0.55 - massWeight) + specks * 0.11
      local pigment = 0.18 + 0.39 * silty + 0.28 * specks + 0.15 * streak
      return score, pigment, streak
    end
  end
  if style == "Moss" then
    local lobes = makeField(width, height, scale * 1.9, scale * 1.6, seed + 61, seamless)
    return function(x, y)
      local mass, buds, fine = broad(x, y), middle(x, y), grain(x, y)
      local cluster = lobes(x, y)
      local massWeight = 0.33 + 0.24 * clustering
      -- Only a growing colony has the density needed for its brighter buds.
      local growth = cluster * 0.27 + buds * (0.60 - massWeight) + mass * massWeight + fine * 0.13
      local pigment = 0.13 + 0.29 * buds + 0.28 * fine + 0.24 * cluster
      return growth, pigment, cluster
    end
  end
  local wash = makeField(width, height, max(2, scale * 0.85), scale * 3.4, seed + 59, seamless)
  return function(x, y)
    local mass, variation, grainValue = broad(x, y), middle(x, y), grain(x, y)
    local crust = mass * (0.52 + 0.28 * clustering)
      + variation * (0.35 - 0.20 * clustering) + grainValue * (0.13 - 0.08 * clustering)
    local streak = wash(x, y)
    local trace = crust - 0.055 * smooth(clampUnit((0.37 - grainValue) / 0.37))
    -- Dark pits and warmer grains give the body contrast while its edge fades by coverage.
    local pit = smooth(clampUnit((0.40 - grainValue) / 0.40)) * smooth(clampUnit((crust - 0.40) * 3))
    local pigment = 0.02 + 0.35 * variation + 0.34 * grainValue + 0.21 * streak + 0.15 * mass - 0.10 * pit
    return trace, pigment, streak
  end
end

local softProfiles = {
  Dirt = {
    softness = 78, runoff = 72, threshold = 0.85, opacity = 0.63, contrast = 0.43,
    weather = function(wetness, flow, retention, sediment, streak)
      local trail = flow * (0.25 + 0.19 * streak)
      local score = trail + sediment * 0.64 + min(0, wetness) * 0.45
      local pigment = flow * 0.10 + sediment * 0.10 - retention * 0.24
      return score, pigment
    end,
  },
  Moss = {
    softness = 74, runoff = 74, threshold = 0.89, opacity = 0.70, contrast = 0.48,
    weather = function(wetness, flow, retention, _, cluster)
      local moisture = retention * (0.75 + 0.25 * cluster)
      local score = moisture * 1.15 - flow * 0.29 + min(0, wetness) * 0.7
      return score, retention * 0.07 - flow * 0.12
    end,
  },
  Rust = {
    softness = Texture.defaultRustSoftness, runoff = Texture.defaultRustRunoff,
    threshold = 0.85, opacity = 0.71, contrast = 0.56,
    weather = function(wetness, flow, retention, _, streak)
      local score = wetness * 0.47 + flow * (0.50 + 0.50 * streak) * 0.058 + retention * 0.12
      return score, flow * 0.085 - max(0, wetness) * 0.22 - retention * 0.045
    end,
  },
}

function Texture.isSoftDeposit(style)
  return softProfiles[style] ~= nil
end

function Texture.defaultSoftness(style)
  return (softProfiles[style] or softProfiles.Dirt).softness
end

function Texture.defaultRunoff(style)
  return (softProfiles[style] or softProfiles.Dirt).runoff
end

local function softNumber(value, fallback)
  value = tonumber(value)
  if not value or value ~= value then value = fallback end
  return clampUnit(value / 100)
end

-- A sample packs the palette position in the high byte and coverage in
-- the low byte. Zero is transparent. Coordinates match Texture.generate().
local function generateSoftDeposit(width, height, options, mask, rect, style)
  width, height = floor(width), floor(height)
  local profile = softProfiles[style]
  rect = rect or { x = 0, y = 0, width = width, height = height }
  local outWidth, outHeight = floor(rect.width), floor(rect.height)
  local outX, outY = floor(rect.x), floor(rect.y)
  local result = {}
  if outWidth < 1 or outHeight < 1 then return result end

  local density = getNumber(options, "density", 0, 100) / 100
  local intensity = getNumber(options, "intensity", 0, 100) / 100
  if width < 1 or height < 1 or density == 0 or intensity == 0 then
    for i = 1, outWidth * outHeight do result[i] = 0 end
    return result
  end

  local scale = getNumber(options, "scale", 1, 64)
  local seed = floor(getNumber(options, "seed", -2147483648, 4294967295))
  local clustering = getNumber(options, "clustering", 0, 100) / 100
  local edge = getNumber(options, "edge", 0, 100) / 100
  local bottom = getNumber(options, "bottom", 0, 100) / 100
  local softness = softNumber(options.softness, profile.softness)
  local runoff = softNumber(options.runoff, profile.runoff)
  local seamless = options.seamless == true
  local allowed = makeMask(width, height, mask, seamless)
  local sample = softFields(width, height, style, scale, seed, seamless, clustering)
  local radius = max(3, min(16, floor(scale * 1.85 + 0.5)))
  local edgeMap = edge > 0 and makeEdgeMap(allowed, outX, outY, outWidth, outHeight, radius)
  local bottomField = bottom > 0 and makeBottomField(width, height, mask, seamless)
  local threshold = profile.threshold - density * 0.47 - max(0, 1 - width * height / 1024) * density * 0.15
  local shoulder = 0.035 + softness * 0.235
  local onset = threshold - shoulder * 0.67
  local opacity = (0.27 + profile.opacity * intensity) * (1 - 0.22 * softness) * min(1, density * 5)

  local surfaceSampler, weatherSampler, surfaceGain
  local surface = options.surface
  if type(surface) == "table" and type(surface.heights) == "table" then
    local strength = tonumber(surface.strength) or Texture.defaultSurfaceStrength
    if strength > 0 then
      local blend = min(100, strength) / 100
      surfaceSampler = Surface.sampler(width, height, surface.heights, seamless, surface.placement, style)
      surfaceGain = blend * 0.24
    end
    if runoff > 0 then
      weatherSampler = Weather.sampler(width, height, surface.heights, seamless, mask, scale)
    end
  end

  local index = 1
  for row = 0, outHeight - 1 do
    local rawY = outY + row
    local y = seamless and rawY % height or rawY
    for column = 0, outWidth - 1 do
      local rawX = outX + column
      local packed = 0
      if allowed(rawX, rawY) then
        local x = seamless and rawX % width or rawX
        local score, pigment, streak = sample(x, y)
        if edgeMap then score = score + (edgeMap(column, row) - 0.38) * edge * 0.45 end
        if bottomField then score = score + (bottomField(x, y) - 0.48) * bottom * 0.43 end
        if surfaceSampler then
          local coverage, tone = surfaceSampler(x, y)
          score = score + coverage * surfaceGain
          pigment = pigment + tone * surfaceGain * 0.48
        end
        if weatherSampler then
          local wetness, flow, retention, sediment = weatherSampler(x, y)
          local placement, tone = profile.weather(wetness, flow, retention, sediment, streak)
          score, pigment = score + runoff * placement, pigment + runoff * tone
        end
        local fade = smooth(clampUnit((score - onset) / (shoulder * 1.52)))
        local coverage = depositByte(fade * opacity)
        if coverage > 0 then
          local tone = depositByte((pigment - 0.5) * (0.8 + profile.contrast * intensity) + 0.5)
          packed = (tone << 8) | coverage
        end
      end
      result[index] = packed
      index = index + 1
    end
  end
  return result
end

function Texture.generateSoftDeposit(width, height, options, mask, rect)
  options = options or {}
  local style = Texture.isSoftDeposit(options.style) and options.style or "Dirt"
  return generateSoftDeposit(width, height, options, mask, rect, style)
end

function Texture.generateRust(width, height, options, mask, rect)
  return generateSoftDeposit(width, height, options or {}, mask, rect, "Rust")
end

local defaultRustColors = Texture.defaultColors("Rust")

function Texture.softDepositSample(sample, colors)
  if not sample or sample <= 0 then return nil end
  colors = colors or defaultRustColors
  local tone, coverage = (sample >> 8) & 255, sample & 255
  local low, high, fraction
  if tone < 128 then
    low, high, fraction = colors[1], colors[2], tone / 128
  else
    low, high, fraction = colors[2], colors[3], (tone - 128) / 127
  end
  local lowAlpha, highAlpha = low.a or 255, high.a or 255
  local alpha = floor((lowAlpha + (highAlpha - lowAlpha) * fraction) * coverage / 255 + 0.5)
  if alpha == 0 then return nil end
  return floor(low.r + (high.r - low.r) * fraction + 0.5),
         floor(low.g + (high.g - low.g) * fraction + 0.5),
         floor(low.b + (high.b - low.b) * fraction + 0.5), alpha
end

Texture.rustSample = Texture.softDepositSample

return Texture
