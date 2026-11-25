local Rain = {}
Rain.defaults = { intensity = 55, duration = 50 }

local floor, min, max = math.floor, math.min, math.max

local function unit(value)
  return max(0, min(1, value))
end

local function option(value, fallback)
  value = tonumber(value)
  if not value or value ~= value then value = fallback end
  return unit(value / 100)
end

local function neutral()
  return 0, 0, 0
end

local function noRoute()
  return 0, 0, 0, 0
end

local function allows(mask, index, x, y)
  if not mask then return true end
  local value
  if type(mask) == "function" then value = mask(x, y) else value = mask[index] end
  return value and value ~= 0
end

local function fall(from, to)
  return to and unit((from - to) * 3.4) or 0
end

local function route(from, to, forward, side)
  if to == nil then return 0 end
  local uphill = unit((to - from) * 5)
  local weight = side and (0.025 + 0.80 * fall(forward or from, to)) or 1
  return weight * (0.75 + 2.7 * fall(from, to)) * (1 - uphill)^2
end

local function contourRoute(from, to, forward, side, crest, forwardCrest)
  if to == nil then return 0 end
  local uphill = unit((to - from) * 12)
  local drop = unit((from - to) * 6)
  local bypass = max(0, (forward or from) - to, forwardCrest - crest)
  local weight = side and (0.025 + 0.95 * unit(bypass * 14)) or 1
  return weight * (0.75 + 2.7 * drop) * (1 - uphill)^2 * (1 - 0.75 * unit(crest * 12))
end

-- Rows are transported downwards. Depth affects exposure and lateral flow,
-- while the silhouette decides where drops can enter or leave the surface.
-- The 0-based sampler reports passing water, retained water and direct exposure.
-- Seamless callers may still require a physical top and bottom (wrapY = false).
-- The second sampler reports the exact outgoing fractions (left, down, right)
-- and ponding propensity, all normalized, for the next row of transport.
function Rain.sampler(width, height, heights, seamless, mask, options)
  width, height = floor(width), floor(height)
  options = options or {}
  local intensity = option(options.intensity, Rain.defaults.intensity)
  local duration = option(options.duration, Rain.defaults.duration)
  if width < 1 or height < 1 or intensity == 0 or duration == 0 then return neutral, noRoute end

  local guide = type(heights) == "table" and heights or nil
  local field = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local i = y * width + x + 1
      if allows(mask, i, x, y) then
        local value = guide and guide[i]
        field[i] = type(value) == "number" and value == value and unit(value) or 0.5
      end
    end
  end
  if not next(field) then return neutral, noRoute end

  local wrapY = seamless and options.wrapY ~= false
  local function at(x, y)
    if seamless then x = x % width end
    if wrapY then y = y % height end
    if x >= 0 and x < width and y >= 0 and y < height then return field[y * width + x + 1] end
  end

  local function crestAhead(x, y, nextHeight)
    if not nextHeight then return 0 end
    local second = at(x, y + 2)
    if not second then return 0 end
    local third = at(x, y + 3)
    return max(0, second - nextHeight, ((third or second) - nextHeight) * 0.55)
  end

  local function geometry(x, y, center)
    local left, right, bottom = at(x - 1, y), at(x + 1, y), nil
    local lowerLeft, lowerRight
    if height > 1 then
      bottom = at(x, y + 1)
      -- Ignore corner-only links across empty pixels. In a two-column
      -- repeat, both diagonals reach the same destination.
      if width > 1 and (bottom or left) then lowerLeft = at(x - 1, y + 1) end
      if width > 1 and (bottom or right) and (not seamless or width > 2 or not lowerLeft) then
        lowerRight = at(x + 1, y + 1)
      end
    end
    local middleWeight, leftWeight, rightWeight, lip, channel
    if options.contour then
      -- Steer around a shallow rise before the water reaches its face.
      local ahead = crestAhead(x, y, bottom)
      middleWeight = contourRoute(center, bottom, bottom, false, ahead, ahead)
      leftWeight = contourRoute(center, lowerLeft, bottom, true, crestAhead(x - 1, y, lowerLeft), ahead)
      rightWeight = contourRoute(center, lowerRight, bottom, true, crestAhead(x + 1, y, lowerRight), ahead)
      lip = unit(((bottom or center) - center) * 10)
      channel = left and right and unit((min(left, right) - center) * 7) or 0
    else
      middleWeight = route(center, bottom, bottom, false)
      leftWeight = route(center, lowerLeft, bottom, true)
      rightWeight = route(center, lowerRight, bottom, true)
      lip = fall(bottom or center, center)
      channel = left and right and fall(min(left, right), center) or 0
    end
    local total = middleWeight + leftWeight + rightWeight
    local pool = unit(0.73 * lip + 0.60 * channel)
    if total == 0 and (bottom or lowerLeft or lowerRight) then pool = max(pool, 0.80) end
    local speed = max(fall(center, bottom), fall(center, lowerLeft), fall(center, lowerRight))
    return leftWeight, middleWeight, rightWeight, pool, total, speed
  end

  -- A storm's duration increases both deposited water and how far a film
  -- can connect. Incoming water never amplifies without direct rain.
  local elapsed = duration ^ 0.72
  local rain = intensity ^ 0.86 * (0.18 + 0.82 * elapsed)
  local carry = 0.60 + 0.29 * elapsed
  local warmup = wrapY and height > 1 and math.ceil(math.log(1e-6) / math.log(carry)) or 0
  local incoming, horizon, rows = {}, {}, {}
  local nextY = -warmup

  local function deposit(downstream, x, flux, weight)
    if weight > 0 then
      local index = (x % width) + 1
      downstream[index] = (downstream[index] or 0) + flux * weight
    end
  end

  local function traceRow(y)
    local downstream, row = {}, {}
    for x = 0, width - 1 do
      local i = x + 1
      local center = at(x, y)
      if center then
        local upstream = horizon[i]
        local above = at(x, y - 1)
        local lipShadow = upstream and unit((upstream - center - 0.018) * 3.6) or 0
        lipShadow = lipShadow^2 * (3 - 2 * lipShadow)
        local exposure = (above and (0.15 + 0.78 * fall(center, above)) or 1) * (1 - lipShadow)
        horizon[i] = max(center, upstream or 0) - 0.066

        local leftWeight, middleWeight, rightWeight, pool, total, speed = geometry(x, y, center)

        local water = (incoming[i] or 0) + exposure * rain
        if total > 0 then
          local flux = water * carry * (1 - 0.34 * pool) / total
          deposit(downstream, x, flux, middleWeight)
          deposit(downstream, x - 1, flux, leftWeight)
          deposit(downstream, x + 1, flux, rightWeight)
        end
        if y >= 0 and water > 0 then
          local flow = water / (0.59 + water)
          local retained = unit(flow * (0.14 + 0.60 * pool) * (1 - 0.64 * speed) * (0.38 + 0.62 * elapsed))
          local out = 3 * x + 1
          row[out], row[out + 1], row[out + 2] = flow, retained, exposure
        end
      else
        horizon[i] = nil
      end
    end
    incoming = downstream
    if y >= 0 then rows[y] = row end
  end

  local function waterAt(x, y)
    if seamless then x = x % width end
    if wrapY then y = y % height end
    if x < 0 or x >= width or y < 0 or y >= height then return neutral() end
    while nextY <= y do
      traceRow(nextY)
      nextY = nextY + 1
    end
    local row, i = rows[y], 3 * x + 1
    return row[i] or 0, row[i + 1] or 0, row[i + 2] or 0
  end

  local function routeAt(x, y)
    local center = at(x, y)
    if not center then return noRoute() end
    local left, middle, right, pool, total = geometry(x, y, center)
    if total <= 0 then return 0, 0, 0, pool end
    return left / total, middle / total, right / total, pool
  end

  return waterAt, routeAt
end

return Rain
