local Streaks = {}
local floor, min, max = math.floor, math.min, math.max

local function unit(value)
  return max(0, min(1, value))
end

local function option(value, fallback, low, high)
  value = tonumber(value)
  if not value or value ~= value then return fallback end
  return max(low, min(high, value))
end

local function neutral()
  return 0, 0.5
end

local function grain(x, y, seed)
  local value = ((x * 0x9e3779b1) ~ (y * 0x85ebca77) ~ seed) & 0xffffffff
  value = ((value ~ (value >> 16)) * 0x7feb352d) & 0xffffffff
  value = ((value ~ (value >> 15)) * 0x846ca68b) & 0xffffffff
  return (value ~ (value >> 16)) / 4294967296
end

-- Only an actual oxide pixel can supply pigment. The guide changes how it
-- travels through the next row and how much settles along the way.
function Streaks.sampler(width, height, heights, mask, seamless, sourceAt, options)
  width, height = floor(width), floor(height)
  options = options or {}
  local strength = option(options.strength, 65, 0, 100) / 100
  if width < 1 or height < 2 or strength == 0 or type(sourceAt) ~= "function" then
    return neutral
  end

  local scale = option(options.scale, 4, 1, 64)
  local seed = floor(option(options.seed, 1, -2147483648, 4294967295))
  local routes = type(options.routes) == "function" and options.routes or nil
  local guide = type(heights) == "table" and heights or nil
  local decay = 0.69 + 0.18 * unit((scale - 1) / 18)
  local epsilon = 0.00015
  local wrapY = seamless and options.wrapY ~= false
  local warmup = wrapY and math.ceil(math.log(epsilon * 0.001) / math.log(decay)) or 0

  local function allowed(x, y)
    if wrapY then y = y % height elseif y < 0 or y >= height then return false end
    if seamless then x = x % width elseif x < 0 or x >= width then return false end
    return not mask or not not mask[y * width + x + 1]
  end

  local function heightAt(x, y)
    if not guide or not allowed(x, y) then return nil end
    local value = guide[(y % height) * width + (x % width) + 1]
    if type(value) == "number" and value == value then return unit(value) end
  end

  local function routeWeight(from, to, lateral, forwardHeight)
    if from == nil or to == nil then return lateral and 0.025 or 1 end
    local fall = unit((from - to) * 3.5)
    local rise = unit((to - from) * 7)
    -- Take the straight route when all three destinations are equally low.
    local bias = lateral and (0.025 + 0.70 * unit(((forwardHeight or from) - to) * 3.5)) or 1
    return bias * (0.18 + 4.5 * fall) * (1 - rise)^2
  end

  local function add(incoming, x, amount, hue)
    if amount < epsilon then return end
    local i = (x % width) * 2 + 1
    incoming[i] = (incoming[i] or 0) + amount
    incoming[i + 1] = (incoming[i + 1] or 0) + hue
  end

  local rows, sourceRows, incoming = {}, {}, {}
  local nextY = -warmup

  local function readSources(y)
    local h = y % height
    local remembered = sourceRows[h]
    if remembered then return remembered end
    local row = {}
    for x = 0, width - 1 do
      if allowed(x, h) then
        local oxide, tone = sourceAt(x, h)
        oxide = option(oxide, 0, 0, 1)
        if oxide > 0.025 then
          local i = x * 2 + 1
          local mass = 0.92 * unit((oxide - 0.025) / 0.975)^0.81
          row[i], row[i + 1] = mass, mass * option(tone, 0.58, 0, 1)
        end
      end
    end
    if y < 0 then sourceRows[h] = row end
    return row
  end

  local function fillRow(y)
    local h = y % height
    local source = readSources(y)
    local output, carried = {}, {}
    for x = 0, width - 1 do
      local i = x * 2 + 1
      local received, supplied = incoming[i] or 0, source[i] or 0
      if received > 0 or supplied > 0 then
        local ahead = allowed(x, y + 1)
        local left = width > 1 and allowed(x - 1, y + 1) and (ahead or allowed(x - 1, y))
        local right = width > 1 and allowed(x + 1, y + 1) and (ahead or allowed(x + 1, y))
        if seamless and width == 2 and left then right = false end
        local leftWeight, middleWeight, rightWeight, pooling
        if routes then
          leftWeight, middleWeight, rightWeight, pooling = routes(x, y)
          if not left then leftWeight = 0 end
          if not ahead then middleWeight = 0 end
          if not right then rightWeight = 0 end
        else
          local center = heightAt(x, y)
          local lower = ahead and heightAt(x, y + 1) or nil
          local lowerLeft = left and heightAt(x - 1, y + 1) or nil
          local lowerRight = right and heightAt(x + 1, y + 1) or nil
          middleWeight = ahead and routeWeight(center, lower, false) or 0
          leftWeight = left and routeWeight(center, lowerLeft, true, lower) or 0
          rightWeight = right and routeWeight(center, lowerRight, true, lower) or 0
          pooling = 0
          if center then
            local lip = lower and unit((lower - center) * 3.2) or 0
            local sideLeft, sideRight = heightAt(x - 1, y), heightAt(x + 1, y)
            local gutter = sideLeft and sideRight and unit((min(sideLeft, sideRight) - center) * 2.8) or 0
            pooling = unit(0.70 * lip + 0.36 * gutter)
          end
        end
        local total = middleWeight + leftWeight + rightWeight
        if total == 0 and (ahead or left or right) then pooling = max(pooling, 0.75) end
        if y >= 0 and received >= epsilon then
          local variation = 0.87 + 0.26 * grain(x, h, seed)
          local stain = strength * variation * (0.62 + 0.55 * pooling) * received / (1 + 0.52 * received)
          output[i] = unit(stain)
          output[i + 1] = unit(incoming[i + 1] / received - 0.17 * pooling)
        end

        if total > 0 then
          local keep = decay * (1 - 0.44 * pooling)
          local mass = supplied + received * keep
          local hue = (source[i + 1] or 0) + (incoming[i + 1] or 0) * keep
          add(carried, x - 1, mass * leftWeight / total, hue * leftWeight / total)
          add(carried, x, mass * middleWeight / total, hue * middleWeight / total)
          add(carried, x + 1, mass * rightWeight / total, hue * rightWeight / total)
        end
      end
    end
    if y >= 0 then
      rows[y] = output
      sourceRows[h] = nil
    end
    incoming = carried
  end

  return function(x, y)
    if not allowed(x, y) then return neutral() end
    x, y = x % width, y % height
    while nextY <= y do
      fillRow(nextY)
      nextY = nextY + 1
    end
    local i = x * 2 + 1
    return rows[y][i] or 0, rows[y][i + 1] or 0.5
  end
end

return Streaks
