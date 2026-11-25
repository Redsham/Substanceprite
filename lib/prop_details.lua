local Surface = require("lib.surface")
local Alphas = require("lib.detail_alphas")

local Details = {}
Details.kinds = { "Seam", "Fasteners", "Plate", "Stencil", "Vents", "Dent", "Abrasion", "Rail", "Frame", "Alpha Stamp" }
Details.names = { "Cargo Container", "Industrial Panel" }

local defaults = {
  Seam = { width = 78, height = 6, strength = 68, color = 0x8A8074 },
  Fasteners = { width = 70, height = 7, strength = 82, color = 0xA79E88, count = 4 },
  Plate = { width = 24, height = 23, strength = 82, color = 0xA6A58F, text = "A17" },
  Stencil = { width = 28, height = 16, strength = 82, color = 0xE5DDC4, text = "0487" },
  Vents = { width = 36, height = 44, strength = 85, color = 0x6A6961, count = 5 },
  Dent = { width = 22, height = 30, strength = 72, color = 0x796758 },
  Abrasion = { width = 25, height = 13, strength = 60, color = 0xBFAD93, count = 4 },
  Rail = { width = 82, height = 8, strength = 66, color = 0x83796A },
  Frame = { width = 96, height = 94, strength = 65, color = 0x8B8070 },
  ["Alpha Stamp"] = { width = 26, height = 32, strength = 85, color = 0xA5A095,
    alphaId = Alphas.default, reliefMode = "Auto" },
}

local presets = {
  ["Cargo Container"] = {
    { kind = "Frame", name = "Container frame", width = 100, height = 100, strength = 42 },
    { kind = "Rail", name = "Left corner post", x = 2, width = 3, height = 87, strength = 48 },
    { kind = "Rail", name = "Right corner post", x = 98, width = 3, height = 87, strength = 48 },
    { kind = "Seam", name = "Panel joint", x = 65, width = 2, height = 88, strength = 33 },
    { kind = "Dent", name = "Buckled corrugation", x = 28, y = 69, width = 17, height = 32, strength = 72 },
    { kind = "Abrasion", name = "Scraped paint", x = 32, y = 72, width = 20, height = 12, count = 3, strength = 45 },
    { kind = "Stencil", name = "Container number", x = 84, y = 27, width = 20, height = 12 },
    { kind = "Plate", name = "Cargo plate", x = 88, y = 80, width = 11, height = 13, strength = 94, text = "A7" },
  },
  ["Industrial Panel"] = {
    { kind = "Frame", name = "Panel frame" },
    { kind = "Seam", name = "Top joint", y = 22, width = 85 },
    { kind = "Fasteners", name = "Top bolts", y = 13, width = 81, count = 3 },
    { kind = "Fasteners", name = "Bottom bolts", y = 85, width = 81, count = 3 },
    { kind = "Plate", name = "Serial plate", x = 27, y = 45, width = 33, height = 24 },
    { kind = "Vents", name = "Vent grille", x = 72, y = 57, width = 33, height = 48 },
    { kind = "Stencil", name = "Equipment marking", x = 27, y = 72, width = 31, text = "H-2", strength = 70 },
  },
}

local abs, floor, ceil, min, max = math.abs, math.floor, math.ceil, math.min, math.max

local function number(value, fallback, low, high)
  value = tonumber(value)
  if not value or value ~= value then return fallback end
  return min(high, max(low, value))
end

local function round(value)
  return floor(value + 0.5)
end

local function byte(value)
  return round(number(value, 0, 0, 255))
end

local function mix(a, b, amount)
  return a + (b - a) * amount
end

local function pack(r, g, b, a)
  return byte(r) | (byte(g) << 8) | (byte(b) << 16) | (byte(a) << 24)
end

local function rgba(pixel)
  return pixel & 255, (pixel >> 8) & 255, (pixel >> 16) & 255, (pixel >> 24) & 255
end

function Details.new(kind)
  local source = defaults[kind]
  if not source then return nil end
  local entry = { kind = kind, enabled = true, x = 50, y = 50, rotation = 0 }
  for key, value in pairs(source) do entry[key] = value end
  local color = source.color
  entry.color = { r = color >> 16, g = (color >> 8) & 255, b = color & 255, a = 255 }
  return entry
end

function Details.nameOf(entry)
  if type(entry.name) == "string" and entry.name:match("%S") then return entry.name end
  if entry.kind == "Alpha Stamp" then
    local alpha = Alphas.get(entry.alphaId or Alphas.default)
    if alpha then return alpha.name end
  end
  return entry.kind or "Detail"
end

function Details.preset(name)
  local preset = presets[name]
  if not preset then return nil end
  local entries = {}
  for i, source in ipairs(preset) do
    local entry = Details.new(source.kind)
    entry.id = tostring(i)
    for key, value in pairs(source) do entry[key] = value end
    entries[i] = entry
  end
  return entries
end

local function geometry(width, height, entry, fallback)
  local w = max(1, round(width * number(entry.width, fallback.width, 1, 100) / 100))
  local h = max(1, round(height * number(entry.height, fallback.height, 1, 100) / 100))
  local cx = round(width * number(entry.x, 50, 0, 100) / 100 - w * 0.5) + w * 0.5
  local cy = round(height * number(entry.y, 50, 0, 100) / 100 - h * 0.5) + h * 0.5
  local angle = math.rad(number(entry.rotation, 0, -180, 180))
  local c, s = math.cos(angle), math.sin(angle)
  local ex, ey = (abs(c) * w + abs(s) * h) * 0.5, (abs(s) * w + abs(c) * h) * 0.5
  return {
    w = w, h = h, cx = cx, cy = cy, c = c, s = s,
    left = max(0, floor(cx - ex)), right = min(width - 1, ceil(cx + ex) - 1),
    top = max(0, floor(cy - ey)), bottom = min(height - 1, ceil(cy + ey) - 1),
  }
end

local function hash(x, y, seed)
  local bits = ((x * 0x9e3779b1) ~ (y * 0x85ebca77) ~ seed) & 0xffffffff
  bits = ((bits ~ (bits >> 16)) * 0x7feb352d) & 0xffffffff
  bits = ((bits ~ (bits >> 15)) * 0x846ca68b) & 0xffffffff
  return (bits ~ (bits >> 16)) / 4294967296
end

local function seedFor(seed, entry, index)
  local label = tostring(entry.id or index) .. entry.kind
  for i = 1, #label do seed = ((seed ~ label:byte(i)) * 16777619) & 0xffffffff end
  return seed
end

local font = {
  ["0"] = {7, 5, 5, 5, 7}, ["1"] = {2, 6, 2, 2, 7}, ["2"] = {6, 1, 7, 4, 7},
  ["3"] = {6, 1, 3, 1, 6}, ["4"] = {5, 5, 7, 1, 1}, ["5"] = {7, 4, 6, 1, 6},
  ["6"] = {3, 4, 7, 5, 7}, ["7"] = {7, 1, 2, 2, 2}, ["8"] = {7, 5, 7, 5, 7},
  ["9"] = {7, 5, 7, 1, 6}, A = {2, 5, 7, 5, 5}, B = {6, 5, 6, 5, 6},
  C = {3, 4, 4, 4, 3}, D = {6, 5, 5, 5, 6}, E = {7, 4, 6, 4, 7},
  F = {7, 4, 6, 4, 4}, G = {3, 4, 5, 5, 3}, H = {5, 5, 7, 5, 5},
  I = {7, 2, 2, 2, 7}, J = {1, 1, 1, 5, 2}, K = {5, 5, 6, 5, 5},
  L = {4, 4, 4, 4, 7}, M = {5, 7, 7, 5, 5}, N = {5, 7, 7, 7, 5},
  O = {2, 5, 5, 5, 2}, P = {6, 5, 6, 4, 4}, Q = {2, 5, 5, 3, 1},
  R = {6, 5, 6, 5, 5}, S = {3, 4, 2, 1, 6}, T = {7, 2, 2, 2, 2},
  U = {5, 5, 5, 5, 7}, V = {5, 5, 5, 5, 2}, W = {5, 5, 7, 7, 5},
  X = {5, 5, 2, 5, 5}, Y = {5, 5, 2, 2, 2}, Z = {7, 1, 2, 4, 7},
  ["-"] = {0, 0, 7, 0, 0}, ["."] = {0, 0, 0, 0, 2}, ["/"] = {1, 1, 2, 4, 4},
}

local function lettering(text, w, h, padding)
  local availableWidth, availableHeight = w - padding * 2, h - padding * 2
  if type(text) ~= "string" or text == "" or availableWidth < 3 or availableHeight < 5 then return end
  text = text:upper():gsub("[^A-Z0-9 ./%-]", " "):sub(1, min(16, (availableWidth + 1) // 4))
  local letters = {}
  for i = 1, #text do letters[i] = font[text:sub(i, i)] end
  local textWidth = #text * 4 - 1
  local scale = min(4, availableWidth // textWidth, availableHeight // 5)
  local left, top = (w - scale * textWidth) // 2, (h - scale * 5) // 2
  return function(u, v)
    local x, y = (u - left) // scale, (v - top) // scale
    if x < 0 or y < 0 or x >= textWidth or y >= 5 or x % 4 == 3 then return false end
    local glyph = letters[x // 4 + 1]
    return glyph and (glyph[y + 1] & (4 >> (x % 4))) ~= 0
  end
end

local forms = {}

forms["Alpha Stamp"] = function(w, h, entry, fallback, seed)
  local sampler = Alphas.sampler(entry.alphaId or fallback.alphaId, w, h, seed)
    or Alphas.sampler(fallback.alphaId, w, h, seed)
  local mode = entry.reliefMode or fallback.reliefMode
  return function(u, v)
    local coverage, shape, tone = sampler(u, v)
    if not coverage or coverage <= 0 then return end
    local depth = (shape or 0) * coverage * 0.20
    if mode == "Raised" then
      depth = coverage * (0.085 + 0.11 * abs(shape or 0))
    elseif mode == "Recessed" then
      depth = -coverage * (0.085 + 0.11 * abs(shape or 0))
    elseif mode == "Color Only" then
      depth = 0
    end
    return (tone or 0) * 74, coverage, depth, 0.63
  end
end

function forms.Stencil(w, h, entry, fallback, seed)
  local letteringAt = lettering(entry.text or fallback.text, w, h, 0)
  return function(u, v)
    if not letteringAt or not letteringAt(u, v) then return end
    local wear = hash(u // 2, v // 2, seed)
    local speck = hash(u, v, seed + 791)
    return 2, 0.64 + 0.23 * wear + 0.13 * speck, 0, 1
  end
end

local function alongAxis(w, h)
  if w >= h then return function(u, v) return u, v end end
  return function(u, v) return v, u end
end

function forms.Seam(w, h, _, _, seed)
  local along = alongAxis(w, h)
  local length, breadth = max(w, h), min(w, h)
  local groove = breadth // 2
  return function(u, v)
    local x, y = along(u, v)
    local weight = x == 0 or x == length - 1
    weight = weight and 0.59 or 1
    local worn = hash(x // 3, 1, seed)
    if y == groove then return -48 - 14 * worn, 0.86 * weight, -0.13, 0.10 end
    if y == groove - 1 then return 25 + 8 * worn, 0.79 * weight, 0.05, 0.16 end
    if y == groove + 1 then return -19, 0.69 * weight, -0.04, 0.12 end
  end
end

function forms.Fasteners(w, h, entry, fallback)
  local along = alongAxis(w, h)
  local length, breadth = max(w, h), min(w, h)
  local radius = min(2, (breadth - 1) // 2)
  local pitch = radius * 2 + 1
  local count = min(floor(number(entry.count, fallback.count, 1, 16)), length // pitch)
  local centers = {}
  for i = 1, count do
    local where = count == 1 and (length - 1) * 0.5 or mix(radius, length - 1 - radius, (i - 1) / (count - 1))
    centers[i] = round(where)
  end
  local centerY = (breadth - 1) // 2
  return function(u, v)
    local x, y = along(u, v)
    local dy = y - centerY
    for _, center in ipairs(centers) do
      local dx = x - center
      if dx * dx + dy * dy <= radius * radius + 0.1 then
        if radius == 0 then return 24, 0.89, 0.08, 0.66 end
        if dx == 0 and dy == 0 then return -20, 0.95, 0.095, 0.64 end
        if dx + dy < 0 then return 37, 1, 0.12, 0.69 end
        return -20, 0.88, 0.052, 0.64
      end
    end
  end
end

function forms.Abrasion(w, h, entry, fallback, seed)
  local along = alongAxis(w, h)
  local length, breadth = max(w, h), min(w, h)
  local count = min(floor(number(entry.count, fallback.count, 1, 16)), breadth, 12)
  local strips = {}
  for i = 1, count do
    local centerY = min(breadth - 1, floor((i - 0.5) * breadth / count))
    local start = floor(length * 0.28 * hash(i, 0, seed))
    local run = max(1, floor(length * (0.28 + 0.51 * hash(i, 1, seed))))
    strips[centerY] = { start = start, finish = min(length - 1, start + run), variation = hash(i, 2, seed) }
  end
  return function(u, v)
    local x, y = along(u, v)
    local strip = strips[y]
    if not strip or x < strip.start or x > strip.finish then return end
    local fromEnd = min(x - strip.start, strip.finish - x)
    local edge = min(1, 0.36 + 0.33 * fromEnd)
    local uneven = hash(x // 3, y, seed + 913)
    local weight = edge * (0.41 + 0.47 * uneven)
    return 13 + 13 * strip.variation - 9 * uneven, weight, -0.009 * weight, 0.69
  end
end

function forms.Plate(w, h, entry, fallback)
  local letteringAt = lettering(entry.text or fallback.text, w, h, 1)
  local bevel = w >= 6 and h >= 5
  return function(u, v)
    local edgeX, edgeY = min(u, w - 1 - u), min(v, h - 1 - v)
    if bevel and edgeX + edgeY == 0 then return end
    if letteringAt and letteringAt(u, v) then return -78, 0.96, 0.11, 0.82 end
    if edgeX == 1 and edgeY == 1 and w >= 10 and h >= 5 then return -52, 0.91, 0.13, 0.67 end
    if v == h - 1 or u == w - 1 then return -33, 0.89, 0.045, 0.63 end
    if v == 0 or u == 0 then return 23, 0.86, 0.14, 0.78 end
    return 3, 0.97, 0.11, 0.92
  end
end

function forms.Vents(w, h, entry, fallback)
  local inside = h - 2
  local count = min(floor(number(entry.count, fallback.count, 1, 16)), max(1, inside // 2))
  return function(u, v)
    local x, y = min(u, w - 1 - u), min(v, h - 1 - v)
    if x + y == 0 and w > 4 and h > 4 then return end
    if v == 0 or u == 0 then return 18, 0.86, 0.08, 0.38 end
    if v == h - 1 or u == w - 1 then return -19, 0.81, 0.032, 0.40 end
    local slot = (v - 1) * count % inside
    if slot < count then return 17, 0.87, 0.055, 0.43 end
    if slot < 2 * count and inside >= 3 * count then return -66, 0.98, -0.18, 0.43 end
    return -83, 0.97, -0.21, 0.43
  end
end

function forms.Rail(w, h)
  local along = alongAxis(w, h)
  local length, breadth = max(w, h), min(w, h)
  return function(u, v)
    local x, y = along(u, v)
    local endPixel = x == 0 or x == length - 1
    if y == 0 then return 21, endPixel and 0.55 or 0.89, 0.12, 0.21 end
    if y == breadth - 1 then return -32, 0.79, 0.045, 0.19 end
    if y == breadth - 2 and breadth > 4 then return -16, 0.84, 0.095, 0.22 end
    return 7, 0.85, 0.14, 0.24
  end
end

function forms.Frame(w, h)
  local border = max(1, min(4, round(min(w, h) * 0.047)))
  return function(u, v)
    local edgeX, edgeY = min(u, w - 1 - u), min(v, h - 1 - v)
    if edgeX + edgeY == 0 and min(w, h) > 5 then return end
    local edge = min(edgeX, edgeY)
    if edge > border then return end
    local lit = edgeX < edgeY and u < w / 2 or edgeX >= edgeY and v < h / 2
    if edge == 0 then return lit and 21 or -17, 0.89, 0.11, 0.17 end
    if edge == border then return -29, 0.68, 0.024, 0.075 end
    return lit and 12 or 1, 0.88, 0.107, 0.21
  end
end

function forms.Dent(w, h, _, _, seed)
  local tilt = (hash(1, 2, seed) - 0.5) * 0.32
  return function(u, v)
    local x, y = 2 * (u + 0.5) / w - 1, 2 * (v + 0.5) / h - 1
    local skew = x + tilt * y
    local radius = skew * skew + y * y
    if radius >= 1 then return end
    local bowl = 1 - radius
    local hollow = bowl * bowl
    local crease = max(0, 1 - abs(y + 0.34 * x) * 4) * bowl
    local shade = -16 * hollow + 32 * (0.35 * skew + y) * bowl - 13 * crease
    local pullX = (-0.10 * w * (1 + 0.46 * skew)) * (0.72 * bowl + 0.28 * crease)
    local pullY = 0.055 * h * (0.54 * skew - y) * bowl
    return shade, min(1, bowl * 2.1), -0.12 * hollow - 0.025 * crease, 0.14 * hollow, pullX, pullY
  end
end

local function channels(color, fallback)
  fallback = fallback.color
  color = type(color) == "table" and color or {}
  return number(color.r, fallback >> 16, 0, 255),
    number(color.g, (fallback >> 8) & 255, 0, 255),
    number(color.b, fallback & 255, 0, 255), number(color.a, 255, 0, 255) / 255
end

local function maskAllows(mask, index, x, y)
  if not mask then return true end
  local value
  if type(mask) == "function" then value = mask(x, y) else value = mask[index] end
  return value and value ~= 0
end

-- Every pass first samples a frozen image. Later details can overlap it, and
-- a dent can shift source colors and heights without feeding back into itself.
local function renderEntry(width, height, art, heights, entry, seed)
  local fallback = defaults[entry.kind]
  if not fallback or entry.enabled == false then return end
  local strength = number(entry.strength, fallback.strength, 0, 100) / 100
  if strength == 0 then return end

  local p = geometry(width, height, entry, fallback)
  local sample = forms[entry.kind](p.w, p.h, entry, fallback, seed)
  local inkR, inkG, inkB, inkAlpha = channels(entry.color, fallback)
  local pixels, relief = {}, {}
  for y = p.top, p.bottom do
    for x = p.left, p.right do
      local index = y * width + x + 1
      local pixel = art[index]
      if pixel then
        local dx, dy = x + 0.5 - p.cx, y + 0.5 - p.cy
        local u = floor(dx * p.c + dy * p.s + p.w * 0.5)
        local v = floor(-dx * p.s + dy * p.c + p.h * 0.5)
        if u >= 0 and u < p.w and v >= 0 and v < p.h then
          local shade, coverage, depth, tint, pullX, pullY = sample(u, v)
          if shade then
            local _, _, _, a = rgba(pixel)
            if pullX and coverage > 0 then
              local sx = x + round(pullX * p.c - pullY * p.s)
              local sy = y + round(pullX * p.s + pullY * p.c)
              if sx >= 0 and sx < width and sy >= 0 and sy < height then
                local at = sy * width + sx + 1
                if art[at] then
                  pixel = art[at]
                  depth = depth + (heights[at] - heights[index]) * coverage
                end
              end
            end
            local r, g, b = rgba(pixel)
            local light = 0.66 + 0.61 * Surface.luminance(r, g, b)
            local alpha = byte(a * strength * inkAlpha * coverage)
            if alpha > 0 then
              pixels[index] = pack(mix(r, inkR * light, tint) + shade,
                mix(g, inkG * light, tint) + shade, mix(b, inkB * light, tint) + shade, alpha)
            end
            if depth ~= 0 then relief[index] = number(heights[index] + strength * depth, 0, 0, 1) end
          end
        end
      end
    end
  end
  return pixels, relief
end

local function over(under, overlay)
  local r, g, b, a = rgba(under)
  local pr, pg, pb, pa = rgba(overlay)
  local weight = pa / 255
  return pack(mix(r, pr, weight), mix(g, pg, weight), mix(b, pb, weight), a)
end

-- The sparse RGBA layers use Aseprite's byte order. Heights retain the input
-- values wherever no detail has relief. Nothing is emitted outside the mask.
function Details.render(width, height, baseReader, options)
  width, height = floor(width), floor(height)
  options = options or {}
  local result = { layers = {}, heights = {} }
  local art, heights, mask = {}, result.heights, options.mask
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local i = y * width + x + 1
      if maskAllows(mask, i, x, y) then
        local r, g, b, a = baseReader(x, y)
        if r and g and b and (a == nil or a > 0) then
          art[i] = pack(r, g, b, a or 255)
          local supplied = options.heights and options.heights[i]
          heights[i] = number(supplied, Surface.luminance(r, g, b), 0, 1)
        end
      end
    end
  end

  local seed = math.tointeger(tonumber(options.seed)) or 1
  for i, entry in ipairs(options.entries or {}) do
    if defaults[entry.kind] then
      local pixels, relief = renderEntry(width, height, art, heights, entry, seedFor(seed, entry, i))
      if pixels then
        for at, z in pairs(relief) do heights[at] = z end
        if next(pixels) then
          result.layers[#result.layers + 1] = {
            id = entry.id or tostring(i), name = Details.nameOf(entry), pixels = pixels,
          }
          for at, pixel in pairs(pixels) do art[at] = over(art[at], pixel) end
        end
      end
    end
  end
  return result
end

return Details
