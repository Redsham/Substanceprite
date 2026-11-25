local Aseprite = require("lib.aseprite")
local Composer = require("lib.composer")
local Lighting = require("lib.material_lighting")
local MaterialSample = require("lib.material_sample")
local MaterialSphere = require("lib.material_sphere")
local Normal = require("lib.normal")
local Workspace = {}
Workspace.heightChannel = "Effective Height"

local function read(target, x, y)
  return target.read(target.x + x, target.y + y)
end

local function render(target, settings, rect, layers, relief)
  local function source(x, y) return read(target, x, y) end
  local base, heights = source, settings.heights
  if settings.recipe then
    base, heights = MaterialSample.forArtwork(target.width, target.height, settings.recipe,
      settings.seed, source, target.mask, settings)
  end
  local range
  if settings.palette and (settings.paletteAmount or 0) > 0 then
    range = Composer.paletteRange(target.width, target.height, target.mask, base)
  end
  local options = {
    layers = settings.layers, heights = heights, seed = settings.seed,
    palette = settings.palette, paletteAmount = settings.paletteAmount, paletteRange = range,
    paletteName = settings.paletteName, seamless = settings.seamless,
    captureLayers = layers, captureRelief = relief, masks = settings.masks,
  }
  local pixels, details = Composer.render(target.width, target.height, options, target.mask, rect, base)
  if layers and settings.recipe then
    local stage = { name = "Base Material", pixels = {} }
    for y = 0, target.height - 1 do
      for x = 0, target.width - 1 do
        local r, g, b, a = base(x, y)
        if r and (a or 255) > 0 then stage.pixels[y * target.width + x + 1] = Composer.pack(r, g, b) end
      end
    end
    table.insert(details.stages, 1, stage)
  end
  return pixels, details
end

function Workspace.normals(target, settings, rect)
  local colors, details = render(target, settings, nil, false, true)
  local options = {
    strength = settings.normalStrength, smoothing = settings.smoothing,
    invertGreen = settings.invertGreen, seamless = settings.seamless,
  }
  return Normal.generate(target.width, target.height, details.heights, options, target.mask, rect),
    colors, details.heights
end

function Workspace.materialSample(recipe, settings)
  settings = settings or {}
  local width, height = 96, 64
  local base, heights, profile = MaterialSample.generate(width, height, recipe, settings.seed, settings)
  local options = {
    layers = settings.layers or recipe.layers,
    heights = heights,
    palette = settings.palette or recipe.palette,
    paletteAmount = settings.paletteAmount or recipe.paletteAmount,
    paletteRange = Composer.paletteRange(width, height, nil, base),
    seed = settings.seed,
    seamless = true,
    captureRelief = true,
  }
  local colors, details = Composer.render(width, height, options, nil, nil, base)
  return { width = width, height = height, colors = colors, heights = details.heights, profile = profile }
end

function Workspace.renderSphere(sample, settings, size)
  settings = settings or {}
  local pixels = MaterialSphere.render(size, sample.width, sample.height, sample.colors, sample.heights, {
    roughness = sample.profile.roughness, metalness = sample.profile.metalness,
    relief = sample.profile.relief,
    angle = settings.lightAngle, elevation = settings.lightElevation, rotation = settings.rotation,
  })
  local image = Image(size, size, ColorMode.RGB)
  for y = 0, size - 1 do
    for x = 0, size - 1 do
      local pixel = pixels[y * size + x + 1]
      if pixel ~= 0 then image:putPixel(x, y, pixel) end
    end
  end
  return image
end

function Workspace.materialSphere(recipe, settings, size)
  return Workspace.renderSphere(Workspace.materialSample(recipe, settings), settings, size)
end

function Workspace.preview(target, settings, rect, channel)
  rect = rect or { x = 0, y = 0, width = target.width, height = target.height }
  local isMap = Lighting.isMap(channel)
  local normals, colors, depths, map, shade, paint
  local shaded = channel == "Lit" or Lighting.enabled(settings)
  if channel == "Normal Map" then
    normals = Workspace.normals(target, settings, rect)
  elseif channel == Workspace.heightChannel then
    local _, details = render(target, settings, rect, false, true)
    depths = details.heights
  elseif isMap then
    local _, details = render(target, settings, nil, false, true)
    map = Lighting.map(target.width, target.height, details.heights, settings, target.mask, rect, channel)
  else
    local message
    paint, message = Aseprite.rgbPainter(target.site)
    if not paint then return nil, message end
    if shaded then
      local details
      colors, details = render(target, settings, nil, false, true)
      shade = Lighting.shader(target.width, target.height, details.heights, settings, target.mask,
        rect, channel == "Lit")
    else
      colors = render(target, settings, rect)
    end
  end
  local image = Image(rect.width, rect.height, ColorMode.RGB)
  local rgba = app.pixelColor.rgba
  for y = 0, rect.height - 1 do
    for x = 0, rect.width - 1 do
      local index = y * rect.width + x + 1
      local u, v = rect.x + x, rect.y + y
      local a = target.alphaAt(u, v)
      local r, g, b
      if normals then
        r, g, b = Normal.rgb(normals[index])
      elseif depths then
        local height = depths[index]
        if height ~= nil then
          local gray = math.floor(height * 255 + 0.5)
          r, g, b = gray, gray, gray
        end
      elseif map then
        local gray = math.floor((1 - map[index]) * 255 + 0.5)
        r, g, b = gray, gray, gray
      else
        local colorIndex = shaded and (v * target.width + u + 1) or index
        r, g, b = Composer.rgb(colors[colorIndex])
        if r then
          if shade then r, g, b = Composer.rgb(Composer.pack(shade(r, g, b, index))) end
          local _, pr, pg, pb = paint(r, g, b, a)
          r, g, b = pr, pg, pb
        end
      end
      if r and a > 0 then image:drawPixel(x, y, rgba(r, g, b, a)) end
    end
  end
  return image
end

function Workspace.layerImages(target, settings)
  local paint, message = Aseprite.rgbPainter(target.site)
  if not paint then return nil, message end
  local shaded = Lighting.enabled(settings)
  local colors, details = render(target, settings, nil, true, shaded)
  if shaded then
    local shade = Lighting.shader(target.width, target.height, details.heights, settings, target.mask)
    local pixels = {}
    for i, pixel in ipairs(colors) do
      local r, g, b = Composer.rgb(pixel)
      if r then pixels[i] = Composer.pack(shade(r, g, b, i)) end
    end
    details.stages[#details.stages + 1] = { name = "Lighting", pixels = pixels }
  end
  local images, previous = {}, nil
  for _, stage in ipairs(details.stages) do
    local image, count = Aseprite.newTextureImage(target), 0
    for y = 0, target.height - 1 do
      for x = 0, target.width - 1 do
        local i = y * target.width + x + 1
        local r, g, b = Composer.rgb(stage.pixels[i])
        if r then
          local a = target.alphaAt(x, y)
          local before
          if previous then
            local pr, pg, pb = Composer.rgb(previous[i])
            if pr then before = paint(pr, pg, pb, a) end
          else
            local pr, pg, pb = read(target, x, y)
            before = paint(pr, pg, pb, a)
          end
          local after = paint(r, g, b, a)
          if after ~= before then
            image:drawPixel(x, y, after)
            count = count + 1
          end
        end
      end
    end
    if count > 0 then images[#images + 1] = { name = stage.name, image = image } end
    previous = stage.pixels
  end
  return images
end

function Workspace.normalImage(target, settings, neutralPadding)
  local normals = Workspace.normals(target, settings)
  local source = target.site.sprite
  local image = Image(source.width, source.height, ColorMode.RGB)
  local rgba = app.pixelColor.rgba
  if neutralPadding then image:clear(rgba(128, 128, 255, 255)) end
  for y = 0, target.height - 1 do
    for x = 0, target.width - 1 do
      local r, g, b = Normal.rgb(normals[y * target.width + x + 1])
      if r then
        local alpha = neutralPadding and 255 or target.alphaAt(x, y)
        image:drawPixel(target.x + x, target.y + y, rgba(r, g, b, alpha))
      end
    end
  end
  return image
end

function Workspace.lightMapImage(target, settings, channel)
  local map = assert(Workspace.preview(target, settings, nil, channel))
  local sprite = target.site.sprite
  local image = Image(sprite.width, sprite.height, ColorMode.RGB)
  image:drawImage(map, Point(target.x, target.y))
  return image
end

function Workspace.openMapSprite(image, name)
  local sprite = Sprite(image.width, image.height, ColorMode.RGB)
  local cel = sprite.cels[1]
  cel.layer.name = name
  cel.image = image
  app.refresh()
  return sprite
end

function Workspace.openNormalSprite(image)
  return Workspace.openMapSprite(image, "Tangent-space Normal")
end

return Workspace
