local Linked = require("lib.linked_weathering")
local Surface = require("lib.surface")
local CastShadow = require("lib.cast_shadow")

local Native = {}
local namespace = "substanceprite/substanceprite"
local legacyNamespace = "pixel-art-toolkit/pixel-art-toolkit"
local version = 1
local stages = { "chips", "rust", "trails" }
local names = { chips = "Paint Chips", rust = "Rust", trails = "Rust Trails" }
local shadowRole, shadowName = "shadows", "Cast Shadows"
local recipeKeys = {
  "density", "scale", "intensity", "clustering", "softness", "runoff", "trails",
  "edge", "bottom", "seed", "seamless", "lighting", "heightMode", "heightChannel",
  "heightInvert", "placement", "surfaceStrength", "colors",
  "shadows", "shadowAngle", "shadowElevation", "shadowReach", "shadowSoftness", "shadowStrength",
}

local function properties(layer)
  local current = layer.properties(namespace)
  if current.linkedVersion or current.weatheringRole or current.weatheringLink then return current end
  local old = layer.properties(legacyNamespace)
  if old.linkedVersion or old.weatheringRole or old.weatheringLink then return old end
  return current
end

local function isLinkedGroup(layer)
  return layer.isGroup and properties(layer).linkedVersion == version
end

local function walk(layers, visit)
  for _, layer in ipairs(layers) do
    visit(layer)
    if layer.isGroup then walk(layer.layers, visit) end
  end
end

local function editableRaster(layer, sprite)
  return layer and layer.sprite == sprite and layer.isImage and not layer.isTilemap
    and not layer.isReference and not properties(layer).weatheringRole
end

local function rememberLayer(layer)
  if not layer then return "" end
  local data = properties(layer)
  local identity = data.weatheringLink
  if not identity then
    identity = tostring(layer.uuid)
    data.weatheringLink = identity
  end
  return identity
end

local function findInput(group, identity, preferBelow)
  if not identity or identity == "" then return nil end
  local sprite = group.sprite
  if preferBelow then
    local layer = group.parent.layers[group.stackIndex - 1]
    if editableRaster(layer, sprite) and properties(layer).weatheringLink == identity then
      return layer
    end
  end
  local result, count = nil, 0
  walk(sprite.layers, function(layer)
    if editableRaster(layer, sprite) and properties(layer).weatheringLink == identity then
      result, count = layer, count + 1
    end
  end)
  if count == 1 then return result end
end

function Native.list(sprite)
  local groups = {}
  walk(sprite.layers, function(layer)
    if isLinkedGroup(layer) then groups[#groups + 1] = layer end
  end)
  return groups
end

function Native.layers(group)
  if not group or not isLinkedGroup(group) then return nil end
  local data = properties(group)
  local result = {
    source = findInput(group, data.sourceLink, true),
    height = findInput(group, data.heightLink),
    outputs = {}, masks = {},
  }
  for _, layer in ipairs(group.layers) do
    local role = properties(layer).weatheringRole
    if layer.isGroup and role == "masks" then
      result.masksGroup = layer
      for _, mask in ipairs(layer.layers) do
        local maskRole = properties(mask).weatheringRole
        if maskRole == "tones" then result.tones = mask
        elseif names[maskRole] then result.masks[maskRole] = mask end
      end
    elseif not layer.isGroup and (names[role] or role == shadowRole) then
      result.outputs[role] = layer
    end
  end
  return result
end

local function settingsFrom(group, layers)
  local settings = properties(group).recipe or {}
  settings.heightLayer, settings.opacity = layers.height, {}
  for _, stage in ipairs(stages) do
    local output = layers.outputs[stage]
    if output then settings.opacity[stage] = output.opacity end
  end
  return settings
end

function Native.settings(group)
  local layers = Native.layers(group)
  if layers then return settingsFrom(group, layers) end
end

local function recipeFrom(previous, changes)
  local recipe = {}
  for _, key in ipairs(recipeKeys) do
    local value = changes[key]
    if value == nil then value = previous[key] end
    recipe[key] = value
  end
  if changes.heightLayer ~= nil and changes.heightMode == nil then
    recipe.heightMode = changes.heightLayer and "Height Map Layer" or "Flat"
  end
  recipe.heightMode = recipe.heightMode or "Flat"
  return recipe
end

local function equal(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return a == b end
  for key, value in pairs(a) do
    if not equal(value, b[key]) then return false end
  end
  for key in pairs(b) do
    if a[key] == nil then return false end
  end
  return true
end

local function transparent()
  return 0, 0, 0, 0
end

local function reader(cel)
  if not cel then return transparent end
  local image, bounds = cel.image, cel.bounds
  local bytes, stride = image.bytes, image.rowStride
  return function(x, y)
    local u, v = x - bounds.x, y - bounds.y
    if u < 0 or v < 0 or u >= bounds.width or v >= bounds.height then
      return 0, 0, 0, 0
    end
    local offset = v * stride + u * 4 + 1
    return bytes:byte(offset, offset + 3)
  end
end

local function localReader(read, area)
  if read then return function(x, y) return read(x + area.x, y + area.y) end end
end

local function engineSettings(recipe, width, height, sourceAt, heightAt, footprint)
  local options = {}
  for key, value in pairs(recipe) do options[key] = value end
  if heightAt then
    local heights, count = Surface.build(width, height, function(x, y)
      if footprint(x, y) then
        local _, _, _, a = sourceAt(x, y)
        if a > 0 then return heightAt(x, y) end
      end
    end, { channel = recipe.heightChannel, invert = recipe.heightInvert })
    if count > 0 then
      options.surface = {
        heights = heights,
        placement = recipe.placement or "Material",
        strength = recipe.surfaceStrength or 65,
      }
    end
  end
  return options
end

local function maskValues(width, height, read)
  local values = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local r, g, b, a = read(x, y)
      if a > 0 then
        local luma = (2126 * r + 7152 * g + 722 * b + 5000) // 10000
        local value = (luma * a + 127) // 255
        if value > 0 then values[y * width + x + 1] = value end
      end
    end
  end
  return values
end

local function byte(value)
  return math.floor(math.max(0, math.min(255, value)) + 0.5)
end

local function shadowPixels(width, height, recipe, options, sourceAt)
  if not recipe.shadows then return nil end
  local strength = tonumber(recipe.shadowStrength) or CastShadow.defaults.strength
  local pixels = {}
  if strength <= 0 or not options.surface then return pixels end
  local coverage = CastShadow.generate(width, height, options.surface.heights, {
    angle = recipe.shadowAngle, elevation = recipe.shadowElevation,
    reach = recipe.shadowReach, softness = recipe.shadowSoftness, seamless = recipe.seamless,
  })
  -- A translucent black layer attenuates the underlying paint and deposits
  -- together, retaining local tone even at maximum shadow strength.
  local opacity = math.min(100, strength) / 100 * CastShadow.maxDarkening
  for index, amount in ipairs(coverage) do
    if amount > 0 then
      local x, y = (index - 1) % width, (index - 1) // width
      local _, _, _, a = sourceAt(x, y)
      local alpha = byte(a * amount * opacity)
      if alpha > 0 then pixels[index] = alpha << 24 end
    end
  end
  return pixels
end

local zeroPixel = "\0\0\0\0"

local function rasterBytes(image, bounds, domain, pixels)
  local left = math.max(bounds.x, domain.x)
  local right = math.min(bounds.x + bounds.width, domain.x + domain.width)
  local top = math.max(bounds.y, domain.y)
  local bottom = math.min(bounds.y + bounds.height, domain.y + domain.height)
  local stride = image.rowStride
  if left >= right or top >= bottom then return string.rep("\0", stride * bounds.height) end
  local prefix = string.rep("\0", (left - bounds.x) * 4)
  local suffix = string.rep("\0", stride - (right - bounds.x) * 4)
  local rows = { string.rep("\0", (top - bounds.y) * stride) }
  for y = top, bottom - 1 do
    local data = {}
    local index = (y - domain.y) * domain.width + left - domain.x + 1
    for x = 1, right - left do
      local value = pixels[index + x - 1]
      data[x] = value and value ~= 0 and string.pack("<I4", value) or zeroPixel
    end
    rows[#rows + 1] = prefix .. table.concat(data) .. suffix
  end
  rows[#rows + 1] = string.rep("\0", (bounds.y + bounds.height - bottom) * stride)
  return table.concat(rows)
end

local function newImage(sprite, width, height)
  return Image(ImageSpec{
    width = width or sprite.width, height = height or sprite.height, colorMode = ColorMode.RGB,
    colorSpace = sprite.colorSpace,
  })
end

local function makeLayer(sprite, parent, name, role, image, frame, position)
  local layer = image and sprite:newLayer() or sprite:newGroup()
  layer.name = name
  layer.parent = parent
  properties(layer).weatheringRole = role
  if image then sprite:newCel(layer, frame, image, position or Point(0, 0)) end
  return layer
end

local function makeShadowLayer(sprite, group, masksGroup)
  local layer = sprite:newLayer()
  layer.name = shadowName
  layer.parent = group
  properties(layer).weatheringRole = shadowRole
  if masksGroup then layer.stackIndex = masksGroup.stackIndex end
  layer.isEditable = false
  return layer
end

local function initialOpacity(settings)
  local opacity = {}
  local amount = tonumber(settings.amount)
  local default = amount and byte(255 * amount / 100) or 255
  for _, stage in ipairs(stages) do
    local value = settings.opacity and tonumber(settings.opacity[stage])
    opacity[stage] = value and byte(value) or default
  end
  return opacity
end

local function maskImage(sprite, target, values, permit)
  local image = newImage(sprite, target.width, target.height)
  local rows = {}
  local padding = string.rep("\0", image.rowStride - image.width * 4)
  for y = 0, target.height - 1 do
    local data = {}
    for x = 1, target.width do
      local index = y * target.width + x
      local value = values[index] or 0
      data[x] = (permit[index] or 0) > 0 and string.char(value, value, value, 255) or zeroPixel
    end
    rows[y + 1] = table.concat(data) .. padding
  end
  image.bytes = table.concat(rows)
  return image
end

local function heightReader(recipe, heightLayer, frame, sourceAt)
  if recipe.heightMode == "Luminance" then return sourceAt end
  if recipe.heightMode == "Height Map Layer" and heightLayer then
    local cel = heightLayer:cel(frame)
    if cel then return reader(cel) end
  end
end

local function prepare(target, settings)
  local site = target and target.site
  local sprite, source, frame
  if site then sprite, source, frame = site.sprite, site.layer, site.frame end
  if not sprite or sprite.colorMode ~= ColorMode.RGB then
    return nil, "Linked weathering requires an RGB sprite."
  end
  if not editableRaster(source, sprite) or not frame or not source:cel(frame) then
    return nil, "Select the original paint layer with a cel in the current frame."
  end
  settings = settings or {}
  local recipe = recipeFrom({}, settings)
  local height = recipe.heightMode == "Height Map Layer" and settings.heightLayer or nil
  if recipe.heightMode == "Height Map Layer" and not editableRaster(height, sprite) then
    return nil, "Choose a raster height map layer."
  end
  local readSource = reader(source:cel(frame))
  local sourceAt = localReader(readSource, target)
  local heightAt = localReader(heightReader(recipe, height, frame, readSource), target)
  local function footprint(x, y)
    if target.alphaAt(x, y) == 0 then return false end
    local _, _, _, a = sourceAt(x, y)
    return a > 0
  end
  local width, heightPixels = target.width, target.height
  local options = engineSettings(recipe, width, heightPixels, sourceAt, heightAt, footprint)
  local values = Linked.generate(width, heightPixels, options, footprint)
  local opacity = initialOpacity(settings)
  options.opacity = opacity
  local pixels = Linked.render(width, heightPixels, options, footprint, sourceAt, values, values.tones)
  pixels.shadows = shadowPixels(width, heightPixels, recipe, options, sourceAt)
  return {
    sprite = sprite, source = source, frame = frame, height = height, recipe = recipe,
    masks = values, opacity = opacity, pixels = pixels,
  }
end

function Native.preview(target, settings)
  local prepared, message = prepare(target, settings)
  if prepared then return prepared.pixels end
  return nil, message
end

function Native.create(target, settings)
  local prepared, message = prepare(target, settings)
  if not prepared then return nil, message end
  local sprite, source, frame = prepared.sprite, prepared.source, prepared.frame
  local values = prepared.masks
  local maskImages = {}
  local outputImages = {}
  local fullCanvas = { x = 0, y = 0, width = sprite.width, height = sprite.height }
  for _, stage in ipairs(stages) do
    maskImages[stage] = maskImage(sprite, target, values[stage], values.trails)
    local image = newImage(sprite)
    image.bytes = rasterBytes(image, fullCanvas, target, prepared.pixels[stage])
    outputImages[stage] = image
  end
  local toneImage = maskImage(sprite, target, values.tones, values.trails)
  local maskPosition = Point(target.x, target.y)
  local group
  app.transaction("Create Linked Weathering", function()
    local sourceLink, heightLink = rememberLayer(source), rememberLayer(prepared.height)
    group = sprite:newGroup()
    group.name = "Linked Weathering - " .. source.name
    group.parent = source.parent
    group.stackIndex = source.stackIndex + 1
    group.properties(namespace, {
      linkedVersion = version, sourceLink = sourceLink, heightLink = heightLink, recipe = prepared.recipe,
    })
    for _, stage in ipairs(stages) do
      local layer = makeLayer(sprite, group, names[stage], stage, outputImages[stage], frame)
      layer.opacity = prepared.opacity[stage]
      layer.isEditable = false
    end
    if prepared.recipe.shadows then
      local shadow = newImage(sprite)
      if prepared.pixels.shadows then
        shadow.bytes = rasterBytes(shadow, fullCanvas, target, prepared.pixels.shadows)
      end
      local layer = makeShadowLayer(sprite, group)
      sprite:newCel(layer, frame, shadow, Point(0, 0))
    end
    local masksGroup = makeLayer(sprite, group, "Masks (white reveals)", "masks")
    masksGroup.isVisible = false
    for _, stage in ipairs(stages) do
      local mask = makeLayer(sprite, masksGroup, names[stage] .. " Mask", stage, maskImages[stage], frame,
        maskPosition)
      mask.isVisible = stage == "chips"
    end
    local tones = makeLayer(sprite, masksGroup, "Chip Tone Data", "tones", toneImage, frame, maskPosition)
    tones.isVisible = false
    tones.isEditable = false
    masksGroup.isCollapsed = true
  end)
  if app.sprite == sprite then
    app.layer = source
    app.refresh()
  end
  return group
end

local function union(first, second)
  if not first then return second end
  local x, y = math.min(first.x, second.x), math.min(first.y, second.y)
  return {
    x = x, y = y,
    width = math.max(first.x + first.width, second.x + second.width) - x,
    height = math.max(first.y + first.height, second.y + second.height) - y,
  }
end

local function workingArea(sprite, recipe, toneCel, maskCels)
  local bounds = toneCel and toneCel.bounds
  if not recipe.seamless or not bounds then
    for _, stage in ipairs(stages) do
      if maskCels[stage] then bounds = union(bounds, maskCels[stage].bounds) end
    end
  end
  if bounds then
    local x, y = math.max(bounds.x, 0), math.max(bounds.y, 0)
    local width = math.min(bounds.x + bounds.width, sprite.width) - x
    local height = math.min(bounds.y + bounds.height, sprite.height) - y
    if width > 0 and height > 0 then return { x = x, y = y, width = width, height = height } end
  end
end

local function renderFrame(sprite, recipe, layers, frame)
  local sourceCel = layers.source and layers.source:cel(frame)
  local toneCel = layers.tones and layers.tones:cel(frame)
  local outputs, maskCels, masks, enabled, opacity, pixels = {}, {}, {}, {}, {}, {}
  for _, stage in ipairs(stages) do
    local layer = layers.outputs[stage]
    local cel = layer:cel(frame)
    if not cel then return false end
    outputs[stage] = cel
    maskCels[stage] = layers.masks[stage]:cel(frame)
    enabled[stage] = layer.isVisible
    opacity[stage] = (layer.opacity * cel.opacity + 127) // 255
  end
  local shadow = layers.outputs.shadows
  outputs.shadows = shadow and shadow:cel(frame)
  local area = workingArea(sprite, recipe, toneCel, maskCels)
  if sourceCel and area then
    local width, height = area.width, area.height
    local readSource = reader(sourceCel)
    local sourceAt = localReader(readSource, area)
    local readHeight = heightReader(recipe, layers.height, frame, readSource)
    local heightAt = readHeight and localReader(readHeight, area)
    local toneAt = localReader(reader(toneCel), area)
    local tones = maskValues(width, height, toneAt)
    for _, stage in ipairs(stages) do
      masks[stage] = maskValues(width, height, localReader(reader(maskCels[stage]), area))
    end
    local function footprint(x, y)
      local _, _, _, alpha = toneAt(x, y)
      local index = y * width + x + 1
      return alpha > 0 or masks.chips[index] or masks.rust[index] or masks.trails[index]
    end
    local options = engineSettings(recipe, width, height, sourceAt, heightAt, footprint)
    options.enabled, options.opacity = enabled, opacity
    pixels = Linked.render(width, height, options, footprint, sourceAt, masks, tones)
    if outputs.shadows then pixels.shadows = shadowPixels(width, height, recipe, options, sourceAt) end
  end
  local changed = false
  for stage, cel in pairs(outputs) do
    local image, bounds = cel.image, cel.bounds
    local values = pixels[stage]
    local bytes = values and rasterBytes(image, bounds, area, values)
      or string.rep("\0", image.rowStride * image.height)
    if bytes ~= image.bytes then
      -- The cels are derived data. Updating their bytes preserves the brush and mask Undo history.
      image.bytes = bytes
      changed = true
    end
  end
  return changed
end

function Native.refresh(sprite, group)
  if sprite.colorMode ~= ColorMode.RGB then return nil, "Linked weathering requires an RGB sprite." end
  local layers = group and group.sprite == sprite and Native.layers(group)
  if not layers then return nil, "Select a linked weathering group." end
  for _, stage in ipairs(stages) do
    if not layers.outputs[stage] or not layers.masks[stage] then
      return nil, "The linked weathering group is missing a generated layer or mask."
    end
  end
  local recipe = properties(group).recipe or {}
  local changed = false
  for _, chipCel in ipairs(layers.outputs.chips.cels) do
    if renderFrame(sprite, recipe, layers, chipCel.frameNumber) then changed = true end
  end
  return changed
end

function Native.setSettings(sprite, group, changes)
  local layers = group and group.sprite == sprite and Native.layers(group)
  if not layers then return nil, "Select a linked weathering group." end
  changes = changes or {}
  local data = properties(group)
  local previous = data.recipe or {}
  local recipe = recipeFrom(previous, changes)
  local height = changes.heightLayer
  if height == nil then height = layers.height end
  if recipe.heightMode ~= "Height Map Layer" then
    height = nil
  elseif height and not editableRaster(height, sprite) then
    return nil, "Choose a raster height map layer."
  elseif not height and changes.heightMode == "Height Map Layer" then
    return nil, "Choose a raster height map layer."
  end
  local writeRecipe = not equal(previous, recipe)
  local writeHeight = recipe.heightMode ~= "Height Map Layer" and data.heightLink ~= ""
    or changes.heightLayer ~= nil and height ~= layers.height
  local opacity = {}
  for _, stage in ipairs(stages) do
    local layer = layers.outputs[stage]
    local value = changes.opacity and tonumber(changes.opacity[stage])
    if layer and value and byte(value) ~= layer.opacity then opacity[stage] = byte(value) end
  end
  local addShadow = recipe.shadows and not layers.outputs.shadows and layers.outputs.chips
  if writeRecipe or writeHeight or next(opacity) or addShadow then
    app.transaction("Adjust Linked Weathering", function()
      if writeRecipe then data.recipe = recipe end
      if writeHeight then data.heightLink = rememberLayer(height) end
      for stage, value in pairs(opacity) do layers.outputs[stage].opacity = value end
      if addShadow then
        local layer = makeShadowLayer(sprite, group, layers.masksGroup)
        for _, cel in ipairs(layers.outputs.chips.cels) do
          sprite:newCel(layer, cel.frameNumber, newImage(sprite), Point(0, 0))
        end
      end
    end)
  end
  local changed, message = Native.refresh(sprite, group)
  if changed == nil then return nil, message end
  if app.sprite == sprite then app.refresh() end
  return true
end

return Native
