-- Optional example enabled in generators/user.lua.
return function(Effects, Masks)
  assert(Masks.register {
    name = "Example Upper Third",
    direct = true,
    sampler = function(_, height)
      return function(_, y)
        return math.max(0, 1 - y / math.max(1, height / 3))
      end
    end,
  })

  assert(Effects.register {
    name = "Example Flecks",
    profile = { density = 28, scale = 2, intensity = 52, clustering = 45 },
    colors = {
      { r = 63, g = 48, b = 37 },
      { r = 128, g = 101, b = 76 },
      { r = 194, g = 161, b = 113 },
    },
    generate = function(width, height, settings, footprint, rect)
      local options = { style = "Dust" }
      for key, value in pairs(settings) do
        if key ~= "style" then options[key] = value end
      end
      return Effects.generator("Dust")(width, height, options, footprint, rect)
    end,
    sampler = function(colors) return Effects.sampler("Dust", colors) end,
  })
end
