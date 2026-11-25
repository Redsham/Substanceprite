local Normal = {}

Normal.defaults = { strength = 50, smoothing = 0, invertGreen = false, seamless = false }
Normal.neutral = 0x8080ff
Normal.missing = -1

local floor, min, max, sqrt = math.floor, math.min, math.max, math.sqrt
local kernels = {
  { 2, 1 },
  { 6, 4, 1 },
  { 20, 15, 6, 1 },
}

function Normal.rgb(sample)
  if sample == nil or sample == Normal.missing then return nil end
  return (sample >> 16) & 255, (sample >> 8) & 255, sample & 255
end

local function number(value, fallback, low, high)
  value = tonumber(value)
  if not value or value ~= value then return fallback end
  return max(low, min(high, value))
end

local function heightReader(width, height, heights, mask, seamless)
  return function(x, y)
    if seamless then
      x, y = x % width, y % height
    elseif x < 0 or x >= width or y < 0 or y >= height then
      return nil
    end
    local index = y * width + x + 1
    if not mask or mask[index] then return heights[index] end
  end
end

-- Keep only the scanlines near the current pixel. A detail preview samples the
-- same neighborhood as a full bake without allocating a smoothed full canvas.
local function cacheRows(read, capacity)
  local rows, order, nextSlot = {}, {}, 1
  return function(x, y)
    local row = rows[y]
    if not row then
      local oldest = order[nextSlot]
      if oldest then rows[oldest] = nil end
      row = {}
      rows[y], order[nextSlot] = row, y
      nextSlot = nextSlot % capacity + 1
    end
    local value = row[x]
    if value == nil then
      value = read(x, y) or false
      row[x] = value
    end
    return value or nil
  end
end

local function blurAxis(read, kernel, dx, dy)
  return function(x, y)
    local center = read(x, y)
    if center == nil then return nil end

    local weight = kernel[1]
    local sum = center * weight
    for side = -1, 1, 2 do
      for i = 2, #kernel do
        local distance = side * (i - 1)
        local neighbor = read(x + dx * distance, y + dy * distance)
        if neighbor == nil then break end
        sum = sum + neighbor * kernel[i]
        weight = weight + kernel[i]
      end
    end
    return sum / weight
  end
end

local function gradient(previous, center, nextValue)
  if previous ~= nil and nextValue ~= nil then return (nextValue - previous) * 0.5 end
  if previous ~= nil then return center - previous end
  if nextValue ~= nil then return nextValue - center end
  return 0
end

local function channel(value)
  return floor(128 + 127.5 * value)
end

-- Heights are normalized to [0, 1]. Coordinates and an optional output rect are
-- zero-based. The flat input, mask and result tables are row-major with 1-based
-- indexes. Pixels with no height are always Normal.missing, including holes.
function Normal.generate(width, height, heights, options, mask, rect)
  width, height = floor(width), floor(height)
  rect = rect or { x = 0, y = 0, width = width, height = height }
  local outWidth, outHeight = floor(rect.width), floor(rect.height)
  if outWidth < 1 or outHeight < 1 then return {} end

  local result = {}
  if width < 1 or height < 1 or not heights then
    for index = 1, outWidth * outHeight do result[index] = Normal.missing end
    return result
  end

  options = options or {}
  local strength = number(options.strength, Normal.defaults.strength, 0, 200) * 0.04
  local smoothing = floor(number(options.smoothing, Normal.defaults.smoothing, 0, #kernels))
  local greenSign = options.invertGreen and -1 or 1
  local sample = heightReader(width, height, heights, mask, options.seamless)
  if smoothing > 0 and strength > 0 then
    local kernel = kernels[smoothing]
    local horizontal = cacheRows(blurAxis(sample, kernel, 1, 0), 2 * smoothing + 4)
    sample = cacheRows(blurAxis(horizontal, kernel, 0, 1), 4)
  end

  local outX, outY = floor(rect.x), floor(rect.y)
  local index = 1
  for y = outY, outY + outHeight - 1 do
    for x = outX, outX + outWidth - 1 do
      local center = sample(x, y)
      local pixel = Normal.missing
      if center ~= nil then
        pixel = Normal.neutral
        if strength > 0 then
          local dx = gradient(sample(x - 1, y), center, sample(x + 1, y))
          local dy = gradient(sample(x, y - 1), center, sample(x, y + 1))
          -- Image Y increases down, while the tangent-space Y axis points up.
          local nx, ny = -dx * strength, dy * strength * greenSign
          local z = 1 / sqrt(1 + nx * nx + ny * ny)
          pixel = (channel(nx * z) << 16) | (channel(ny * z) << 8) | channel(z)
        end
      end
      result[index] = pixel
      index = index + 1
    end
  end
  return result
end

return Normal
