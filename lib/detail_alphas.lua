local Alphas = { categories = { "Damage", "Grilles", "Hardware" }, default = "chip-cluster" }

local abs, floor, min, max, sqrt = math.abs, math.floor, math.min, math.max, math.sqrt
local pi, sin, cos = math.pi, math.sin, math.cos
local tau = 2 * pi
local entries, byId = {}, {}

local function unit(value)
  return min(1, max(0, value))
end

local function mix(a, b, amount)
  return a + (b - a) * amount
end

local function edge(distance)
  return unit(0.55 - distance)
end

local function hash(x, y, seed)
  local bits = ((x * 0x9e3779b1) ~ (y * 0x85ebca77) ~ seed) & 0xffffffff
  bits = ((bits ~ (bits >> 16)) * 0x7feb352d) & 0xffffffff
  bits = ((bits ~ (bits >> 15)) * 0x846ca68b) & 0xffffffff
  return (bits ~ (bits >> 16)) / 4294967296
end

local function shadowCut(distance, depth, lighting)
  local body = edge(distance + 0.13)
  local lip = edge(distance - 0.52) - body
  return max(body, 0.68 * lip), -depth * body + 0.24 * lip, -0.76 * body + lighting * lip
end

local function segments(width, height, paths, seed, wiggle)
  local result = {}
  local scale = min(width, height)
  for pathId, path in ipairs(paths) do
    local points = {}
    for i, point in ipairs(path.points) do
      local dx = (hash(i, pathId, seed) - 0.5) * wiggle * width
      local dy = (hash(i, pathId, seed + 941) - 0.5) * wiggle * height
      points[i] = { point[1] * width + dx, point[2] * height + dy, (point[3] or 1) }
    end
    for i = 1, #points - 1 do
      local a, b = points[i], points[i + 1]
      local dx, dy = b[1] - a[1], b[2] - a[2]
      result[#result + 1] = {
        x = a[1], y = a[2], dx = dx, dy = dy,
        inverse = 1 / max(dx * dx + dy * dy, 0.001),
        ra = max(0.42, scale * path.radius * a[3]), rb = max(0.42, scale * path.radius * b[3]),
      }
    end
  end
  return result
end

local function pathDistance(paths, x, y)
  local distance = math.huge
  for _, s in ipairs(paths) do
    local u, v = x - s.x, y - s.y
    local t = unit((u * s.dx + v * s.dy) * s.inverse)
    u, v = u - s.dx * t, v - s.dy * t
    distance = min(distance, sqrt(u * u + v * v) - mix(s.ra, s.rb, t))
  end
  return distance
end

local function carving(width, height, paths, seed, wiggle, depth, lighting)
  local strokes = segments(width, height, paths, seed, wiggle)
  return function(x, y)
    return shadowCut(pathDistance(strokes, x, y), depth, lighting)
  end
end

local function polygon(width, height, coordinates)
  local points = {}
  local px, py = coordinates[#coordinates][1] * width, coordinates[#coordinates][2] * height
  for _, point in ipairs(coordinates) do
    local x, y = point[1] * width, point[2] * height
    local dx, dy = x - px, y - py
    points[#points + 1] = {
      x = px, y = py, dx = dx, dy = dy,
      inverse = 1 / max(dx * dx + dy * dy, 0.001),
    }
    px, py = x, y
  end
  return points
end

local function polygonDistance(points, x, y)
  local inside, nearest = false, math.huge
  for _, p in ipairs(points) do
    local dx, dy = x - p.x, y - p.y
    local t = unit((dx * p.dx + dy * p.dy) * p.inverse)
    local u, v = dx - p.dx * t, dy - p.dy * t
    nearest = min(nearest, u * u + v * v)
    if (p.y > y) ~= (p.y + p.dy > y) and x < p.x + p.dx * dy / p.dy then inside = not inside end
  end
  return sqrt(nearest) * (inside and -1 or 1)
end

local function flake(width, height, cx, cy, rx, ry, seed)
  local outline = {}
  for i = 0, 8 do
    local angle = i * tau / 9 + 0.30 * hash(i, 1, seed)
    local radius = 0.54 + 0.47 * hash(i, 2, seed)
    outline[#outline + 1] = { cx + cos(angle) * radius * rx, cy + sin(angle) * radius * ry }
  end
  return polygon(width, height, outline)
end

local function chipCluster(width, height, seed)
  local fragments = {
    flake(width, height, 0.44, 0.54, 0.31, 0.34, seed),
    flake(width, height, 0.73, 0.64, 0.14, 0.15, seed + 41),
    flake(width, height, 0.59, 0.22, 0.11, 0.12, seed + 73),
    flake(width, height, 0.22, 0.77, 0.07, 0.08, seed + 123),
    flake(width, height, 0.79, 0.31, 0.08, 0.06, seed + 407),
  }
  return function(x, y)
    local distance = math.huge
    for _, piece in ipairs(fragments) do distance = min(distance, polygonDistance(piece, x, y)) end
    local coverage, relief, tone = shadowCut(distance, 0.33, 0.58)
    if coverage == 0 then return 0, 0, 0 end
    local oxide = hash(floor(x / 2), floor(y / 2), seed + 61) * 0.37
    return coverage, relief, tone + oxide
  end
end

local function flakedEdge(width, height, seed)
  local main = polygon(width, height, {
    {0.04, 0.14}, {0.25, 0.10}, {0.31, 0.17}, {0.41, 0.14}, {0.43, 0.27}, {0.58, 0.21},
    {0.65, 0.32}, {0.80, 0.30}, {0.95, 0.44}, {0.83, 0.53}, {0.68, 0.49}, {0.60, 0.59},
    {0.47, 0.53}, {0.38, 0.65}, {0.27, 0.54}, {0.15, 0.57}, {0.16, 0.44}, {0.05, 0.42},
  })
  local chip = flake(width, height, 0.50, 0.77, 0.13, 0.12, seed + 31)
  return function(x, y)
    local distance = min(polygonDistance(main, x, y), polygonDistance(chip, x, y))
    local coverage, relief, tone = shadowCut(distance, 0.44, 0.55)
    return coverage, relief, tone + 0.18 * coverage * hash(floor(x / 2), floor(y / 2), seed)
  end
end

local function branchingCrack(width, height, seed)
  return carving(width, height, {
    { radius = 0.047, points = {{.05,.20,.5}, {.20,.25}, {.29,.43}, {.48,.36}, {.65,.55},
      {.62,.64}, {.76,.74,.80}, {.95,.79,.24}} },
    { radius = 0.030, points = {{.28,.41}, {.24,.58}, {.36,.68,.65}, {.33,.92,.3}} },
    { radius = 0.025, points = {{.48,.36}, {.53,.20}, {.70,.11,.28}} },
    { radius = 0.023, points = {{.69,.69}, {.83,.51}, {.92,.52,.28}} },
  }, seed, 0.042, 0.82, 0.39)
end

local function hairlineCrack(width, height, seed)
  return carving(width, height, {
    { radius = 0.022, points = {{.08,.71,.44}, {.20,.60,.65}, {.31,.66}, {.39,.49}, {.54,.54},
      {.61,.37}, {.74,.43,.75}, {.84,.29,.55}, {.94,.22,.28}} },
  }, seed, 0.051, 0.56, 0.30)
end

local function scratchBundle(width, height, seed)
  local scratches = {}
  for i = 0, 3 do
    local start = 0.08 + i * 0.08 + 0.05 * hash(i, 9, seed)
    local finish = 0.68 + i * 0.07 - 0.11 * hash(i, 10, seed)
    local y = 0.60 + i * 0.10
    scratches[#scratches + 1] = {
      radius = 0.030 + 0.007 * (i % 2),
      points = {{start,y,.33}, {start+.09,y-.061,.78}, {finish-.12,y-.45}, {finish,y-.53,.29}},
    }
  end
  return carving(width, height, scratches, seed, 0.034, 0.56, 0.64)
end

local function longGouge(width, height, seed)
  return carving(width, height, {
    { radius = 0.088, points = {{.06,.66,.22}, {.21,.55,.60}, {.35,.52}, {.49,.44,1.15},
      {.65,.46}, {.79,.34,.68}, {.95,.29,.20}} },
    { radius = 0.033, points = {{.23,.64,.40}, {.39,.59,.90}, {.51,.53}, {.72,.52,.24}} },
  }, seed, 0.028, 0.87, 0.79)
end

local function impactDent(width, height, seed)
  local size = min(width, height)
  local tilt = (hash(1, 2, seed) - 0.5) * 0.53
  return function(x, y)
    local u, v = (x / width - 0.50) / 0.43, (y / height - 0.49) / 0.40
    u = u + tilt * v
    local d = sqrt(u * u + v * v)
    local bowl = unit(1 - d * d)
    local lip = unit(1 - abs(d - 0.78) * 6)
    local coverage = edge((d - 0.98) * size * 0.38) * unit(0.17 + 0.79 * bowl^1.16 + 0.39 * lip)
    return coverage, -0.90 * bowl * bowl + 0.21 * lip,
      -0.26 * bowl + (0.72 * v - 0.38 * u) * (0.59 * bowl + 0.37 * lip)
  end
end

local function puncture(width, height, seed)
  local outline = {}
  for i = 0, 15 do
    local a = i * tau / 16 + 0.15 * hash(i, 0, seed)
    local r = (i % 2 == 0 and 0.25 or 0.41) * (0.68 + 0.34 * hash(i, 1, seed))
    outline[#outline + 1] = { 0.51 + cos(a) * r, 0.49 + sin(a) * r }
  end
  local tear = polygon(width, height, outline)
  local size = min(width, height)
  local rim = min(max(0.55, size * 0.035), size * 0.16)
  return function(x, y)
    local d = polygonDistance(tear, x, y)
    local core = edge(d + rim)
    local lip = edge(d - min(0.80, size * 0.24)) - core
    local light = unit(1 - 0.65 * x / width - 0.55 * y / height)
    return max(core, lip), 0.67 * lip - 0.98 * core, (light * 1.13 - 0.26) * lip - 0.96 * core
  end
end

local function pittedCorrosion(width, height, seed)
  local pits = {}
  local size = min(width, height)
  for i = 1, 27 do
    local angle = hash(i, 2, seed) * tau
    local magnitude = hash(i, 4, seed)^0.64
    local scale = hash(i, 6, seed)
    local r = max(0.44, size * (0.016 + 0.055 * scale * scale))
    pits[i] = { x = width * (0.51 + 0.43 * magnitude * cos(angle)),
      y = height * (0.51 + 0.42 * magnitude * sin(angle)), radius = r,
      aspect = 0.64 + 0.65 * hash(i, 7, seed),
    }
  end
  return function(x, y)
    local distance = math.huge
    for _, pit in ipairs(pits) do
      local u, v = x - pit.x, (y - pit.y) * pit.aspect
      distance = min(distance, sqrt(u * u + v * v) - pit.radius)
    end
    return shadowCut(distance, 0.62, 0.64)
  end
end

local function crushedCorner(width, height, seed)
  local fold = polygon(width, height, {
    {.04,.04}, {.67,.04}, {.76,.10}, {.48,.23}, {.52,.29}, {.28,.46}, {.25,.65}, {.10,.84}, {.04,.79},
  })
  local crease = segments(width, height, {
    { radius = .041, points = {{.09,.73,.34}, {.17,.48}, {.32,.30}, {.26,.19}, {.60,.09,.30}} },
    { radius = .025, points = {{.16,.48,.75}, {.17,.27}, {.07,.13,.25}} },
  }, seed, 0.05)
  return function(x, y)
    local d = polygonDistance(fold, x, y)
    local face = edge(d)
    local groove = edge(pathDistance(crease, x, y))
    local lip = edge(d - 0.68) - face
    local level = unit(1.05 - 0.73 * (x / width + y / height))
    return max(face, groove, lip * 0.68), -0.60 * face * level - 0.33 * groove + 0.25 * lip,
      (0.38 - level) * face - 0.59 * groove + 0.62 * lip
  end
end

local function panelDistance(width, height, x, y)
  return max(abs(x - width * 0.5) - width * 0.45, abs(y - height * 0.5) - height * 0.42)
end

local function louvers(width, height, _, broken)
  local count = max(1, min(6, floor(height / 4.5)))
  local pitch = height * 0.77 / count
  local halfSlot = max(0.40, pitch * 0.31)
  return function(x, y)
    local d = panelDistance(width, height, x, y)
    if d > 0.55 then return end
    local border = edge(d + 0.10) - edge(d + 1.0)
    local u, v = x / width, y / height
    local row = (y - height * 0.115) / pitch
    local r = floor(row)
    if r < 0 or r >= count then return border, 0.22 * border, 0.37 * border end
    local offset = 0
    local gash = broken and r == count // 2 and u > 0.36 and u < 0.76
    if gash then offset = unit(1 - abs(u - 0.56) * 4) * 0.34 end
    local slot = max(abs((row - r - 0.55 - offset) * pitch) - halfSlot, (abs(u - 0.5) - 0.38) * width)
    local gap = edge(slot + 0.14)
    local lip = edge(slot - 0.58) - gap
    local bent = gash and 0.30 or 0
    return max(gap, lip * 0.67, border * 0.82), -0.78 * gap + (0.34 + bent) * lip + 0.18 * border,
      -0.84 * gap + (v < 0.5 and 0.40 or 0.58) * lip + 0.29 * border
  end
end

local function diagonalSlots(width, height)
  local paths = {}
  local count = max(2, min(6, floor(width / 8)))
  for i = 0, count - 1 do
    local x = 0.08 + 0.60 * (i + 0.5) / count
    paths[#paths + 1] = { radius = .043, points = {{x,.76}, {x+.24,.24}} }
  end
  return carving(width, height, paths, 0, 0, 0.82, 0.65)
end

local function perforations(width, height, _, style)
  local cols = max(2, min(7, floor(width / 6)))
  local rows = max(2, min(6, floor(height / 6)))
  local xStep, yStep = width * 0.84 / cols, height * 0.78 / rows
  local ratio = style == "hex" and 0.45 or 0.34
  local radius = max(0.48, min(xStep, yStep) * ratio)
  return function(x, y)
    if panelDistance(width, height, x, y) > 0.15 then return end
    local best = math.huge
    local row = floor((y - height * 0.11) / yStep)
    for gy = max(0, row - 1), min(rows - 1, row + 1) do
      local shift = style ~= "square" and (gy % 2) * 0.5 or 0
      local col = floor((x - width * 0.08) / xStep - shift)
      for gx = max(0, col - 1), min(cols - 1, col + 1) do
        local dx = abs(x - (width * 0.08 + (gx + 0.5 + shift) * xStep))
        local dy = abs(y - (height * 0.11 + (gy + 0.5) * yStep))
        local d
        if style == "square" then d = max(dx, dy)
        elseif style == "hex" then d = max(dx, 0.5 * dx + 0.8660254 * dy)
        else d = sqrt(dx * dx + dy * dy) end
        best = min(best, d)
      end
    end
    return shadowCut(best - radius, 0.88, 0.63)
  end
end

local function diamondMesh(width, height)
  local size = min(width, height)
  local frequency = max(2, min(8, floor(size / 4.7)))
  return function(x, y)
    local box = panelDistance(width, height, x, y)
    if box > 0.55 then return end
    local u, v = x / width, y / height
    local a = abs(((u + v) * frequency + 0.5) % 1 - 0.5)
    local b = abs(((u - v) * frequency + 0.5) % 1 - 0.5)
    local distance = (min(a, b) - 0.078) * size / frequency
    local bar = edge(distance)
    local crossing = edge((max(a, b) - 0.12) * size / frequency)
    local border = edge(box) - edge(box + 0.8)
    return max(bar, border * 0.75), 0.67 * bar + 0.23 * crossing + 0.10 * border,
      (a < b and 0.56 or 0.31) * bar + 0.18 * crossing + 0.27 * border
  end
end

local function radialFan(width, height)
  local scale = min(width, height) * 0.43
  return function(x, y)
    local dx, dy = (x - width * 0.5) / scale, (y - height * 0.5) / scale
    local r = sqrt(dx * dx + dy * dy)
    local ring = edge(abs(r - 0.89) * scale - max(0.55, scale * 0.085))
    local hub = edge((r - 0.22) * scale)
    local phase = (math.atan(dy, dx) / tau * 6 + r * 0.80) % 1
    local fin = edge((abs(phase - 0.5) - 0.19) * max(0.75, r * scale))
    local open = edge((r - 0.84) * scale) * (1 - hub)
    local blade, recess = fin * open, (1 - fin) * open
    return max(ring, hub, blade, 0.35 * recess), 0.68 * ring + 0.55 * hub + 0.26 * blade - 0.76 * recess,
      (0.23 - 0.31 * dx - 0.31 * dy) * ring + 0.47 * hub + 0.26 * blade - 0.77 * recess
  end
end

local function hexBolt(width, height)
  local scale = min(width, height) * 0.40
  return function(x, y)
    local dx, dy = (x - width * 0.5) / scale, (y - height * 0.5) / scale
    local ax, ay = abs(dx), abs(dy)
    local polygonEdge = max(ax, ax * 0.50 + ay * 0.8660254)
    local outer = edge((polygonEdge - 1) * scale)
    local inner = edge((polygonEdge - 0.74) * scale)
    local bevel = outer - inner
    local drill = edge((sqrt(dx * dx + dy * dy) - 0.27) * scale)
    local shine = unit(0.48 - dx * 0.42 - dy * 0.43)
    return outer, 0.55 * bevel + 0.70 * inner - 0.44 * drill,
      (shine * 1.43 - 0.48) * bevel + 0.27 * inner - 0.48 * drill
  end
end

local function countersunkScrew(width, height, seed)
  local scale = min(width, height) * 0.39
  local angle = 0.28 + hash(7, 1, seed) * 0.63
  local c, s = cos(angle), sin(angle)
  return function(x, y)
    local u, v = (x - width * 0.5) / scale, (y - height * 0.5) / scale
    local r = sqrt(u * u + v * v)
    local outer = edge((r - 1) * scale)
    local inner = edge((r - 0.76) * scale)
    local rim = outer - inner
    local a, b = u * c - v * s, u * s + v * c
    local notch = min(max(abs(a) - 0.64, abs(b) - 0.105), max(abs(b) - 0.46, abs(a) - 0.105))
    local groove = edge(notch * scale) * inner
    return outer * (1 - 0.65 * groove), 0.28 * rim + 0.52 * inner - 0.78 * groove,
      (0.24 - 0.55 * u - 0.52 * v) * rim + 0.33 * inner - 0.94 * groove
  end
end

local function rivetRow(width, height)
  local count = max(2, min(6, floor(width / 8)))
  local pitch = width * 0.87 / count
  local radius = max(0.54, min(pitch * 0.30, height * 0.31))
  return function(x, y)
    local slot = (x - width * 0.065) / pitch
    if slot < 0 or slot >= count then return end
    local dx, dy = (slot % 1 - 0.5) * pitch, y - height * 0.5
    local r = sqrt(dx * dx + dy * dy)
    local coverage = edge(r - radius)
    local dome = unit(1 - r / max(0.54, radius))
    return coverage, 0.72 * dome, (0.21 - 0.54 * (dx + dy) / radius) * coverage
  end
end

local function weldBead(width, height, seed)
  local count = max(3, min(15, floor(width / 3)))
  local thickness = max(0.55, height * 0.21)
  local key = hash(2, 9, seed) * tau
  return function(x, y)
    local u, v = x / width, y / height
    local bead = (u * count + 0.31 * sin(v * pi)) % 1
    local shimmer = 0.72 + 0.25 * cos(bead * tau)
    local center = height * (0.50 + 0.067 * sin(u * tau + key) + 0.038 * sin(u * tau * 3))
    local taper = min(unit((u - 0.07) * 13), unit((0.94 - u) * 13))
    local d = abs(y - center) - thickness * taper * shimmer
    local coverage = edge(d) * taper
    return coverage, 0.79 * coverage * shimmer,
      (0.22 + 0.50 * cos(bead * tau) - 0.55 * (y - center) / thickness) * coverage
  end
end

local function plateBody(width, height, x, y)
  local a, b = abs(x - width * 0.5), abs(y - height * 0.5)
  local corner = max(1, min(width, height) * 0.085)
  return max(a - width * 0.43, b - height * 0.39, (a + b - width * 0.43 - height * 0.39 + corner) * 0.7071)
end

local function hinge(width, height)
  local pinSize = max(0.55, width * 0.086)
  local screwSize = max(0.43, min(width, height) * 0.063)
  return function(x, y)
    local d = plateBody(width, height, x, y)
    local body = edge(d)
    local u, v = x / width, y / height
    local barrel = edge(max(abs(x - width * 0.5) - pinSize, (abs(v - 0.50) - 0.44) * height))
    local joint = min(abs(v - 0.32), abs(v - 0.68)) * height
    local cut = edge(joint - max(0.54, height * 0.027)) * barrel
    local channel = edge(abs(abs(x - width * 0.5) - pinSize - 0.64) - 0.43) * body
    local sx, sy = (abs(u - 0.5) - 0.28) * width, (abs(v - 0.5) - 0.23) * height
    local screw = edge(sqrt(sx * sx + sy * sy) - screwSize)
    local side = (1 - u) * 0.26 + (1 - v) * 0.13
    local coverage = max(body, barrel) * unit(1 - 0.78 * cut - 0.55 * channel - 0.36 * screw)
    return coverage, 0.36 * body + 0.48 * barrel - 0.61 * cut - 0.27 * channel + 0.22 * screw,
      (side + 0.40 * barrel - 0.73 * cut - 0.47 * channel - 0.28 * screw) * max(body, barrel)
  end
end

local function nameplate(width, height)
  local scale = min(width, height)
  return function(x, y)
    local bodyDepth = plateBody(width, height, x, y)
    local body = edge(bodyDepth)
    local bevel = body - edge(bodyDepth + max(0.58, scale * 0.048))
    local u, v = x / width, y / height
    local dx, dy = (abs(u - 0.5) - 0.34) * width, (abs(v - 0.5) - 0.25) * height
    local rivet = edge(sqrt(dx * dx + dy * dy) - max(0.46, scale * 0.046))
    local score = min(abs(v - 0.43), abs(v - 0.59)) * height
    local engraving = edge(max(score - 0.37, (abs(u - 0.47 - 0.07 * (v > 0.51 and 1 or 0)) - 0.23) * width))
    return body, 0.54 * body - 0.16 * bevel + 0.21 * rivet - 0.23 * engraving,
      0.26 * body + (0.78 - u - v) * bevel - 0.39 * engraving - 0.44 * rivet
  end
end

local function register(category, id, name, build, variant)
  local entry = { id = id, name = name, category = category, build = build, variant = variant }
  entries[#entries + 1], byId[id] = entry, entry
end

register("Damage", "chip-cluster", "Chipped Paint Cluster", chipCluster)
register("Damage", "flaked-edge", "Flaked Paint Edge", flakedEdge)
register("Damage", "branching-crack", "Branching Crack", branchingCrack)
register("Damage", "hairline-crack", "Hairline Crack", hairlineCrack)
register("Damage", "scratch-bundle", "Scratch Bundle", scratchBundle)
register("Damage", "long-gouge", "Long Gouge", longGouge)
register("Damage", "impact-dent", "Impact Dent", impactDent)
register("Damage", "puncture", "Torn Puncture", puncture)
register("Damage", "pitted-corrosion", "Pitted Corrosion", pittedCorrosion)
register("Damage", "crushed-corner", "Crushed Corner", crushedCorner)

register("Grilles", "horizontal-louvers", "Horizontal Louvers", louvers)
register("Grilles", "diagonal-slots", "Diagonal Slots", diagonalSlots)
register("Grilles", "round-perforation", "Round Perforation", perforations, "round")
register("Grilles", "square-perforation", "Square Perforation", perforations, "square")
register("Grilles", "hex-perforation", "Hex Perforation", perforations, "hex")
register("Grilles", "diamond-mesh", "Diamond Mesh", diamondMesh)
register("Grilles", "radial-fan", "Radial Fan", radialFan)
register("Grilles", "broken-slat", "Broken Slat", louvers, true)

register("Hardware", "hex-bolt", "Hex Bolt", hexBolt)
register("Hardware", "countersunk-screw", "Countersunk Screw", countersunkScrew)
register("Hardware", "rivet-row", "Rivet Row", rivetRow)
register("Hardware", "weld-bead", "Weld Bead", weldBead)
register("Hardware", "hinge", "Hinge", hinge)
register("Hardware", "nameplate", "Nameplate", nameplate)

local function info(entry)
  return { id = entry.id, name = entry.name, category = entry.category }
end

function Alphas.list(category)
  local found = {}
  for _, entry in ipairs(entries) do
    if category == nil or category == entry.category then found[#found + 1] = info(entry) end
  end
  return found
end

function Alphas.get(id)
  local entry = byId[id]
  return entry and info(entry)
end

-- Output is coverage, signed relief and signed tone. Bounds and unsupported
-- parts of a stamp return transparent samples with no height or color changes.
function Alphas.sampler(id, width, height, seed)
  local entry = byId[id]
  if not entry or width < 1 or height < 1 then return end
  local sample = entry.build(width, height, math.tointeger(tonumber(seed)) or 1, entry.variant)
  return function(x, y)
    if x < 0 or y < 0 or x >= width or y >= height then return 0, 0, 0 end
    local coverage, relief, tone = sample(x + 0.5, y + 0.5)
    if not coverage or coverage <= 0 then return 0, 0, 0 end
    return unit(coverage), max(-1, min(1, relief)), max(-1, min(1, tone))
  end
end

return Alphas
