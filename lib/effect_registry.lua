local Deposits = require("lib.deposits")
local Soot = require("lib.soot")

local Effects = { styles = {} }
local entries = {}
local requiredSettings = { "density", "scale", "intensity", "clustering" }

local function colorRamp(source)
  local colors = type(source) == "function" and source() or source
  if type(colors) ~= "table" or #colors == 0 then return nil end
  local copy = {}
  for index, color in ipairs(colors) do
    if type(color) ~= "table" then return nil end
    for _, channel in ipairs({ "r", "g", "b", "a" }) do
      local value = color[channel]
      if (channel ~= "a" or value ~= nil) and
          (type(value) ~= "number" or value ~= value or value < 0 or value > 255) then
        return nil
      end
    end
    copy[index] = { r = color.r, g = color.g, b = color.b, a = color.a or 255 }
  end
  return copy
end

function Effects.register(definition)
  if type(definition) ~= "table" or type(definition.name) ~= "string" or not definition.name:match("%S") then
    return nil, "An effect needs a name"
  end
  local name = definition.name
  if entries[name] then return nil, "Effect already registered: " .. name end
  if type(definition.generate) ~= "function" or type(definition.sampler) ~= "function" then
    return nil, "Effect " .. name .. " needs generate and sampler functions"
  end
  if type(definition.profile) ~= "table" then return nil, "Effect " .. name .. " needs a profile" end
  for _, key in ipairs(requiredSettings) do
    local value = definition.profile[key]
    local minimum, maximum = 0, 100
    if key == "scale" then minimum, maximum = 1, 64 end
    if type(value) ~= "number" or value ~= value or value < minimum or value > maximum then
      return nil, "Invalid profile setting " .. key .. " for effect " .. name
    end
  end
  local success, colors = pcall(colorRamp, definition.colors)
  if not success or not colors then return nil, "Effect " .. name .. " needs an RGBA color ramp" end
  local controlsType = type(definition.controls)
  if controlsType ~= "nil" and controlsType ~= "table" and controlsType ~= "function" then
    return nil, "Invalid controls for effect " .. name
  end

  entries[name] = definition
  Effects.styles[#Effects.styles + 1] = name
  return true
end

function Effects.get(name)
  return entries[name]
end

function Effects.profile(name)
  local definition = entries[name]
  return definition and definition.profile
end

function Effects.defaultColors(name)
  local definition = entries[name]
  return definition and colorRamp(definition.colors) or {}
end

function Effects.controls(name)
  local definition = entries[name]
  local controls = definition and definition.controls
  if type(controls) == "function" then return controls() end
  return controls
end

function Effects.generator(name)
  local definition = entries[name]
  return definition and definition.generate
end

function Effects.sampler(name, colors)
  local definition = entries[name]
  return definition and definition.sampler(colors or Effects.defaultColors(name))
end

local function originalGenerator(name)
  local generate = Deposits.generator(name)
  return function(width, height, options, mask, rect)
    if options and options.style == name then return generate(width, height, options, mask, rect) end
    local settings = {}
    for key, value in pairs(options or {}) do settings[key] = value end
    settings.style = name
    return generate(width, height, settings, mask, rect)
  end
end

for _, name in ipairs(Deposits.styles) do
  assert(Effects.register {
    name = name,
    profile = Deposits.profile(name),
    colors = function() return Deposits.defaultColors(name) end,
    generate = originalGenerator(name),
    sampler = function(colors) return Deposits.sampler(name, colors) end,
    controls = function() return Deposits.controls(name) end,
  })
end

assert(Effects.register {
  name = "Soot", profile = Soot.defaults, colors = Soot.colors,
  generate = Soot.generate, sampler = Soot.sampler,
})

return Effects
