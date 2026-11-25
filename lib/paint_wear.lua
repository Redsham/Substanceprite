local Wear = {}
Wear.defaults = { edgeWear = 0, edgeWidth = 2, scuffs = 0, scuffDirection = "Auto", fading = 0 }

local abs, floor, min, max = math.abs, math.floor, math.min, math.max

local function number(value, fallback, lower, upper)
  value = tonumber(value)
  if not value or value ~= value then value = fallback end
  return max(lower, min(upper, value))
end

local function smooth(value)
  value = max(0, min(1, value))
  return value * value * (3 - 2 * value)
end

local function byte(value)
  return floor(max(0, min(1, value)) * 255 + 0.5)
end

local function hash(x, y, seed)
  local bits = ((x * 0x9e3779b1) ~ (y * 0x85ebca77) ~ seed) & 0xffffffff
  bits = ((bits ~ (bits >> 16)) * 0x7feb352d) & 0xffffffff
  bits = ((bits ~ (bits >> 15)) * 0x846ca68b) & 0xffffffff
  return (bits ~ (bits >> 16)) / 4294967296
end

local function gridAxis(size, step, seamless)
  if size >= 6 then step = min(step, size * 0.53) end
  local cells = seamless and max(1, floor(size / step + 0.5))
  if cells then step = size / cells end
  local axis = {}
  for pixel = 0, size - 1 do
    local position = (pixel + 0.5) / step
    local left = floor(position)
    axis[pixel] = {
      cells and left % cells or left,
      cells and (left + 1) % cells or left + 1,
      smooth(position - left),
    }
  end
  return axis
end

-- Interpolated fields keep rubbed areas coherent across neighboring pixels.
local function field(width, height, along, across, seed, seamless)
  local xs = gridAxis(width, along, seamless)
  local ys = gridAxis(height, across, seamless)
  local cachedY, lattice
  return function(x, y)
    local xx, yy = xs[x], ys[y]
    if cachedY ~= yy[1] then
      cachedY, lattice = yy[1], {}
    end
    local key = xx[1]
    local cell = lattice[key]
    if not cell then
      cell = { hash(xx[1], yy[1], seed), hash(xx[2], yy[1], seed),
        hash(xx[1], yy[2], seed), hash(xx[2], yy[2], seed) }
      lattice[key] = cell
    end
    local top = cell[1] + (cell[2] - cell[1]) * xx[3]
    local bottom = cell[3] + (cell[4] - cell[3]) * xx[3]
    return top + (bottom - top) * yy[3]
  end
end

local function readers(width, height, mask, heights, seamless)
  local readsMask = type(mask) == "function"
  local function at(x, y)
    if seamless then x, y = x % width, y % height end
    if x < 0 or y < 0 or x >= width or y >= height then return nil end
    local index = y * width + x + 1
    if mask then
      local value
      if readsMask then value = mask(x, y) else value = mask[index] end
      if not value or value == 0 then return nil end
    end
    return index
  end
  local function relief(index, fallback)
    local value = index and heights and heights[index]
    if type(value) == "number" and value == value then return value end
    return fallback
  end
  return at, relief
end

local function exposedSide(center, a, b)
  -- A uniform slope produces no bevel. A downward step exposes its high side.
  local descent = max(0, center - min(a, b))
  local rise = max(0, max(a, b) - center)
  return smooth((descent - rise * 0.82 - 0.065) * 4.2)
end

local function edgeAt(x, y, index, reach, at, relief)
  local center = relief(index)
  local tangentX, tangentY = 0, 0
  for distance = 1, reach do
    local left, right = at(x - distance, y), at(x + distance, y)
    local above, below = at(x, y - distance), at(x, y + distance)
    local weight = 1 - (distance - 1) / reach
    if not above or not below then
      tangentX = max(tangentX, weight)
    elseif center then
      tangentX = max(tangentX, exposedSide(center, relief(above, center), relief(below, center)) * weight)
    end
    if not left or not right then
      tangentY = max(tangentY, weight)
    elseif center then
      tangentY = max(tangentY, exposedSide(center, relief(left, center), relief(right, center)) * weight)
    end
  end
  return tangentX, tangentY
end

local function contactWidth(contact, patch, amount)
  local exposed = smooth((patch - 0.64 + 0.23 * amount) / 0.30)
  return smooth(contact) * exposed
end

local function stroke(buffer, tones, along, across, halfLength, halfWidth, slant, bend, strength, tone, tile)
  for u = floor(along - halfLength), math.ceil(along + halfLength) do
    local alongStroke = (u - along) / halfLength
    local taper = smooth((1 - abs(alongStroke)) * 3.1)
    if taper > 0 then
      local middle = across + (u - along) * slant + alongStroke * alongStroke * bend
      local width = halfWidth * (0.55 + 0.45 * taper)
      for v = floor(middle - width - 1), math.ceil(middle + width + 1) do
        local crossStroke = abs(v - middle)
        local coverage = smooth((width + 0.65 - crossStroke) / (width * 0.52 + 0.64))
        if coverage > 0 then
          local index = tile(u, v)
          local opacity = byte(strength * taper * coverage)
          if index and opacity > (buffer[index] or 0) then
            buffer[index], tones[index] = opacity, byte(tone - 0.20 * (1 - coverage))
          end
        end
      end
    end
  end
end

local function scuffGroups(width, height, vertical, seamless, seed, amount)
  local primary, secondary = width, height
  if vertical then primary, secondary = height, width end
  local columns = max(1, floor(primary / 23 + 0.5))
  local rows = max(1, floor(secondary / 10 + 0.5))
  local alongCell, acrossCell = primary / columns, secondary / rows
  local buffer, tones = {}, {}
  local function tile(u, v)
    if seamless then u, v = u % primary, v % secondary end
    if u < 0 or u >= primary or v < 0 or v >= secondary then return end
    if vertical then return u * width + v + 1 end
    return v * width + u + 1
  end
  for row = 0, rows - 1 do
    for column = 0, columns - 1 do
      local function variation(offset) return hash(column, row, seed + offset) end
      local activity = smooth((amount + 0.24 - variation(362)) / 0.31)
      if activity > 0 then
        local u = (column + 0.20 + variation(488) * 0.60) * alongCell - 0.5
        local v = (row + 0.22 + variation(994) * 0.56) * acrossCell - 0.5
        local length = max(1.2, alongCell * (0.27 + variation(336) * 0.30))
        local fan = min(2.8, acrossCell * 0.28)
        local angle = (variation(811) - 0.5) * 0.17
        local bend = variation(613) * 0.82 - 0.41
        local strength = activity * (0.26 + 0.74 * amount)
        stroke(buffer, tones, u, v, length * 1.08, max(0.75, fan * 0.88), angle, bend,
          strength * 0.31, 0.51, tile)
        for mark = 0, 2 + floor(variation(393) * 2) do
          local offset = mark * 37
          local side = mark == 0 and 0 or (variation(591 + offset) - 0.5) * 2 * fan
          local start = (variation(637 + offset) - 0.5) * length * 0.70
          local extent = length * (0.43 + 0.53 * variation(747 + offset))
          local thickness = 0.28 + 0.44 * variation(872 + offset)
          local shadow = variation(245 + offset)
          stroke(buffer, tones, u + start, v + side, extent, thickness, angle, bend,
            strength * (0.54 + 0.40 * shadow), 0.60 + 0.30 * shadow, tile)
        end
      end
    end
  end
  return buffer, tones
end

local function weatherExposure(x, y, index, height, seamless, at, relief)
  local exposure = seamless and 0 or 0.12 * (0.5 - (y + 0.5) / height)
  local center = relief(index)
  if not center then return exposure end
  local above = relief(at(x, y - 2), center)
  local below = relief(at(x, y + 2), center)
  local facingUp = (below - above) * 0.14
  local recess = max(0, (above + below) * 0.5 - center) * 0.13
  return exposure + min(0.10, max(-0.10, facingUp - recess))
end

-- All channels are dense bytes in row-major order. The caller combines edge
-- with chip geometry, while the two surface marks leave the metal map alone.
function Wear.generate(width, height, params, mask)
  local wear = { edge = {}, scuff = {}, fading = {}, scuffTones = {}, fadingTones = {} }
  width, height = floor(width), floor(height)
  if width < 1 or height < 1 then return wear end
  params = params or {}
  local edge = number(params.edgeWear, Wear.defaults.edgeWear, 0, 100) / 100
  local scuff = number(params.scuffs, Wear.defaults.scuffs, 0, 100) / 100
  local fade = number(params.fading, Wear.defaults.fading, 0, 100) / 100
  if edge + scuff + fade == 0 then
    for i = 1, width * height do
      wear.edge[i], wear.scuff[i], wear.fading[i], wear.scuffTones[i], wear.fadingTones[i] = 0, 0, 0, 0, 0
    end
    return wear
  end

  local reach = floor(number(params.edgeWidth, Wear.defaults.edgeWidth, 1, 6) + 0.5)
  local seed = floor(number(params.seed, 1, -2147483648, 4294967295))
  local heights = params.heights or (params.surface and params.surface.heights)
  local seamless = params.seamless == true
  local at, relief = readers(width, height, mask, heights, seamless)

  local rubX, rubY, rough
  if edge > 0 then
    rubX = field(width, height, 10, 2.5, seed + 771, seamless)
    rubY = field(width, height, 2.5, 10, seed + 771, seamless)
    rough = field(width, height, 2.0, 2.0, seed + 149, seamless)
  end
  local scuffCoverage, scuffPigment
  if scuff > 0 then
    local vertical = params.scuffDirection == "Vertical"
      or (params.scuffDirection ~= "Horizontal" and height > width)
    scuffCoverage, scuffPigment = scuffGroups(width, height, vertical, seamless, seed, scuff)
  end
  local chalk, chalkFine
  if fade > 0 then
    chalk = field(width, height, 25, 19, seed + 526, seamless)
    chalkFine = field(width, height, 6, 6, seed + 236, seamless)
  end

  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local i = y * width + x + 1
      local allowed = at(x, y)
      local rubbed, brushed, bleached, scuffTone, fadeTone = 0, 0, 0, 0, 0
      if allowed then
        if rubX then
          local tangentX, tangentY = edgeAt(x, y, i, reach, at, relief)
          if tangentX > 0 or tangentY > 0 then
            local texture = 0.19 * rough(x, y)
            local alongX = contactWidth(tangentX, 0.81 * rubX(x, y) + texture, edge)
            local alongY = contactWidth(tangentY, 0.81 * rubY(x, y) + texture, edge)
            rubbed = byte(max(alongX, alongY) * (0.31 + 0.69 * edge))
          end
        end
        if scuffCoverage and scuffCoverage[i] then
          local center = relief(i)
          local shielding = 1
          if center then
            local high = max(relief(at(x - 1, y), center), relief(at(x + 1, y), center),
              relief(at(x, y - 1), center), relief(at(x, y + 1), center))
            shielding = 1 - 0.68 * smooth((high - center) * 2.4)
          end
          brushed = floor(scuffCoverage[i] * shielding + 0.5)
          if brushed > 0 then scuffTone = scuffPigment[i] end
        end
        if chalk then
          local cloud = 0.87 * chalk(x, y) + 0.13 * chalkFine(x, y)
            + weatherExposure(x, y, i, height, seamless, at, relief)
          local exposure = smooth((cloud - 0.67 + 0.34 * fade) / 0.39)
          bleached = byte(exposure * (0.37 + 0.63 * fade))
          if bleached > 0 then fadeTone = byte(0.26 + 0.52 * cloud + 0.11 * exposure) end
        end
      end
      wear.edge[i], wear.scuff[i], wear.fading[i] = rubbed, brushed, bleached
      wear.scuffTones[i], wear.fadingTones[i] = scuffTone, fadeTone
    end
  end
  return wear
end

return Wear
