local Catalog = require("lib.material_catalog")
local Surface = require("lib.surface")

local Sample = {}
local abs, floor, min, max = math.abs, math.floor, math.min, math.max
local tau = 2 * math.pi

local function unit(value)
  return max(0, min(1, value))
end

local function mix(a, b, amount)
  return a + (b - a) * amount
end

local function cubic(value)
  return value * value * (3 - 2 * value)
end

local function smooth(low, high, value)
  return cubic(unit((value - low) / (high - low)))
end

local function hash(x, y, seed)
  local bits = ((x * 0x9e3779b1) ~ (y * 0x85ebca77) ~ seed) & 0xffffffff
  bits = ((bits ~ (bits >> 16)) * 0x7feb352d) & 0xffffffff
  bits = ((bits ~ (bits >> 15)) * 0x846ca68b) & 0xffffffff
  return (bits ~ (bits >> 16)) / 4294967296
end

local function field(columns, rows, seed)
  local grid = {}
  for y = 0, rows - 1 do
    for x = 0, columns - 1 do
      grid[y * columns + x + 1] = hash(x, y, seed)
    end
  end
  return function(u, v)
    local x, y = u * columns, v * rows
    local i, j = floor(x), floor(y)
    local fx, fy = cubic(x - i), cubic(y - j)
    local left, right = i % columns + 1, (i + 1) % columns + 1
    local top, bottom = j % rows * columns, (j + 1) % rows * columns
    return mix(mix(grid[top + left], grid[top + right], fx),
      mix(grid[bottom + left], grid[bottom + right], fx), fy) - 0.5
  end
end

local function centered(value)
  return (value + 0.5) % 1 - 0.5
end

local function line(value, core, fade)
  return 1 - smooth(core, fade, abs(centered(value)))
end

local function bark(seed, count, noise)
  local ribs, fractures = count(11), count(7)
  local drift = noise(5, 8, seed + 29)
  local grain = noise(37, 26, seed + 73)
  local plates = noise(14, 9, seed + 133)
  return function(u, v)
    local warped = u + 0.073 * drift(u, v) + 0.009 * grain(u, v)
    local rib = ribs * warped
    local index = floor(rib) % ribs
    local seam = line(rib, 0.028, 0.17)
    local shoulder = line(rib - 0.23, 0.04, 0.22)
    local cross = fractures * v + hash(index, 1, seed + 67) + 0.17 * plates(u, v)
    local crack = line(cross, 0.018, 0.102)
      * (0.23 + 0.77 * smooth(0.12, 0.46, abs(centered(rib))))
    local plate = hash(index, floor(cross) % fractures, seed + 55) - 0.5
    local tone = 0.56 + 0.21 * plate + 0.17 * grain(u, v) + 0.17 * shoulder - 0.37 * seam - 0.19 * crack
    return tone, 0.53 + 0.09 * plate + 0.08 * shoulder - 0.22 * seam - 0.095 * crack
  end
end

local function planks(seed, count, noise)
  local boards, fibers = count(5), count(27)
  local warp = noise(9, 6, seed + 41)
  local fiber = noise(35, 9, seed + 79)
  local pores = noise(63, 24, seed + 109)
  return function(u, v)
    local weather = warp(u, v)
    local position = boards * (u + 0.004 * weather)
    local board = floor(position) % boards
    local boardHue = hash(board, 0, seed + 16) - 0.5
    local knotX = 0.26 + 0.46 * hash(board, 0, seed + 23)
    local knotY = hash(board, 0, seed + 33)
    local dx, dy = position % 1 - knotX, centered(v - knotY)
    local knot = 1 - smooth(0.10, 1.3, dx * dx * 18 + dy * dy * 105)
    local bend = weather * 0.026 + dx * knot * 0.080
    local rings = math.cos(tau * (fibers * (u + bend) + 0.22 * math.sin(tau * 2 * v)))
    local seam = line(position, 0.007, 0.052) * (0.72 + 0.56 * weather)
    local thread = fiber(u + bend, v)
    local tone = 0.54 + 0.085 * boardHue + 0.25 * thread + 0.043 * rings
      + 0.09 * weather + 0.048 * pores(u, v) - 0.075 * seam - 0.18 * knot
    return tone, 0.50 + 0.026 * rings + 0.053 * thread - 0.026 * seam - 0.045 * knot
  end
end

local function metal(seed, _, noise)
  local cloud = noise(8, 6, seed + 37)
  local brush = noise(7, 39, seed + 81)
  local mottle = noise(29, 25, seed + 118)
  return function(u, v)
    local broad, grain, speckle = cloud(u, v), brush(u, v), mottle(u, v)
    return 0.51 + 0.38 * broad + 0.17 * grain + 0.22 * speckle,
      0.50 + 0.097 * broad + 0.051 * grain + 0.058 * speckle
  end
end

local function painted(seed, count, noise)
  local paint = noise(8, 9, seed + 53)
  local film = noise(33, 36, seed + 17)
  local columns, rows = count(4), count(4)
  return function(u, v)
    local panelU, panelV = columns * u + 0.34, rows * v + 0.14
    local seam = max(line(panelU, 0.010, 0.066), line(panelV, 0.009, 0.060))
    local bevel = max(line(panelU - 0.072, 0.010, 0.054), line(panelV - 0.075, 0.010, 0.054))
    local dx, dy = (abs(centered(panelU)) - 0.142) / 0.065, (abs(centered(panelV)) - 0.133) / 0.057
    local distance = dx * dx + dy * dy
    local stud = 1 - smooth(0.33, 1.15, distance)
    local pocket = 1 - smooth(1.0, 1.90, distance) - stud
    local tone = 0.61 + 0.24 * paint(u, v) + 0.11 * film(u, v)
      - 0.085 * seam + 0.028 * bevel + 0.13 * stud - 0.14 * pocket
    return tone, 0.48 + 0.035 * paint(u, v) - 0.034 * seam + 0.014 * bevel + 0.15 * stud
  end
end

local function plastic(seed, count, noise)
  local cloud = noise(8, 7, seed + 41)
  local grain = noise(60, 38, seed + 89)
  local pebbles = noise(36, 31, seed + 103)
  local rows = count(3)
  return function(u, v)
    local surface = cloud(u, v)
    local pebble = smooth(0.14, 0.42, pebbles(u, v))
    local moldLine = line(rows * v + 0.18, 0.010, 0.036)
    local shoulder = line(rows * v + 0.112, 0.040, 0.110)
    local texture = 0.20 * grain(u, v) + 0.083 * pebble
    local tone = 0.63 + 0.22 * surface + texture - 0.25 * moldLine + 0.064 * shoulder
    return tone, 0.50 + 0.029 * surface + 0.019 * pebble + 0.031 * texture - 0.077 * moldLine + 0.036 * shoulder
  end
end

local function stone(seed, count, noise)
  local columns, rows = count(4), count(4)
  local veinX, veinY = count(2), count(3)
  local drift = noise(7, 6, seed + 37)
  local split = noise(13, 11, seed + 91)
  local grit = noise(44, 39, seed + 127)
  local sites = {}
  for y = 0, rows - 1 do
    for x = 0, columns - 1 do
      sites[y * columns + x + 1] = {
        x = 0.08 + 0.84 * hash(x, y, seed + 149),
        y = 0.13 + 0.74 * hash(x, y, seed + 197),
        tone = hash(x, y, seed + 261) - 0.5,
        breakage = hash(x, y, seed + 311),
      }
    end
  end
  return function(u, v)
    local warp, details = drift(u, v), split(u, v)
    local x = (u + v + 0.064 * warp + 0.016 * details) * columns
    local y = (v - 0.058 * warp + 0.019 * details) * rows
    local cellX, cellY = floor(x), floor(y)
    local first, second = math.huge, math.huge
    local face, neighbor, dx, dy
    for j = cellY - 1, cellY + 1 do
      for i = cellX - 1, cellX + 1 do
        local site = sites[j % rows * columns + i % columns + 1]
        local sx, sy = x - i - site.x, y - j - site.y
        local distance = sx * sx + sy * sy
        if distance < first then
          first, second = distance, first
          neighbor = face
          face, dx, dy = site, sx, sy
        elseif distance < second then
          second, neighbor = distance, site
        end
      end
    end

    -- The plane stays coherent inside a fragment. A shallow bright lip follows
    -- the dark fissure on the side facing the upper left.
    local gap = second - first
    local plane = unit(0.5 + 0.53 * dx + 0.76 * dy) - 0.5
    local lightSide = smooth(0.04, 0.45, dx + dy)
    local fracture = 0.21 + 0.79 * smooth(0.36, 0.65, (face.breakage + neighbor.breakage) * 0.5)
    local fault = (1 - smooth(0.023, 0.157, gap)) * (0.81 + 0.58 * details) * fracture
    local lip = (1 - smooth(0.11, 0.35, gap)) * smooth(0.028, 0.13, gap) * lightSide * fracture
    local vein = line(veinX * u + veinY * v + 0.44 * warp + 0.12 * details, 0.015, 0.089)
      * smooth(-0.21, 0.28, details)
    local grain = grit(u, v)
    local tone = 0.55 + 0.30 * face.tone + 0.20 * plane + 0.15 * details + 0.09 * grain
      + 0.18 * lip - 0.37 * fault - 0.091 * vein
    return tone, 0.51 + 0.14 * face.tone + 0.10 * plane + 0.036 * grain
      + 0.060 * lip - 0.25 * fault - 0.028 * vein
  end
end

local function concrete(seed, _, noise)
  local cloud = noise(5, 5, seed + 41)
  local patches = noise(14, 13, seed + 73)
  local aggregate = noise(31, 29, seed + 101)
  local bubbles = noise(23, 21, seed + 131)
  local grain = noise(64, 57, seed + 173)
  return function(u, v)
    local broad, cast = cloud(u, v), patches(u, v)
    local sand = grain(u, v)
    local small = aggregate(u, v)
    local stoneDust = smooth(0.14, 0.40, small) - 0.68 * smooth(0.18, 0.44, -small)
    local air = bubbles(u + 0.016 * cast, v + 0.021 * broad) + 0.09 * cast
    local dimple = smooth(0.24, 0.42, air)
    local pore = smooth(0.35, 0.48, air)
    local tone = 0.56 + 0.18 * broad + 0.12 * cast + 0.052 * sand + 0.074 * stoneDust
      - 0.060 * dimple - 0.16 * pore
    return tone, 0.51 + 0.034 * broad + 0.023 * cast + 0.014 * sand + 0.014 * stoneDust
      - 0.035 * dimple - 0.098 * pore
  end
end

local patterns = {
  bark = bark,
  ["wood-planks"] = planks,
  metal = metal,
  ["painted-metal"] = painted,
  plastic = plastic,
  stone = stone,
  concrete = concrete,
}

local function setting(value, default, low, high)
  value = tonumber(value)
  if not value or value ~= value then return default end
  return max(low, min(high, value))
end

local function byte(value)
  return floor(max(0, min(255, value)) + 0.5)
end

local function rgbAt(palette, value)
  if #palette == 1 then
    local color = palette[1]
    return byte(color.r), byte(color.g), byte(color.b)
  end
  local pos = unit(value) * (#palette - 1)
  local index = min(#palette - 1, floor(pos) + 1)
  local left, right = palette[index], palette[index + 1]
  local w = pos - index + 1
  return byte(mix(left.r, right.r, w)), byte(mix(left.g, right.g, w)), byte(mix(left.b, right.b, w))
end

local function pixel(r, g, b)
  return (r << 16) | (g << 8) | b
end

local function rgb(value)
  return (value >> 16) & 255, (value >> 8) & 255, value & 255
end

-- Pattern frequency uses an integer number of features per tile so a scale
-- change does not introduce a jump when the tile repeats.
function Sample.generate(width, height, material, seed, options)
  width, height = max(1, floor(width)), max(1, floor(height))
  options = options or {}
  local default = Catalog.recipe("metal")
  local recipe = type(material) == "table" and material or Catalog.recipe(material) or default
  local palette = recipe.palette and #recipe.palette > 0 and recipe.palette or default.palette
  local scale = setting(options.patternScale, 100, 25, 250)
  local function count(frequency)
    return max(1, floor(frequency * 100 / scale + 0.5))
  end
  local function noise(columns, rows, fieldSeed)
    return field(count(columns), count(rows), fieldSeed)
  end
  local pattern = patterns[recipe.pattern or recipe.id] or metal
  local shape = pattern(math.tointeger(tonumber(seed)) or 1, count, noise)
  local horizontal = options.patternDirection == "Horizontal"
  local colors, heights = {}, {}
  for y = 0, height - 1 do
    local v = (y + 0.5) / height
    for x = 0, width - 1 do
      local u = (x + 0.5) / width
      local index = y * width + x + 1
      local tone, relief
      if horizontal then tone, relief = shape(v, u) else tone, relief = shape(u, v) end
      colors[index], heights[index] = pixel(rgbAt(palette, tone)), unit(relief)
    end
  end
  local function read(x, y)
    local value = colors[(floor(y) % height) * width + floor(x) % width + 1]
    local r, g, b = rgb(value)
    return r, g, b, 255
  end
  return read, heights, {
    roughness = setting(recipe.roughness, default.roughness, 0, 1),
    metalness = setting(recipe.metalness, default.metalness, 0, 1),
    relief = setting(recipe.relief, default.relief, 0, 3),
  }
end

-- Bake the same surface into a prop. An alpha-weighted reference isolates
-- painted highlights and shadows from the average brightness of the input.
function Sample.forArtwork(width, height, material, seed, baseReader, mask, options)
  width, height = max(1, floor(width)), max(1, floor(height))
  options = options or {}
  local pattern, relief, response = Sample.generate(width, height, material, seed, options)
  local amount = setting(options.patternAmount, 100, 0, 100) / 100
  local lighting = setting(options.lighting, 80, 0, 100) / 100
  local heights, colors, alpha = {}, {}, {}
  local brightness, weight = 0, 0
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local index = y * width + x + 1
      if not mask or (mask[index] and mask[index] ~= 0) then
        local r, g, b, a = baseReader(x, y)
        if r and (not a or a > 0) then
          colors[index], alpha[index] = pixel(r, g, b), a or 255
          brightness = brightness + Surface.luminance(r, g, b) * alpha[index]
          weight = weight + alpha[index]
        end
      end
    end
  end

  local reference = weight > 0 and brightness / weight or 0.5
  for index, value in pairs(colors) do
    local r, g, b = rgb(value)
    local pr, pg, pb = pattern((index - 1) % width, (index - 1) // width)
    local original = options.heights and options.heights[index] or 0.5
    local light = (Surface.luminance(r, g, b) - reference) * lighting * 255
    colors[index] = pixel(byte(mix(r, pr + light, amount)),
      byte(mix(g, pg + light, amount)), byte(mix(b, pb + light, amount)))
    heights[index] = unit(original + (relief[index] - 0.5) * amount)
  end

  return function(x, y)
    local index = y * width + x + 1
    if x < 0 or y < 0 or x >= width or y >= height or not colors[index] then return end
    local r, g, b = rgb(colors[index])
    return r, g, b, alpha[index]
  end, heights, response
end

return Sample
