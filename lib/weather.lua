local Weather = {}
local min, max, floor = math.min, math.max, math.floor

local function unit(value)
  return max(0, min(1, value))
end

local function smooth(value)
  return value * value * (3 - 2 * value)
end

local function neutral()
  return 0, 0, 0, 0
end

-- Rain enters where the relief steps down, then travels toward larger sprite
-- Y. The three forward routes favor lower neighbors and lose moisture as they
-- travel. A lower lip or a channel between ridges holds more of that water.
-- Samples report wetness, passing flow, retained moisture and settled sediment.
function Weather.sampler(width, height, heights, seamless, mask, scale)
  width, height = floor(width), floor(height)
  if type(heights) ~= "table" or width < 1 or height < 1 then return neutral end

  local function heightAt(x, y)
    if seamless then
      x, y = x % width, y % height
    elseif x < 0 or y < 0 or x >= width or y >= height then
      return nil
    end
    local index = y * width + x + 1
    if mask and not mask[index] then return nil end
    local value = heights[index]
    if type(value) == "number" and value == value then return unit(value) end
  end

  local low, high, count, sum = 1, 0, 0, 0
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local value = heightAt(x, y)
      if value then
        low, high = min(low, value), max(high, value)
        count, sum = count + 1, sum + value
      end
    end
  end
  if count == 0 or high - low < 1 / 1024 then return neutral end

  local average = sum / count
  local heightGain = min(4, 1.6 / (high - low + 0.13))
  local runoffScale = tonumber(scale)
  if not runoffScale or runoffScale ~= runoffScale then runoffScale = 4 end
  local decay = 0.62 + 0.16 * unit((runoffScale - 1) / 16)
  local warmup = 0
  if seamless and height > 1 then
    -- Iterate the wrapped upstream rows until any missing initial flux is
    -- negligible. This avoids a rain shadow at the top edge of a repeated tile.
    warmup = math.ceil(math.log(1e-9) / math.log(decay))
  end

  local function drop(from, to)
    return to and unit((from - to) * heightGain) or 0
  end

  local function weight(from, to, axisWeight)
    if not to then return 0 end
    local uphill = max(0, (to - from) * heightGain)
    return axisWeight * (0.25 + 2.75 * drop(from, to)) * unit(1 - 4 * uphill)
  end

  local function deposit(nextFlow, x, value)
    if value > 0 then
      if seamless then x = x % width end
      local index = x + 1
      nextFlow[index] = (nextFlow[index] or 0) + value
    end
  end

  local pendingRow, incoming, rows = -warmup, {}, {}

  local function fillRow(y)
    local nextFlow, row = {}, {}
    for x = 0, width - 1 do
      local center = heightAt(x, y)
      if center then
        local left, right = heightAt(x - 1, y), heightAt(x + 1, y)
        local top, bottom = heightAt(x, y - 1), height > 1 and heightAt(x, y + 1) or nil
        -- A diagonal route must have an orthogonal connection. Across a
        -- transparent gap there is no wetness source or pooling neighbor.
        local lowerLeft, lowerRight
        if height > 1 and width > 1 then
          if left or bottom then lowerLeft = heightAt(x - 1, y + 1) end
          if (not seamless or width > 2) and (right or bottom) then
            lowerRight = heightAt(x + 1, y + 1)
          elseif seamless and width == 2 and not lowerLeft and (right or bottom) then
            lowerLeft = heightAt(x + 1, y + 1)
          end
        end

        local straightDrop = drop(center, bottom)
        local slope = max(straightDrop, 0.73 * drop(center, lowerLeft), 0.73 * drop(center, lowerRight))
        local sideBasin = left and right and drop(min(left, right), center) or 0
        local lowerLip = bottom and drop(bottom, center) or 0
        local pooling = unit(0.70 * lowerLip + 0.56 * sideBasin)
        local received = incoming[x + 1] or 0
        local flow = received / (0.76 + received)

        if y >= 0 then
          local sheltered = top and drop(top, center) or 0
          local exposed = unit((center - average) * heightGain)
          local wetness = flow * (0.74 + 0.53 * pooling)
                        + 0.30 * pooling + 0.10 * sheltered
                        - 0.17 * exposed - 0.08 * straightDrop
          -- A draining face can carry water and sediment without staying wet.
          -- In sheltered pockets, incoming water leaves a longer-lived film.
          local speed = slope * (1 - 0.45 * pooling)
          local film = flow * (0.16 + 0.43 * pooling) * (1 - 0.80 * speed)
          local retained = unit(0.59 * pooling + 0.13 * sheltered + film
            - 0.24 * exposed * (1 - pooling) - 0.14 * speed)
          local settled = unit(flow * (0.27 + 0.38 * (1 - 0.72 * speed)
            + 0.30 * pooling + 0.11 * sheltered))
          local index = 4 * x + 1
          row[index] = max(-1, min(1, wetness))
          row[index + 1], row[index + 2], row[index + 3] = flow, retained, settled
        end

        local middleWeight = weight(center, bottom, 1)
        local leftWeight = weight(center, lowerLeft, 0.21)
        local rightWeight = weight(center, lowerRight, 0.21)
        local totalWeight = middleWeight + leftWeight + rightWeight
        if totalWeight > 0 then
          local rain = 0.94 * smooth(unit((slope - 0.035) * 1.18))
          local carry = (rain + received * decay * (1 - 0.55 * pooling)) / totalWeight
          deposit(nextFlow, x, carry * middleWeight)
          deposit(nextFlow, x - 1, carry * leftWeight)
          deposit(nextFlow, x + 1, carry * rightWeight)
        end
      end
    end
    if y >= 0 then rows[y] = row end
    incoming = nextFlow
  end

  return function(x, y)
    if seamless then
      x, y = x % width, y % height
    elseif x < 0 or y < 0 or x >= width or y >= height then
      return neutral()
    end
    while pendingRow <= y do
      fillRow(pendingRow)
      pendingRow = pendingRow + 1
    end
    local row = rows[y]
    local index = 4 * x + 1
    return row[index] or 0, row[index + 1] or 0, row[index + 2] or 0, row[index + 3] or 0
  end
end

return Weather
