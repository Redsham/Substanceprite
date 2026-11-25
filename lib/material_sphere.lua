local Sphere = {}

local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt
local pi = math.pi
Sphere.defaults = { angle = 135, roughness = 0.65, metalness = 0.12, relief = 1, rotation = 0 }

local function setting(value, default, low, high)
  value = tonumber(value)
  if not value or value ~= value then return default end
  return max(low, min(high, value))
end

local function angle(value, default)
  value = tonumber(value)
  local result = value and value % 360
  if not result or result ~= result then return default end
  return result
end

local function rgb(value)
  return (value >> 16) & 255, (value >> 8) & 255, value & 255
end

local function byte(value)
  return floor(max(0, min(255, value)) + 0.5)
end

local function meanColor(colors, count)
  local r, g, b, total = 0, 0, 0, 0
  for i = 1, count do
    local value = colors[i]
    if value and value >= 0 then
      local sr, sg, sb = rgb(value)
      r, g, b, total = r + sr, g + sg, b + sb, total + 1
    end
  end
  if total == 0 then return 128, 132, 136 end
  return r / total, g / total, b / total
end

local function sphereNormal(nx, ny, nz, east, down)
  local horizontal = sqrt(nx * nx + nz * nz)
  if horizontal < 0.0001 then return nx, ny, nz end
  local tx, tz = nz / horizontal, -nx / horizontal
  -- East follows longitude. The cross product gives the upward latitude tangent.
  local rx = nx - east * tx + down * ny * tz
  local ry = ny + down * horizontal
  local rz = nz - east * tz - down * ny * tx
  local scale = 1 / sqrt(rx * rx + ry * ry + rz * rz)
  return rx * scale, ry * scale, rz * scale
end

local function reliefAt(heights, width, height, x, y)
  local center = heights[y * width + x + 1]
  if not center then return 0, 0, 0 end
  local west = heights[y * width + (x - 1) % width + 1] or center
  local east = heights[y * width + (x + 1) % width + 1] or center
  local north = heights[max(0, y - 1) * width + x + 1] or center
  local south = heights[min(height - 1, y + 1) * width + x + 1] or center
  local cavity = max(0, (west + east + north + south) * 0.25 - center)
  return (east - west) * 0.5, (south - north) * 0.5, cavity
end

local function studio(azimuth, elevation, roughness, metalness)
  local direction = math.rad(azimuth)
  local horizontal = math.cos(math.rad(elevation))
  local lx, ly, lz = math.cos(direction) * horizontal, math.sin(direction) * horizontal, sqrt(1 - horizontal^2)
  local halfLength = sqrt(2 + 2 * lz)
  local hx, hy, hz = lx / halfLength, ly / halfLength, (lz + 1) / halfLength
  local gloss = 6 + (1 - roughness)^2 * 110
  local ambient = 0.39 - 0.09 * metalness
  local diffuse = 0.68 - 0.19 * metalness
  local shine = (1.18 - roughness) * (0.28 + 0.72 * metalness)

  return function(nx, ny, nz, viewZ, cavity, r, g, b)
    local key = max(0, nx * lx + ny * ly + nz * lz)
    local bounce = max(0, nx * 0.35 - ny * 0.74 + nz * 0.57)
    local facing = max(0, nz)
    local rim = (1 - viewZ)^2 * (0.05 + 0.10 * bounce)
    local shade = (ambient + diffuse * key + 0.13 * bounce + 0.07 * facing + rim) * cavity
    local halfDot = max(0, nx * hx + ny * hy + nz * hz)
    local keySpecular = halfDot^gloss
    local fillDot = max(0, nx * 0.49 + ny * 0.12 + nz * 0.86)
    local fillSpecular = fillDot^(gloss * 0.51) * 0.42
    local reflection = (keySpecular + fillSpecular) * shine * min(1, 2 * facing)
    local white = 56 - 25 * metalness
    local tint = 0.65 * metalness
    local red = byte(r * shade + reflection * (white + r * tint))
    local green = byte(g * shade + reflection * (white + g * tint))
    local blue = byte(b * (shade + 0.022 * bounce) + reflection * (white + b * tint + 4))
    return 0xff000000 | (blue << 16) | (green << 8) | red
  end
end

---Render a lit orthographic sphere as row-major AABBGGRR pixels.
---The source texture contains Composer RRGGBB colors and normalized heights.
---A screen-space circle keeps the sphere opaque while texture holes use the
---average material color. Texture samples stay at their original pixel pitch.
function Sphere.render(size, width, height, colors, heights, options)
  size, width, height = floor(size), floor(width), floor(height)
  if size < 1 then return {} end
  colors, options = colors or {}, options or {}
  local defaults = Sphere.defaults
  local relief = setting(options.relief, defaults.relief, 0, 2)
  local roughness = setting(options.roughness, defaults.roughness, 0.06, 1)
  local metalness = setting(options.metalness, defaults.metalness, 0, 1)
  local rotation = angle(options.rotation, defaults.rotation) / 360
  local elevation = setting(options.elevation, math.deg(math.acos(0.68)), 5, 85)
  local shade = studio(angle(options.angle, defaults.angle), elevation, roughness, metalness)
  local radius = max(0.75, size * 0.5 - 0.65)
  local result, averageR, averageG, averageB = {}
  local hasTexture = width > 0 and height > 0

  for y = 0, size - 1 do
    local ny = (size * 0.5 - y - 0.5) / radius
    for x = 0, size - 1 do
      local nx = (x + 0.5 - size * 0.5) / radius
      local distance = nx * nx + ny * ny
      local pixel = 0
      if distance <= 1 then
        local nz = sqrt(1 - distance)
        local r, g, b
        local rx, ry, rz, cavity = nx, ny, nz, 1
        if hasTexture then
          local u = (0.5 + math.atan(nx, nz) / (2 * pi) + rotation) % 1
          local v = 0.5 - math.asin(ny) / pi
          local sx, sy = floor(u * width), min(height - 1, floor(v * height))
          local value = colors[sy * width + sx + 1]
          if value and value >= 0 then r, g, b = rgb(value) end
          if heights and relief > 0 then
            local east, down, recess = reliefAt(heights, width, height, sx, sy)
            local amount = relief * 3.7
            rx, ry, rz = sphereNormal(nx, ny, nz, east * amount, down * amount)
            cavity = 1 - min(0.32, recess * amount * 0.25)
          end
        end
        if not r then
          if not averageR then averageR, averageG, averageB = meanColor(colors, width * height) end
          r, g, b = averageR, averageG, averageB
        end
        pixel = shade(rx, ry, rz, nz, cavity, r, g, b)
      end
      result[y * size + x + 1] = pixel
    end
  end
  return result
end

return Sphere
