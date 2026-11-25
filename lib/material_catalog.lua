local Catalog = {}

local function ramp(...)
  local colors = { ... }
  for index, pixel in ipairs(colors) do
    colors[index] = { r = (pixel >> 16) & 255, g = (pixel >> 8) & 255, b = pixel & 255 }
  end
  return colors
end

local function deposit(style, amount, placement, scale)
  return {
    kind = "Deposits", style = style, amount = amount, mask = placement,
    density = 29, scale = scale, intensity = 54, clustering = 65,
  }
end

local recipes = {
  {
    id = "bark", name = "Bark", palette = ramp(0x251D19, 0x493226, 0x735440, 0x997755, 0xC0A077),
    roughness = 0.91, metalness = 0, relief = 0.85,
    layers = { deposit("Moss", 18, "Recesses", 4) },
  },
  {
    id = "wood-planks", name = "Wood Planks", palette = ramp(0x2B251F, 0x483B2E, 0x665541, 0x907B60, 0xB9A17D),
    roughness = 0.76, metalness = 0, relief = 0.54,
    layers = { deposit("Dirt", 16, "Recesses", 3) },
  },
  {
    id = "metal", name = "Metal", palette = ramp(0x282927, 0x424441, 0x595B58, 0x878A85, 0xC4C6BE),
    roughness = 0.50, metalness = 0.94, relief = 0.49,
    layers = { deposit("Wear", 14, "Ridges", 3) },
  },
  {
    id = "painted-metal", name = "Painted Metal", palette = ramp(0x172826, 0x2D4A45, 0x4B7164, 0x719789, 0xACC0A4),
    roughness = 0.51, metalness = 0.10, relief = 0.56,
    layers = { deposit("Paint Chips", 27, "Whole Surface", 3), deposit("Dirt", 12, "Recesses", 5) },
  },
  {
    id = "plastic", name = "Plastic", palette = ramp(0x261E32, 0x4E385D, 0x795775, 0xA47F94, 0xD2ACB7),
    roughness = 0.39, metalness = 0, relief = 0.30,
    layers = { deposit("Dust", 12, "Whole Surface", 2) },
  },
  {
    id = "stone", name = "Stone", palette = ramp(0x272A31, 0x4C515A, 0x737A80, 0xA1A39B, 0xCCC9BA),
    roughness = 0.83, metalness = 0, relief = 0.96,
    layers = { deposit("Moss", 12, "Recesses", 4) },
  },
  {
    id = "concrete", name = "Concrete", palette = ramp(0x45423D, 0x6D6961, 0x928E85, 0xB4B0A4, 0xD9D5C9),
    roughness = 0.94, metalness = 0, relief = 0.39,
    layers = { deposit("Dust", 13, "Whole Surface", 3) },
  },
}

local byName = {}
Catalog.names = {}
for _, recipe in ipairs(recipes) do
  Catalog.names[#Catalog.names + 1] = recipe.name
  byName[recipe.id], byName[recipe.name] = recipe, recipe
  recipe.paletteAmount = 100
end

local aliases = {
  Steel = "metal", Wood = "wood-planks", ["Cast Iron"] = "metal",
  ["Olive Paint"] = "painted-metal", ["Burnt Orange"] = "painted-metal",
}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, entry in pairs(value) do out[key] = copy(entry) end
  return out
end

function Catalog.recipe(nameOrId)
  return copy(byName[nameOrId] or byName[aliases[nameOrId]])
end

Catalog.recipeById = Catalog.recipe

return Catalog
