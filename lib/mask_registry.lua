local Surface = require("lib.surface")

local Masks = { styles = {} }
local entries = {}

function Masks.register(definition)
  if type(definition) ~= "table" or type(definition.name) ~= "string" or not definition.name:match("%S") then
    return nil, "A mask needs a name"
  end
  local name = definition.name
  if entries[name] then return nil, "Mask already registered: " .. name end
  if type(definition.sampler) ~= "function" then return nil, "Mask " .. name .. " needs a sampler function" end
  for _, flag in ipairs({ "requiresHeight", "direct" }) do
    if definition[flag] ~= nil and type(definition[flag]) ~= "boolean" then
      return nil, "Invalid mask setting " .. flag .. " for " .. name
    end
  end
  entries[name] = definition
  Masks.styles[#Masks.styles + 1] = name
  return true
end

function Masks.get(name)
  return entries[name]
end

function Masks.sampler(name, width, height, options, footprint, layer)
  local definition = entries[name]
  options = options or {}
  if not definition or (definition.requiresHeight and not options.heights) then return nil end
  return definition.sampler(width, height, options, footprint, layer or {})
end

local function coordinates(x, y, width, height, seamless)
  if width < 1 or height < 1 then return nil end
  if seamless then return x % width, y % height end
  if x >= 0 and x < width and y >= 0 and y < height then return x, y end
end

local function footprintSampler(width, height, seamless, footprint)
  return function(x, y)
    x, y = coordinates(x, y, width, height, seamless)
    if not x then return false end
    if not footprint then return true end
    local value
    if type(footprint) == "function" then
      value = footprint(x, y)
    else
      value = footprint[y * width + x + 1]
    end
    return value == true or (type(value) == "number" and value > 0)
  end
end

local function smooth(value)
  local t = math.max(0, math.min(1, value))
  return t * t * (3 - 2 * t)
end

local function sideSampler(width, height, options, footprint, fromTop)
  local allowed = footprintSampler(width, height, options.seamless, footprint)
  local top, bottom = {}, {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      if allowed(x, y) then
        top[x] = top[x] or y
        bottom[x] = y
      end
    end
  end
  return function(x, y)
    x, y = coordinates(x, y, width, height, options.seamless)
    if not x or not allowed(x, y) then return 0 end
    local span = bottom[x] - top[x]
    if span == 0 then return 1 end
    if options.seamless and top[x] == 0 and bottom[x] == height - 1 then
      local wave = math.sin(2 * math.pi * (y + 0.5) / height)
      return (1 + (fromTop and wave or -wave)) * 0.5
    end
    local distance = fromTop and y - top[x] or bottom[x] - y
    return 1 - smooth(distance / span)
  end
end

local directions = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function edgeSampler(width, height, options, footprint, layer)
  local allowed = footprintSampler(width, height, options.seamless, footprint)
  local edgeWidth = tonumber(layer.maskWidth) or 4
  if edgeWidth ~= edgeWidth then edgeWidth = 4 end
  edgeWidth = math.max(1, math.min(16, edgeWidth))
  local queue, distances = {}, {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      if allowed(x, y) then
        for _, offset in ipairs(directions) do
          if not allowed(x + offset[1], y + offset[2]) then
            local i = y * width + x + 1
            distances[i] = 0
            queue[#queue + 1] = i
            break
          end
        end
      end
    end
  end
  local head = 1
  while head <= #queue do
    local i = queue[head]
    head = head + 1
    local distance = distances[i] + 1
    if distance < edgeWidth then
      local x, y = (i - 1) % width, math.floor((i - 1) / width)
      for _, offset in ipairs(directions) do
        local nx, ny = coordinates(x + offset[1], y + offset[2], width, height, options.seamless)
        if nx then
          local j = ny * width + nx + 1
          if not distances[j] and allowed(nx, ny) then
            distances[j] = distance
            queue[#queue + 1] = j
          end
        end
      end
    end
  end
  return function(x, y)
    x, y = coordinates(x, y, width, height, options.seamless)
    if not x then return 0 end
    local distance = distances[y * width + x + 1]
    return distance and 1 - smooth(distance / edgeWidth) or 0
  end
end

local function paintedSampler(width, height, options, footprint, layer)
  local painted = layer.maskValues
  if not painted and options.masks then painted = options.masks[layer.maskSource or layer.id] end
  if not painted and options.layerMasks then painted = options.layerMasks[layer.maskIndex] end
  local allowed = footprintSampler(width, height, options.seamless, footprint)
  return function(x, y)
    x, y = coordinates(x, y, width, height, options.seamless)
    if not x or not allowed(x, y) then return 0 end
    if not painted then return 1 end
    local value
    if type(painted) == "function" then
      value = painted(x, y)
    elseif type(painted) == "table" then
      value = painted[y * width + x + 1]
    end
    if value == true then return 1 end
    if type(value) ~= "number" or value ~= value then return 0 end
    return math.max(0, math.min(1, value))
  end
end

assert(Masks.register { name = "Whole Surface", sampler = function() end })

for _, name in ipairs({ "Recesses", "Ridges", "Slopes" }) do
  assert(Masks.register {
    name = name, requiresHeight = true,
    sampler = function(width, height, options)
      return Surface.sampler(width, height, options.heights, options.seamless, name)
    end,
  })
end

assert(Masks.register { name = "Edges", direct = true, sampler = edgeSampler })
assert(Masks.register {
  name = "Top", direct = true,
  sampler = function(width, height, options, footprint) return sideSampler(width, height, options, footprint, true) end,
})
assert(Masks.register {
  name = "Bottom", direct = true,
  sampler = function(width, height, options, footprint) return sideSampler(width, height, options, footprint, false) end,
})
assert(Masks.register { name = "Painted Mask", direct = true, sampler = paintedSampler })

return Masks
