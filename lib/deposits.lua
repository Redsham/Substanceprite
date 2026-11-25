local Chips = require("lib.chips")
local Texture = require("lib.texture")
local Deposits = {}

Deposits.styles = { table.unpack(Texture.styles) }
Deposits.styles[#Deposits.styles + 1] = Chips.style

local relief = {
  Noise = 0.018, Dirt = 0.085, Rust = 0.065, Dust = 0.040,
  Moss = 0.100, Scratches = -0.075, Wear = -0.042,
}

function Deposits.profile(style)
  return style == Chips.style and Chips.defaults or Texture.defaults
end

function Deposits.defaultColors(style)
  if style == Chips.style then return Chips.defaultColors() end
  return Texture.defaultColors(style)
end

function Deposits.controls(style)
  if style == Chips.style then
    return { softness = Chips.defaults.softness, runoff = Chips.defaults.runoff, trails = Chips.defaults.trails,
      label = "Corrosion", requiresHeight = false, surfaceStrength = 55 }
  end
  if Texture.isSoftDeposit(style) then
    return {
      softness = Texture.defaultSoftness(style), runoff = Texture.defaultRunoff(style),
      label = style == "Moss" and "Moisture" or "Runoff",
      requiresHeight = true,
    }
  end
end

function Deposits.generator(style)
  if style == Chips.style then return Chips.generate end
  if Texture.isSoftDeposit(style) then return Texture.generateSoftDeposit end
  return Texture.generate
end

function Deposits.sampler(style, colors)
  if style == Chips.style then return function(sample) return Chips.sample(sample, colors) end end

  local depth = relief[style] or relief.Dirt
  if Texture.isSoftDeposit(style) then
    return function(sample)
      local r, g, b, a = Texture.softDepositSample(sample, colors)
      if not r then return nil end
      local tone = ((sample >> 8) & 255) / 255
      return r, g, b, a, depth * (0.45 + 0.55 * tone) * a / 255
    end
  end
  return function(level)
    local c = colors[level]
    if not c then return nil end
    local alpha = c.a or 255
    return c.r, c.g, c.b, alpha, depth * (0.45 + 0.55 * level / 3) * alpha / 255
  end
end

return Deposits
