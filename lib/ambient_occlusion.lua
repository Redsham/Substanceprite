local AO = {}

AO.defaults = { strength = 50, radius = 6 }
AO.maxRadius = 24
AO.maxDarkening = 0.58

local floor, min, max, sqrt = math.floor, math.min, math.max, math.sqrt
local directions = { {1, 0}, {0, 1}, {1, 1}, {-1, 1} }
local heightBias = 0.008

local function unit(value)
  return min(1, max(0, value))
end

local function smooth(value)
  return value * value * (3 - 2 * value)
end

local function maskAllows(mask, index, x, y)
  if not mask then return true end
  local value
  if type(mask) == "function" then value = mask(x, y) else value = mask[index] end
  return value and value ~= 0
end

local function clear(result, count)
  for i = 1, count do result[i] = 0 end
  return result
end

local function scanPairs(radius)
  local pairs = {}
  for _, direction in ipairs(directions) do
    local dx, dy = direction[1], direction[2]
    local stride = sqrt(dx * dx + dy * dy)
    local gains, fades = {}, {}
    for step = 1, floor(radius / stride) do
      local distance = step * stride
      gains[step] = 4.8 / (1 + 0.30 * (distance - 1))
      fades[step] = 1 - smooth(unit((distance - radius * 0.58) / (radius * 0.42 + 0.85)))
    end
    if #gains > 0 then pairs[#pairs + 1] = { dx = dx, dy = dy, gains = gains, fades = fades } end
  end
  return pairs
end

local function scan(field, width, height, x, y, z, pair, seamless)
  local dx, dy = pair.dx, pair.dy
  local gains, fades, steps = pair.gains, pair.fades, #pair.gains
  if not seamless then
    if dx ~= 0 then steps = min(steps, x, width - x - 1) end
    if dy ~= 0 then steps = min(steps, y, height - y - 1) end
  end
  local center, offset = y * width + x + 1, dy * width + dx
  local aIndex, bIndex = center, center
  local strongest = 0
  for step = 1, steps do
    if seamless then
      local ox, oy = dx * step, dy * step
      aIndex = (y - oy) % height * width + (x - ox) % width + 1
      bIndex = (y + oy) % height * width + (x + ox) % width + 1
    else
      aIndex, bIndex = aIndex - offset, bIndex + offset
    end

    local a, b = field[aIndex], field[bIndex]
    if a == nil or b == nil then break end
    -- Opposite samples cancel a planar slope. The small threshold also rejects
    -- the height difference from rounding a shallow slope to 8-bit values.
    local rise = (a + b) * 0.5 - z - heightBias
    if rise > 0 then
      strongest = max(strongest, smooth(unit(rise * gains[step])) * fades[step])
    end
    if step < steps and strongest >= fades[step + 1] then break end
  end
  return strongest
end

-- Normalized heights, row-major results and 0-based crop coordinates.
-- Masked pixels receive no occlusion and stop each directional scan.
-- Strength is applied by the caller after the geometric coverage is computed.
function AO.generate(width, height, heights, options, mask, rect)
  width, height = floor(width), floor(height)
  rect = rect or { x = 0, y = 0, width = width, height = height }
  local outWidth, outHeight = floor(rect.width), floor(rect.height)
  local result = {}
  if outWidth < 1 or outHeight < 1 then return result end
  local count = outWidth * outHeight
  options = options or {}
  local radius = tonumber(options.radius)
  if not radius or radius ~= radius then radius = AO.defaults.radius end
  radius = floor(max(0, min(AO.maxRadius, radius)) + 0.5)
  if width < 1 or height < 1 or not heights or radius == 0 then
    return clear(result, count)
  end

  local field = {}
  local low, high = 1, 0
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local index = y * width + x + 1
      local z = heights[index]
      if type(z) == "number" and z == z and maskAllows(mask, index, x, y) then
        z = unit(z)
        field[index] = z
        low, high = min(low, z), max(high, z)
      end
    end
  end
  if high - low <= heightBias then return clear(result, count) end

  local pairs = scanPairs(radius)
  local originX, originY = floor(rect.x), floor(rect.y)
  local seamless = options.seamless == true
  for v = 0, outHeight - 1 do
    for u = 0, outWidth - 1 do
      local x, y = originX + u, originY + v
      if seamless then x, y = x % width, y % height end
      local coverage = 0
      if x >= 0 and x < width and y >= 0 and y < height then
        local z = field[y * width + x + 1]
        if z and z < high - heightBias then
          for _, pair in ipairs(pairs) do
            coverage = coverage + scan(field, width, height, x, y, z, pair, seamless)
          end
          coverage = coverage / #pairs
        end
      end
      result[v * outWidth + u + 1] = coverage
    end
  end
  return result
end

return AO
