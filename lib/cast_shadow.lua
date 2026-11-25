local CastShadow = {}

CastShadow.defaults = { angle = 315, elevation = 35, reach = 12, softness = 30, strength = 55 }
CastShadow.maxDarkening = 0.78

local abs, floor, min, max = math.abs, math.floor, math.min, math.max
local radians, tan = math.rad, math.tan
local epsilon = 1e-10
local maxTraceDistance = 256

local function parameter(value, default, low, high)
  value = tonumber(value)
  if not value or value ~= value then return default end
  return max(low, min(high, value))
end

local function maskAllows(mask, index, x, y)
  if not mask then return true end
  local value
  if type(mask) == "function" then value = mask(x, y) else value = mask[index] end
  return value and value ~= 0
end

-- Trace the cells entered by a ray from a pixel center. A height sample
-- represents a column, so the near face is the nearest possible blocker.
local function rayPath(angle, elevation, spread, reach, range, limit)
  local direction = radians(angle)
  local dx, dy = math.cos(direction), math.sin(direction)
  local stepX, stepY = dx < 0 and -1 or 1, dy < 0 and -1 or 1
  local cellX = abs(dx) > epsilon and 1 / abs(dx) or math.huge
  local cellY = abs(dy) > epsilon and 1 / abs(dy) or math.huge
  local nextX, nextY = cellX * 0.5, cellY * 0.5
  local minSlope = tan(radians(max(5, elevation - spread))) / reach
  local maxSlope = tan(radians(min(89, elevation + spread))) / reach
  local offsetsX, offsetsY, rises, transitions = {}, {}, {}, {}
  local x, y = 0, 0
  limit = min(limit, range / minSlope)
  while true do
    local distance = min(nextX, nextY)
    if distance >= limit then break end
    if nextX <= distance + epsilon then
      x, nextX = x + stepX, nextX + cellX
    end
    if nextY <= distance + epsilon then
      y, nextY = y + stepY, nextY + cellY
    end
    local i = #rises + 1
    offsetsX[i], offsetsY[i] = x, y
    rises[i] = distance * minSlope
    transitions[i] = spread == 0 and 0 or 1 / (distance * (maxSlope - minSlope))
  end
  return { x = offsetsX, y = offsetsY, rises = rises, transitions = transitions }
end

local function trace(ray, x, y, center, greatest, heights, width, height, seamless)
  local available = greatest - center
  local coverage = 0
  local offsetsX, offsetsY, rises, transitions = ray.x, ray.y, ray.rises, ray.transitions
  for i = 1, #rises do
    local rise = rises[i]
    if rise >= available - epsilon then break end
    local xx, yy = x + offsetsX[i], y + offsetsY[i]
    if seamless then
      xx, yy = xx % width, yy % height
    elseif xx < 0 or xx >= width or yy < 0 or yy >= height then
      break
    end
    local blocker = heights[yy * width + xx + 1]
    if blocker then
      local overlap = blocker - center - rise
      if overlap > epsilon then
        local transition = transitions[i]
        local cover = overlap * transition
        if transition == 0 or cover >= 1 then return 1 end
        coverage = max(coverage, cover * cover * (3 - 2 * cover))
      end
    end
  end
  return coverage
end

-- Normalized heights and 0-based coordinates; inputs and result are row-major.
-- Masked and undefined pixels cannot cast or receive. A rect only crops the
-- output, so objects outside an on-screen preview can still cast into it.
function CastShadow.generate(width, height, heights, settings, mask, rect)
  width, height = floor(width), floor(height)
  rect = rect or { x = 0, y = 0, width = width, height = height }
  local outWidth, outHeight = floor(rect.width), floor(rect.height)
  if outWidth < 1 or outHeight < 1 then return {} end

  settings = settings or {}
  local defaults = CastShadow.defaults
  local reach = parameter(settings.reach, defaults.reach, 0, 64)
  local result = {}
  if width < 1 or height < 1 or not heights or reach == 0 then
    for i = 1, outWidth * outHeight do result[i] = 0 end
    return result
  end

  local lowest, highest = 1, 0
  local field = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local index = y * width + x + 1
      local z = heights[index]
      if type(z) == "number" and z == z and maskAllows(mask, index, x, y) then
        z = max(0, min(1, z))
        field[index] = z
        lowest, highest = min(lowest, z), max(highest, z)
      end
    end
  end
  if highest <= lowest then
    for i = 1, outWidth * outHeight do result[i] = 0 end
    return result
  end

  local angle = tonumber(settings.angle)
  angle = angle and angle % 360
  if not angle or angle ~= angle then angle = defaults.angle end
  local elevation = parameter(settings.elevation, defaults.elevation, 5, 85)
  local spread = parameter(settings.softness, defaults.softness, 0, 100) * 0.09
  local seamless = settings.seamless == true
  local limit = maxTraceDistance
  if not seamless then limit = min(limit, math.sqrt(width * width + height * height)) end
  local main = rayPath(angle, elevation, spread, reach, highest - lowest, limit)
  local left, right
  if spread > 0 then
    left = rayPath(angle - spread, elevation, spread, reach, highest - lowest, limit)
    right = rayPath(angle + spread, elevation, spread, reach, highest - lowest, limit)
  end

  local originX, originY = floor(rect.x), floor(rect.y)
  for v = 0, outHeight - 1 do
    for u = 0, outWidth - 1 do
      local x, y = originX + u, originY + v
      if seamless then x, y = x % width, y % height end
      local coverage = 0
      if x >= 0 and x < width and y >= 0 and y < height then
        local center = field[y * width + x + 1]
        if center and center < highest then
          coverage = trace(main, x, y, center, highest, field, width, height, seamless)
          if left then
            -- An angular penumbra widens with blocker distance without blurring
            -- across transparent pixels or the well-defined contact edge.
            local a = trace(left, x, y, center, highest, field, width, height, seamless)
            local b = trace(right, x, y, center, highest, field, width, height, seamless)
            coverage = (a + 2 * coverage + b) * 0.25
          end
        end
      end
      result[v * outWidth + u + 1] = coverage
    end
  end
  return result
end

return CastShadow
