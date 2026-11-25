local Surface = require("lib.surface")
local Material = {}

Material.styles = { "Brushed Steel", "Aged Paint", "Oxidized Copper", "Tarnished Iron" }
Material.forms = { "Keep Lighting", "Horizontal Round", "Vertical Round", "Beveled Panel" }
Material.directions = { "Auto", "Horizontal", "Vertical" }

local profiles = {
  ["Brushed Steel"] = {
    color = { 119, 123, 125 }, undertone = { 132, 128, 115 },
    density = 74, scale = 4, intensity = 66, clustering = 63,
    broad = 2.5, stretch = 4.8, grain = 0.36, contrast = 0.22, tint = 0.19,
    placement = "Slopes",
  },
  ["Aged Paint"] = {
    color = { 75, 81, 58 }, undertone = { 94, 77, 52 },
    density = 78, scale = 5, intensity = 62, clustering = 71,
    broad = 2.65, stretch = 2.85, grain = 0.18, contrast = 0.18, tint = 0.34,
    placement = "Recesses",
  },
  ["Oxidized Copper"] = {
    color = { 159, 66, 38 }, undertone = { 106, 70, 54 },
    density = 77, scale = 5, intensity = 70, clustering = 66,
    broad = 2.7, stretch = 3.65, grain = 0.17, contrast = 0.24, tint = 0.36,
    placement = "Recesses",
  },
  ["Tarnished Iron"] = {
    color = { 57, 59, 61 }, undertone = { 87, 78, 69 },
    density = 78, scale = 4, intensity = 67, clustering = 65,
    broad = 2.25, stretch = 2.7, grain = 0.25, contrast = 0.23, tint = 0.22,
    placement = "Ridges",
  },
}

local defaultStyle = Material.styles[1]
local floor, min, max, abs = math.floor, math.min, math.max, math.abs

local function profileFor(style)
  return profiles[style] or profiles[defaultStyle]
end

function Material.preset(style)
  local profile = profileFor(style)
  return {
    density = profile.density, scale = profile.scale,
    intensity = profile.intensity, clustering = profile.clustering,
  }
end

Material.defaults = Material.preset(defaultStyle)
Material.defaults.style = defaultStyle
Material.defaults.direction = "Auto"
Material.defaults.form = "Keep Lighting"
Material.defaults.edge = 0
Material.defaults.bottom = 0
Material.defaults.seed = 1
Material.defaults.seamless = false

function Material.baseColor(style)
  return table.unpack(profileFor(style).color)
end

local function number(value, fallback, low, high)
  value = tonumber(value)
  if not value or value ~= value then return fallback end
  return min(high, max(low, value))
end

local function mix(a, b, t)
  return a + (b - a) * t
end

local function smooth(t)
  return t * t * (3 - 2 * t)
end

local function hash(x, y, seed)
  local bits = ((x * 0x85ebca6b) ~ (y * 0x9e3779b1) ~ seed) & 0xffffffff
  bits = ((bits ~ (bits >> 16)) * 0x7feb352d) & 0xffffffff
  bits = ((bits ~ (bits >> 15)) * 0x846ca68b) & 0xffffffff
  return (bits ~ (bits >> 16)) / 2147483648 - 1
end

local function axis(size, step, seamless)
  local spacing, period = step
  if size >= 6 then spacing = min(step, size * 0.62) end
  if seamless then
    period = max(1, floor(size / spacing + 0.5))
    spacing = size / period
  end
  local cache = {}
  return function(pixel)
    local sample = cache[pixel]
    if not sample then
      local position = pixel / spacing
      local first = floor(position)
      local last = first + 1
      local fraction = smooth(position - first)
      if period then first, last = first % period, last % period end
      sample = { first, last, fraction }
      cache[pixel] = sample
    end
    return sample
  end
end

-- Interpolate the material fields on integer pixel coordinates. In tile mode
-- the lattice is fitted to the dimensions first, so its phase closes at a seam.
local function field(width, height, stepX, stepY, seed, seamless)
  local alongX, alongY = axis(width, stepX, seamless), axis(height, stepY, seamless)
  local previous, row
  return function(x, y)
    local u, v = alongX(x), alongY(y)
    if v[1] ~= previous then previous, row = v[1], {} end
    local cell = row[u[1]]
    if not cell then
      cell = { hash(u[1], v[1], seed), hash(u[2], v[1], seed),
               hash(u[1], v[2], seed), hash(u[2], v[2], seed) }
      row[u[1]] = cell
    end
    return mix(mix(cell[1], cell[2], u[3]), mix(cell[3], cell[4], u[3]), v[3])
  end
end

local function makeAllowed(width, height, mask, seamless)
  return function(x, y)
    if seamless then
      x, y = x % width, y % height
    elseif x < 0 or x >= width or y < 0 or y >= height then
      return false
    end
    return not mask or mask[y * width + x + 1]
  end
end

local function makeSpans(size, crossSection, masked)
  local cache = {}
  return function(line)
    if not masked then return 0, size - 1 end
    local span = cache[line]
    if not span then
      local first, last = 0, size - 1
      while first < size and not crossSection(line, first) do first = first + 1 end
      while last > first and not crossSection(line, last) do last = last - 1 end
      span = { first, last }
      cache[line] = span
    end
    return span[1], span[2]
  end
end

local function rimDistance(x, y, dx, dy, radius, allowed)
  for distance = 1, radius do
    if not allowed(x + dx * distance, y + dy * distance) then
      return smooth(1 - (distance - 1) / radius)
    end
  end
  return 0
end

local function makeForm(form, width, height, allowed, columns, rows, seamless)
  if form == "Horizontal Round" or form == "Vertical Round" then
    local horizontal = form == "Horizontal Round"
    return function(x, y)
      local first, last
      if horizontal then first, last = columns(x) else first, last = rows(y) end
      if last <= first then return 0 end
      local across = ((horizontal and y or x) - first + 0.5) / (last - first + 1)
      if seamless then
        return 0.32 - 0.83 * math.cos(2 * math.pi * across)
      end
      local center = abs(across - 0.46) / 0.55
      local highlight = max(0, 1 - center * center) ^ 2.35
      return 1.50 * highlight - 0.66
    end
  elseif form == "Beveled Panel" then
    local radius = max(1, min(4, floor(min(width, height) * 0.11 + 0.5)))
    return function(x, y)
      local top = rimDistance(x, y, 0, -1, radius, allowed)
      local left = rimDistance(x, y, -1, 0, radius, allowed)
      local bottom = rimDistance(x, y, 0, 1, radius, allowed)
      local right = rimDistance(x, y, 1, 0, radius, allowed)
      local body = math.sin(math.pi * (x + 0.5) / width)^2 *
                   math.sin(math.pi * (y + 0.5) / height)^2
      return 0.21 * body + 0.57 * max(top, left) - 0.83 * max(bottom, right)
    end
  end
end

local function encode(value)
  return floor(128 + 127 * max(-1, min(1, value)) + 0.5)
end

-- Like the texture engine, rectangles and masks use sprite-local coordinates.
-- Zero denotes a skipped pixel. The other values hold signed detail, tarnish,
-- form light and finish amount in four bytes.
function Material.generate(width, height, options, mask, rect)
  width, height = floor(width), floor(height)
  rect = rect or { x = 0, y = 0, width = width, height = height }
  local outWidth, outHeight = floor(rect.width), floor(rect.height)
  if outWidth < 1 or outHeight < 1 then return {} end
  local result = {}
  options = options or {}
  local profile = profileFor(options.style)
  local density = number(options.density, profile.density, 0, 100) / 100
  local intensity = number(options.intensity, profile.intensity, 0, 100) / 100
  if width < 1 or height < 1 or density == 0 or intensity == 0 then
    for i = 1, outWidth * outHeight do result[i] = 0 end
    return result
  end

  local scale = number(options.scale, profile.scale, 1, 64)
  local clustering = number(options.clustering, profile.clustering, 0, 100) / 100
  local seed = floor(number(options.seed, 1, -2147483648, 4294967295))
  local edge = number(options.edge, 0, 0, 100) / 100
  local lower = number(options.bottom, 0, 0, 100) / 100
  local seamless = options.seamless == true
  local form = options.form
  local direction = options.direction
  local vertical = direction == "Vertical" or
    ((not direction or direction == "Auto") and
      (form == "Vertical Round" or (form ~= "Horizontal Round" and height > width)))
  local allowed = makeAllowed(width, height, mask, seamless)
  local columns = makeSpans(height, allowed, mask ~= nil)
  local rows = makeSpans(width, function(y, x) return allowed(x, y) end, mask ~= nil)
  local formAt = makeForm(form, width, height, allowed, columns, rows, seamless)

  local broadSize = scale * profile.broad * (0.82 + clustering * 0.42)
  local broad = field(width, height, broadSize * 1.37, broadSize, seed + 19, seamless)
  local detail = field(width, height, scale * 1.13, scale * 0.87, seed + 241, seamless)
  local streak, grainStep = scale * profile.stretch, max(1.12, scale * 0.30)
  local grain = field(width, height, vertical and grainStep or streak,
                      vertical and streak or grainStep, seed + 863, seamless)
  local oxide = field(width, height, broadSize * 1.1, broadSize * 1.31, seed + 1301, seamless)
  local grainAmount = profile.grain * (1.25 - clustering * 0.7)
  local coarseAmount = 0.43 + clustering * 0.36
  local fineAmount = 0.37 - clustering * 0.15
  local guide, strength = options.surface, 0
  local sampleSurface
  if guide and guide.heights then
    strength = number(guide.strength, 65, 0, 100) / 100
    if strength > 0 then
      local placement = guide.placement
      if not placement or placement == "Material" then placement = profile.placement end
      sampleSurface = Surface.sampler(width, height, guide.heights, seamless, placement)
    end
  end

  local outX, outY = floor(rect.x), floor(rect.y)
  local rim = max(2, min(5, floor(scale * 0.7 + 0.5)))
  local opacity = density ^ 0.68 * intensity
  local index = 1
  for row = 0, outHeight - 1 do
    local rawY = outY + row
    local y = seamless and rawY % height or rawY
    for col = 0, outWidth - 1 do
      local rawX, sample = outX + col, 0
      if allowed(rawX, rawY) then
        local x = seamless and rawX % width or rawX
        local mass, mottle = broad(x, y), detail(x, y)
        local weather = oxide(x, y) * 0.60 - mass * 0.31 + mottle * 0.17
        local relief, reliefTone = 0, 0
        if sampleSurface then relief, reliefTone = sampleSurface(x, y) end
        local dirt = 0
        if edge > 0 then
          dirt = edge * max(rimDistance(x, y, -1, 0, rim, allowed),
                           rimDistance(x, y, 1, 0, rim, allowed),
                           rimDistance(x, y, 0, -1, rim, allowed),
                           rimDistance(x, y, 0, 1, rim, allowed))
        end
        if lower > 0 then
          local top, bottom = columns(x)
          local level = (y - top + 0.5) / (bottom - top + 1)
          local bias = smooth(level)
          if seamless then bias = 0.5 - 0.5 * math.cos(2 * math.pi * (level - 0.25)) end
          dirt = min(1, dirt + 0.85 * lower * bias)
        end
        local exposure = 1 + relief * strength * 0.50
        local tone = (coarseAmount * mass + fineAmount * mottle + grainAmount * grain(x, y)) * exposure
                     + reliefTone * strength * 0.40 - dirt * 0.39
        local stain = weather * exposure + relief * strength * 0.38 + dirt * 0.45
        local formLight = formAt and formAt(x, y) or 0
        local gain = max(1, floor(opacity * 255 + 0.5))
        sample = (encode(tone) << 24) | (encode(stain) << 16) | (encode(formLight) << 8) | gain
      end
      result[index] = sample
      index = index + 1
    end
  end
  return result
end

local function byte(channel)
  return floor(min(1, max(0, channel)) * 255 + 0.5)
end

local function decode(sample, shift)
  return (((sample >> shift) & 255) - 128) / 127
end

function Material.shader(options)
  local profile = profileFor(options and options.style)
  local red, green, blue = table.unpack(profile.color)
  local dryR, dryG, dryB = table.unpack(profile.undertone)
  local colorLuma = Surface.luminance(red, green, blue)
  local dryLuma = Surface.luminance(dryR, dryG, dryB)
  local colorR, colorG, colorB = red / 255 - colorLuma, green / 255 - colorLuma, blue / 255 - colorLuma
  dryR, dryG, dryB = dryR / 255 - dryLuma, dryG / 255 - dryLuma, dryB / 255 - dryLuma

  return function(r, g, b, sample)
    if not sample or sample == 0 then return r, g, b end
    local oldLuma = Surface.luminance(r, g, b)
    local detail, stain, form = decode(sample, 24), decode(sample, 16), decode(sample, 8)
    local amount = (sample & 255) / 255
    local value = oldLuma
    if form < 0 then
      value = value * (1 + form * min(1, amount * 1.36) * 1.13)
    elseif form > 0 then
      value = value + (1 - value) * form * min(1, amount * 1.36) * 0.52
    end
    local headroom = 0.36 + 0.64 * min(1, value * 2.8, (1 - value) * 3.2)
    value = value + headroom * amount * profile.contrast * (detail - max(0, stain) * 0.14)

    local tarnish = smooth((1 + stain) * 0.5) * 0.50
    local tint = amount * profile.tint
    local saturation = min(1, max(0, (value + 0.045) * 2.45))
    -- Keep the source's value hierarchy and use luma-neutral chroma shifts.
    local sourceChroma = (1 - tint) * min(1.22, (value + 0.18) / (oldLuma + 0.18))
    return byte(value + (r / 255 - oldLuma) * sourceChroma + mix(colorR, dryR, tarnish) * tint * saturation),
           byte(value + (g / 255 - oldLuma) * sourceChroma + mix(colorG, dryG, tarnish) * tint * saturation),
           byte(value + (b / 255 - oldLuma) * sourceChroma + mix(colorB, dryB, tarnish) * tint * saturation)
  end
end

function Material.shade(r, g, b, sample, options)
  return Material.shader(options)(r, g, b, sample)
end

return Material
