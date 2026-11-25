local Paint = require("lib.paint_stack")
local Colors = require("lib.paint_colors")
local Surface = require("lib.surface")

local Native = {}
local namespace = "substanceprite/substanceprite"
local legacyNamespace = "pixel-art-toolkit/pixel-art-toolkit"
local stages = {"undercoat", "metal", "paint", "primer", "fading", "scuff", "rust", "trails", "dirt", "moss", "soot"}
local mapKeys = {metal = "metalMap", height = "heightMap", bevel = "bevelMask", rust = "rustMask",
  trails = "trailsMask", dirt = "dirtMask", moss = "mossMask",
  scuff = "scuffMask", fading = "fadingMask", primer = "primerMask", soot = "sootMask"}
local mapOrder = {"metalMap", "heightMap", "rustMask", "trailsMask", "dirtMask", "mossMask", "metalBaseline", "scope"}
local maskedEffects = {"rust", "trails", "dirt", "moss", "scuff", "fading", "primer", "soot", "bevel"}
local names = {
  undercoat = "Clean Metal", metal = "Exposed Metal Tint", paint = "Paint",
  primer = "Primer at Exposed Edges", fading = "Faded Paint", scuff = "Scuffs",
  rust = "Rust on Metal", trails = "Rust Trails",
  dirt = "Dirt", moss = "Moss", soot = "Soot", mapsGroup = "Maps & Masks",
  metalMap = "Metal Map", heightMap = "Height Map", bevelMask = "Bevel Wear Mask", rustMask = "Rust Mask",
  trailsMask = "Rust Trails Mask", dirtMask = "Dirt Mask", mossMask = "Moss Mask",
  scuffMask = "Scuffs Mask", fadingMask = "Fading Mask", primerMask = "Primer Mask", sootMask = "Soot Mask",
  metalBaseline = "Procedural Metal (reference)", scope = "Target Area (reference)",
}

local function info(layer)
  local current = layer.properties(namespace)
  if current.paintVersion or current.paintRole or current.paintSource then return current end
  local legacy = layer.properties(legacyNamespace)
  if legacy.paintVersion or legacy.paintRole or legacy.paintSource then return legacy end
  return current
end

local function isPainted(layer)
  return layer and layer.isGroup and info(layer).paintVersion == 1
end

local function isOldRust(layer)
  return layer and not layer.isGroup and (layer.name == "Texture - Rust" or layer.name == "Rust")
end

local function isHiddenGuide(layer)
  return layer and not layer.isVisible and layer.name:match("^Height Map")
end

local function isBaked(layer)
  if not layer or not layer.isGroup then return false end
  local properties = layer.properties(namespace)
  if properties.materialVersion or properties.materialBake then return true end
  for _, child in ipairs(layer.layers) do
    if child.isImage and child.name:match("^Palette %- ") then return true end
  end
  return false
end

local function isRaster(layer)
  return layer and layer.isImage and not layer.isTilemap and not layer.isReference
end

local function walk(layers, visit)
  for _, layer in ipairs(layers) do
    visit(layer)
    if layer.isGroup then walk(layer.layers, visit) end
  end
end

function Native.list(sprite)
  local groups = {}
  walk(sprite.layers, function(layer)
    if isPainted(layer) then groups[#groups + 1] = layer end
  end)
  return groups
end

function Native.layers(group)
  if not isPainted(group) then return nil end
  local result = {}
  walk(group.layers, function(layer)
    local role = info(layer).paintRole
    if role then result[role] = layer end
  end)
  result.chipMask = result.metalMap
  result.outputs = {}
  for _, stage in ipairs(stages) do result.outputs[stage] = result[stage] end
  return result
end

local function makeImage(sprite, width, height)
  return Image(ImageSpec{
    width = width or sprite.width, height = height or sprite.height,
    colorMode = ColorMode.RGB, colorSpace = sprite.colorSpace,
  })
end

local function reader(image, left, top)
  if not image then return function() return 0, 0, 0, 0 end end
  local bytes, stride = image.bytes, image.rowStride
  local width, height = image.width, image.height
  left, top = left or 0, top or 0
  return function(x, y)
    x, y = x - left, y - top
    if x < 0 or y < 0 or x >= width or y >= height then return 0, 0, 0, 0 end
    local offset = y * stride + x * 4 + 1
    return bytes:byte(offset, offset + 3)
  end
end

local function readCel(cel)
  if not cel then return reader(nil) end
  return reader(cel.image, cel.position.x, cel.position.y)
end

local function byte(value)
  return math.floor(math.max(0, math.min(255, value)) + 0.5)
end

local function imageFrom(sprite, width, height, pixels)
  local image = makeImage(sprite, width, height)
  local rows, padding = {}, string.rep("\0", image.rowStride - width * 4)
  for y = 0, height - 1 do
    local row = {}
    for x = 1, width do row[x] = string.pack("<I4", pixels[y * width + x] or 0) end
    rows[y + 1] = table.concat(row) .. padding
  end
  image.bytes = table.concat(rows)
  return image
end

local function inputLayer(group)
  local link = info(group).paintInput
  if not link then return nil end
  local siblings = group.parent.layers
  for i = group.stackIndex - 1, 1, -1 do
    local layer = siblings[i]
    if info(layer).paintSource == link then return layer end
    if not isOldRust(layer) and not isHiddenGuide(layer) then break end
  end
  local found, count = nil, 0
  walk(group.sprite.layers, function(layer)
    if info(layer).paintSource == link then found, count = layer, count + 1 end
  end)
  if count == 1 then return found end
end

local function sourceLayer(layer)
  local node = layer
  local sprite = layer.sprite
  while node and node ~= sprite do
    if isBaked(node) then return node end
    node = node.parent
  end
  local siblings = layer.parent.layers
  local index = layer.stackIndex
  while isOldRust(siblings[index]) or isHiddenGuide(siblings[index]) do index = index - 1 end
  if not siblings[index] then return nil end
  if isBaked(siblings[index + 1]) then return siblings[index + 1] end
  return siblings[index]
end

local function sourceParts(source)
  local parts, top = {}, source
  local siblings = source.parent.layers
  local first = source.stackIndex
  if not source.properties(namespace).materialVersion or #source.sprite.frames > 1 then
    while isBaked(siblings[first]) do first = first - 1 end
    while isOldRust(siblings[first]) or isHiddenGuide(siblings[first]) do first = first - 1 end
  end
  if first == 0 or (siblings[first].isGroup and not isBaked(siblings[first])) then
    first = source.stackIndex
  end
  local last = source.stackIndex
  local nextIndex = last + 1
  while isOldRust(siblings[nextIndex]) or isHiddenGuide(siblings[nextIndex]) do
    if isOldRust(siblings[nextIndex]) then last = nextIndex end
    nextIndex = nextIndex + 1
  end
  for i = first, last do parts[#parts + 1] = siblings[i] end
  top = siblings[last] or top
  return parts, top
end

local function sourceImages(sprite, source, frame)
  local clean, original, rust = makeImage(sprite), makeImage(sprite), makeImage(sprite)
  local function draw(layer, inheritedRust, readResult)
    if (not layer.isVisible and not readResult) or isPainted(layer) then return end
    local oxidized = inheritedRust or isOldRust(layer)
    if layer.isGroup then
      local isMaterial = layer.properties(namespace).materialVersion ~= nil
      for _, child in ipairs(layer.layers) do
        if not isMaterial or child.properties(namespace).materialRole == "result" then
          draw(child, oxidized, isMaterial)
        end
      end
    elseif isRaster(layer) then
      local cel = layer:cel(frame)
      if not cel then return end
      local opacity = ((layer.opacity or 255) * cel.opacity + 127) // 255
      original:drawImage(cel.image, cel.position, opacity, layer.blendMode)
      if oxidized then
        rust:drawImage(cel.image, cel.position, opacity, layer.blendMode)
      else
        clean:drawImage(cel.image, cel.position, opacity, layer.blendMode)
      end
    end
  end
  local parts, top = sourceParts(source)
  for _, layer in ipairs(parts) do draw(layer) end
  return clean, original, rust, top
end

local function trim(read, area, allowed)
  local left, top = area.x + area.width, area.y + area.height
  local right, bottom = area.x - 1, area.y - 1
  for y = area.y, area.y + area.height - 1 do
    for x = area.x, area.x + area.width - 1 do
      local _, _, _, alpha = read(x, y)
      if alpha > 0 and allowed(x, y) then
        left, top = math.min(left, x), math.min(top, y)
        right, bottom = math.max(right, x), math.max(bottom, y)
      end
    end
  end
  if right < left or bottom < top then return nil end
  return Rectangle(left, top, right - left + 1, bottom - top + 1)
end

local function makeTarget(site, area, allowed, read)
  local permit, mask, alpha, count = {}, {}, {}, 0
  for y = 0, area.height - 1 do
    for x = 0, area.width - 1 do
      local index = y * area.width + x + 1
      local permits = allowed(x + area.x, y + area.y)
      permit[index] = permits and 255 or 0
      local _, _, _, a = read(x + area.x, y + area.y)
      alpha[index] = permits and a or 0
      if alpha[index] > 0 then mask[index], count = true, count + 1 end
    end
  end
  return {site = site, x = area.x, y = area.y, width = area.width, height = area.height,
    focusX = area.width // 2, focusY = area.height // 2, permit = permit, read = read,
    mask = count < area.width * area.height and mask or nil,
    alphaAt = function(x, y) return alpha[y * area.width + x + 1] or 0 end}
end

local function mergedRecipe(previous, settings)
  local recipe = {}
  for key, default in pairs(Paint.defaults) do
    local value = settings[key]
    if value == nil then value = previous[key] end
    -- Older recipes keep their original runoff until rain is configured.
    if value == nil and key ~= "rainStrength" and key ~= "rainDuration" then value = default end
    recipe[key] = value
  end
  local color = recipe.color
  if type(color) == "userdata" then
    color = {r = color.red, g = color.green, b = color.blue, a = color.alpha}
  end
  recipe.color = {r = color.r, g = color.g, b = color.b, a = color.a or 255}
  recipe.palette = Colors.normalize(recipe.palette)
  return recipe
end

local function findGroup(source, frame)
  local link = info(source).paintSource
  if not link then return nil end
  for _, sibling in ipairs(source.parent.layers) do
    if isPainted(sibling) and info(sibling).paintInput == link then
      local layers = Native.layers(sibling)
      if layers.metalMap and layers.metalMap:cel(frame) then return sibling end
    end
  end
end

local function contextFrom(sprite, source, frame, group, useSelection)
  local layers = group and Native.layers(group)
  if layers and (not layers.scope or not layers.metalMap or not layers.heightMap) then
    return nil, "This painted material is missing its maps."
  end
  if layers and not layers.metalMap:cel(frame) and layers.metalMap.cels[1] then
    frame = layers.metalMap.cels[1].frame
  end
  local clean, original, oldRust, top = sourceImages(sprite, source, frame)
  local read = reader(clean)
  local area, allowed
  if layers then
    local scope = layers.scope:cel(frame)
    if not scope then return nil, "This frame is missing its painted material area." end
    area = scope.bounds
    local readScope = readCel(scope)
    allowed = function(x, y) return select(4, readScope(x, y)) > 0 end
  else
    local selection = sprite.selection
    if useSelection then
      if selection.isEmpty then return nil, "Make a selection or use the whole material." end
      allowed = function(x, y) return selection:contains(x, y) end
    else
      allowed = function() return true end
    end
    area = trim(read, clean:shrinkBounds(), allowed)
    if not area then return nil, "The selected material has no visible pixels in this frame." end
  end
  local site = {sprite = sprite, layer = source, frame = frame, cel = not source.isGroup and source:cel(frame)}
  local saved = group and info(group).paintRecipe or {}
  return {sprite = sprite, source = source, frame = frame, group = group, layers = layers,
    top = top, original = original, oldRust = reader(oldRust), saved = saved,
    settings = mergedRecipe(saved, {}), target = makeTarget(site, area, allowed, read)}
end

function Native.context(site, useSelection)
  local sprite, layer = site.sprite, site.layer
  if not sprite or sprite.colorMode ~= ColorMode.RGB then return nil, "Painted materials require an RGB sprite." end
  if not layer then return nil, "Select the metal layer or its material group." end
  local frame = site.frame or sprite.frames[1]
  if type(frame) == "number" then frame = sprite.frames[frame] end
  local node = layer
  while node and node ~= sprite do
    if isPainted(node) then
      local source = inputLayer(node)
      if not source then return nil, "The original metal layer for this material is missing." end
      return contextFrom(sprite, source, frame, node)
    end
    node = node.parent
  end
  local source = sourceLayer(layer)
  if not source or not (isRaster(source) or source.isGroup) or info(source).paintRole then
    return nil, "Select the metal layer or its material group."
  end
  return contextFrom(sprite, source, frame, findGroup(source, frame), useSelection == true)
end

local function grayValues(layer, frame, target)
  local values = {}
  local read = readCel(layer and layer:cel(frame))
  for y = 0, target.height - 1 do
    for x = 0, target.width - 1 do
      local r, g, b, a = read(x + target.x, y + target.y)
      if a > 0 then
        values[y * target.width + x + 1] = byte(Surface.luminance(r, g, b) * a)
      end
    end
  end
  return values
end

local function initialHeight(context, settings)
  local source = context.target.read
  local height = settings.heightLayer
  if settings.heightMode == "Height Map Layer" then
    if not isRaster(height) or height.sprite ~= context.sprite or not height:cel(context.frame) then
      return nil, "Choose a height map layer with pixels in this frame."
    end
    height = readCel(height:cel(context.frame))
  else
    height = source
  end
  local target, out = context.target, {}
  for y = 0, target.height - 1 do
    for x = 0, target.width - 1 do
      if target.alphaAt(x, y) > 0 then
        local px, py = target.x + x, target.y + y
        local r, g, b, a = height(px, py)
        if a == 0 then r, g, b = source(px, py) end
        local value = settings.heightMode == "Flat" and 0.5 or Surface.luminance(r, g, b)
        if settings.heightInvert then value = 1 - value end
        out[y * target.width + x + 1] = byte(value * 255)
      end
    end
  end
  return out
end

local function prepare(context, settings, commitMetal)
  local target, layers, frame = context.target, context.layers, context.frame
  local recipe = mergedRecipe(context.saved, settings)
  local height, message
  if layers then height = grayValues(layers.heightMap, frame, target)
  else height, message = initialHeight(context, settings) end
  if not height then return nil, message end
  local options = mergedRecipe(recipe, {})
  options.heights = {}
  for index, value in pairs(height) do options.heights[index] = value / 255 end
  options.rustAt = function(x, y) return context.oldRust(target.x + x, target.y + y) end
  local generated = Paint.generate(target.width, target.height, options, target.mask)
  local baseline, metal, regenerate = generated.chips, generated.chips, false
  if layers then
    metal = grayValues(layers.metalMap, frame, target)
    baseline = grayValues(layers.metalBaseline, frame, target)
    local previous = context.settings
    regenerate = settings.regenerateMetal or recipe.chips ~= previous.chips
      or recipe.seed ~= previous.seed or recipe.seamless ~= previous.seamless
      or recipe.edgeWear ~= previous.edgeWear or recipe.edgeWidth ~= previous.edgeWidth
    if regenerate or recipe.edgeWear > 0 then
      local baselineChanged = false
      for index = 1, target.width * target.height do
        local current, previous = metal[index] or 0, baseline[index] or 0
        local x, y = (index - 1) % target.width, (index - 1) // target.width
        local generatedValue = generated.chips[index] or 0
        if previous ~= generatedValue then baselineChanged = true end
        if (target.alphaAt(x, y) > 0 or metal[index] ~= nil)
            and (settings.regenerateMetal or current == previous) then
          metal[index] = generatedValue
        end
      end
      baseline = generated.chips
      regenerate = regenerate or (commitMetal and baselineChanged)
    end
    options.effectMasks = {}
    for _, key in ipairs(maskedEffects) do
      local layer = layers[mapKeys[key]]
      if layer then options.effectMasks[key] = grayValues(layer, frame, target) end
    end
  end
  local function baseAt(x, y) return target.read(target.x + x, target.y + y) end
  local rendered = Paint.render(target.width, target.height, options, target.mask, baseAt, generated, metal)
  rendered.undercoat = {}
  if recipe.opacity > 0 and recipe.color.a > 0 then
    for y = 0, target.height - 1 do
      for x = 0, target.width - 1 do
        local _, _, _, rustAlpha = options.rustAt(x, y)
        local a = target.alphaAt(x, y)
        if rustAlpha > 0 and a > 0 then
          local r, g, b = baseAt(x, y)
          rendered.undercoat[y * target.width + x + 1] = (a << 24) | (b << 16) | (g << 8) | r
        end
      end
    end
  end
  return {recipe = recipe, rendered = rendered, metal = metal, baseline = baseline, height = height,
    regenerate = regenerate}
end

local function grayImage(context, values, mode)
  local target, pixels = context.target, {}
  for index, permit in ipairs(target.permit) do
    local value = values[index]
    local x, y = (index - 1) % target.width, (index - 1) // target.width
    local onSource = target.alphaAt(x, y) > 0
    local retained = context.layers and value ~= nil and mode ~= "preview"
    if permit > 0 and (mode == "scope" or onSource or retained)
        and (value ~= nil or mode ~= "height") then
      local gray = value or 0
      pixels[index] = 0xff000000 | (gray << 16) | (gray << 8) | gray
    end
  end
  return imageFrom(context.sprite, target.width, target.height, pixels)
end

function Native.preview(context, settings, rect, channel)
  settings = settings or {}
  local target = context.target
  rect = rect or Rectangle(0, 0, target.width, target.height)
  local image = makeImage(context.sprite, rect.width, rect.height)
  if channel == "Original" then
    image:drawImage(context.original, Point(-target.x - rect.x, -target.y - rect.y))
    return image
  end
  local prepared, message = prepare(context, settings)
  if not prepared then return nil, message end
  local map = channel == "Metal Map" and prepared.metal or channel == "Height Map" and prepared.height
    or channel == "Bevel Coverage" and prepared.rendered.bevel
  if map then
    local mode = channel == "Height Map" and "height" or "preview"
    image:drawImage(grayImage(context, map, mode), Point(-rect.x, -rect.y))
    return image
  end
  image:drawImage(context.original, Point(-target.x - rect.x, -target.y - rect.y))
  for _, stage in ipairs(stages) do
    local layer = context.layers and context.layers[stage]
    local cel = layer and layer:cel(context.frame)
    if not layer or layer.isVisible then
      local opacity = layer and ((layer.opacity or 255) * (cel and cel.opacity or 255) + 127) // 255 or 255
      local rendered = imageFrom(context.sprite, target.width, target.height, prepared.rendered[stage] or {})
      image:drawImage(rendered, Point(-rect.x, -rect.y), opacity, layer and layer.blendMode or BlendMode.NORMAL)
    end
  end
  return image
end

local function createLayer(context, parent, role, image, editable)
  local sprite = context.sprite
  local layer = image and sprite:newLayer() or sprite:newGroup()
  layer.name, layer.parent = names[role], parent
  info(layer).paintRole = role
  if image then
    sprite:newCel(layer, context.frame, image, Point(context.target.x, context.target.y))
    layer.isEditable = editable == true
  end
  return layer
end

local function outputImages(context, prepared)
  local target, result = context.target, {}
  for _, stage in ipairs(stages) do
    if context.layers and context.layers[stage] or next(prepared.rendered[stage] or {}) then
      result[stage] = imageFrom(context.sprite, target.width, target.height, prepared.rendered[stage] or {})
    end
  end
  return result
end

local function same(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return a == b end
  for key, value in pairs(a) do if not same(value, b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end

local function replace(context, layer, image)
  if not layer or not image then return end
  local cel = layer:cel(context.frame)
  if not cel then
    context.sprite:newCel(layer, context.frame, image, Point(context.target.x, context.target.y))
  elseif cel.image.width ~= image.width or cel.image.height ~= image.height or cel.image.bytes ~= image.bytes then
    cel.image = image
    cel.position = Point(context.target.x, context.target.y)
  end
end

local function wantsStage(recipe, stage)
  if stage == "bevel" then return recipe.bevelWear > 0 end
  if stage == "metal" then return recipe.palette.metal ~= nil end
  if stage == "primer" then return recipe.palette.primer ~= nil or recipe.edgeWear > 0 end
  if stage == "scuff" then return recipe.scuffs > 0 end
  if stage == "fading" then return recipe.fading > 0 end
  if stage == "soot" then return recipe.soot > 0 end
  return true
end

local function updateStages(context, group, recipe, images)
  local layers = context.layers
  for i, stage in ipairs(stages) do
    local layer = layers and layers[stage]
    local image = images[stage]
    if layer then
      if stage == "rust" and layer.name == "Rust in Chips" then layer.name = names.rust end
      replace(context, layer, image)
    elseif wantsStage(recipe, stage) then
      image = image or makeImage(context.sprite, context.target.width, context.target.height)
      layer = createLayer(context, group, stage, image, false)
      if layers then
        local nextLayer = layers.mapsGroup
        for ordinal = i + 1, #stages do
          if layers[stages[ordinal]] then nextLayer = layers[stages[ordinal]]; break end
        end
        if nextLayer then layer.stackIndex = nextLayer.stackIndex end
        layers[stage] = layer
      end
    end
  end
end

local function addWearMasks(context, maps, existing, recipe, editing)
  local white
  for _, key in ipairs({"primer", "fading", "scuff", "soot", "bevel"}) do
    local role = mapKeys[key]
    if not (existing and existing[role]) and (editing == key or wantsStage(recipe, key)) then
      white = white or grayImage(context, context.target.permit)
      local layer = createLayer(context, maps, role, white, true)
      layer.isVisible = false
    end
  end
end

function Native.apply(context, settings)
  settings = settings or {}
  local prepared, message = prepare(context, settings, true)
  if not prepared then return nil, message end
  local sprite, group = context.sprite, context.group
  local images = outputImages(context, prepared)
  local metal, baseline
  if not group or prepared.regenerate then
    metal, baseline = grayImage(context, prepared.metal), grayImage(context, prepared.baseline)
  end
  if group then
    app.transaction("Update Painted Material", function()
      if not same(context.saved, prepared.recipe) then info(group).paintRecipe = prepared.recipe end
      if prepared.regenerate then
        replace(context, context.layers.metalMap, metal)
        replace(context, context.layers.metalBaseline, baseline)
      end
      updateStages(context, group, prepared.recipe, images)
      if context.layers.mapsGroup then
        addWearMasks(context, context.layers.mapsGroup, context.layers, prepared.recipe, settings.editMask)
      end
    end)
  else
    local height = grayImage(context, prepared.height, "height")
    local scope = grayImage(context, context.target.permit, "scope")
    local white = grayImage(context, context.target.permit)
    app.transaction("Create Painted Material", function()
      local source = info(context.source)
      if not source.paintSource then source.paintSource = tostring(context.source.uuid) end
      group = sprite:newGroup()
      group.name = "Painted Material - " .. context.source.name
      group.parent = context.source.parent
      group.stackIndex = context.top.stackIndex + 1
      info(group).paintVersion = 1
      info(group).paintInput = source.paintSource
      info(group).paintRecipe = prepared.recipe
      updateStages(context, group, prepared.recipe, images)
      local maps = createLayer(context, group, "mapsGroup")
      for _, key in ipairs(mapOrder) do
        local image = key == "metalMap" and metal or (key == "heightMap" and height)
          or (key == "metalBaseline" and baseline) or (key == "scope" and scope) or white
        local layer = createLayer(context, maps, key, image, key ~= "scope" and key ~= "metalBaseline")
        layer.isVisible = key == "metalMap"
      end
      addWearMasks(context, maps, nil, prepared.recipe, settings.editMask)
      maps.isVisible, maps.isCollapsed = false, true
    end)
  end
  if app.sprite == sprite then app.layer = group end
  app.refresh()
  return group
end

function Native.refresh(sprite, group)
  if sprite.colorMode ~= ColorMode.RGB or not isPainted(group) then return false end
  local context = Native.context({sprite = sprite, layer = group})
  local layers = context and context.layers or Native.layers(group)
  local images = context and outputImages(context, assert(prepare(context, {})))
  local changed = false
  for _, stage in ipairs(stages) do
    local layer = layers[stage]
    local cel = context and layer and layer:cel(context.frame) or (layer and layer.cels[1])
    if cel then
      local image = cel.image
      local replacement = images and images[stage]
      local bytes = replacement and replacement.bytes or string.rep("\0", image.rowStride * image.height)
      if #bytes == #image.bytes and bytes ~= image.bytes then
        -- Derived pixels must not add an Undo step after a brush stroke on a map.
        image.bytes = bytes
        changed = true
      end
    end
  end
  return changed
end

function Native.editMap(context, key)
  local layers = context.group and Native.layers(context.group)
  local target = layers and layers[mapKeys[key] or key]
  if not target or not layers.mapsGroup then return nil, "Apply the material to create its maps." end
  for _, layer in ipairs(layers.mapsGroup.layers) do layer.isVisible = layer == target end
  layers.mapsGroup.isVisible, layers.mapsGroup.isCollapsed = true, false
  context.group.isCollapsed = false
  app.frame, app.layer = context.frame, target
  app.refresh()
  return true
end

function Native.showResult(context)
  local layers = context.group and Native.layers(context.group)
  if not layers or not layers.mapsGroup then return nil, "Select a painted material." end
  layers.mapsGroup.isVisible = false
  app.frame, app.layer = context.frame, context.group
  app.refresh()
  return true
end

return Native
