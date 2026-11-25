local Aseprite = require("lib.aseprite")
local Catalog = require("lib.material_catalog")
local Workspace = require("lib.workspace")

local Project = {}
local namespace = "substanceprite/substanceprite"
local version = 1
local lightingVersion = 1
local settingKeys = {
  "seed", "nextLayerId", "layers", "palette", "paletteAmount", "paletteName",
  "patternAmount", "patternScale", "patternDirection", "lighting", "seamless",
  "heightMode", "heightChannel", "heightInvert", "normalStrength", "smoothing",
  "invertGreen", "directLight", "lightAngle", "lightElevation", "lightStrength", "lightColor",
  "shadows", "shadowReach", "shadowSoftness", "shadowStrength", "ao", "aoRadius", "aoStrength", "rotation",
}

local function properties(layer)
  return layer.properties(namespace)
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
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

local function walk(layers, visit)
  for _, layer in ipairs(layers) do
    visit(layer)
    if layer.isGroup then walk(layer.layers, visit) end
  end
end

local function isProject(layer)
  return layer and layer.isGroup and properties(layer).materialVersion == version
end

local function isRaster(layer, sprite)
  return layer and layer.sprite == sprite and layer.isImage and not layer.isReference
    and not layer.isTilemap and not properties(layer).materialRole
end

local function remember(layer)
  if not layer then return "" end
  local data = properties(layer)
  local id = data.materialLink
  if not id then
    id = tostring(layer.uuid)
    data.materialLink = id
  end
  return id
end

local function linkedRaster(group, id, adjacent)
  if not id or id == "" then return end
  local sprite = group.sprite
  local function matches(layer)
    return isRaster(layer, sprite) and properties(layer).materialLink == id
  end
  if adjacent then
    local layer = group.parent.layers[group.stackIndex - 1]
    if matches(layer) then return layer end
  end
  local found, count = nil, 0
  walk(sprite.layers, function(layer)
    if matches(layer) then found, count = layer, count + 1 end
  end)
  if count == 1 then return found end
end

function Project.list(sprite)
  local groups = {}
  if sprite and sprite.colorMode == ColorMode.RGB then
    walk(sprite.layers, function(layer)
      if isProject(layer) then groups[#groups + 1] = layer end
    end)
  end
  return groups
end

local function findGroup(site)
  local current = site and site.layer
  if not current then return end
  local sprite = site.sprite
  local layer = current
  while layer and layer ~= sprite do
    if isProject(layer) then return layer end
    layer = layer.parent
  end
  if not isRaster(current, sprite) then return end
  local id = properties(current).materialLink
  if not id then return end
  local above = current.parent.layers[current.stackIndex + 1]
  if isProject(above) and properties(above).sourceLink == id then return above end
  local found, count = nil, 0
  for _, group in ipairs(Project.list(sprite)) do
    if properties(group).sourceLink == id then found, count = group, count + 1 end
  end
  if count == 1 then return found end
end

function Project.sourceFor(site)
  local group = findGroup(site)
  return group and linkedRaster(group, properties(group).sourceLink, true)
end

local function children(group)
  local data = properties(group)
  local result = {
    source = linkedRaster(group, data.sourceLink, true),
    height = linkedRaster(group, data.heightLink),
    masks = {},
  }
  for _, layer in ipairs(group.layers) do
    local role = properties(layer).materialRole
    if role == "result" then
      result.output = layer
    elseif role == "inputs" and layer.isGroup then
      result.inputs = layer
      for _, input in ipairs(layer.layers) do
        local info = properties(input)
        if info.materialRole == "scope" then result.scope = input
        elseif info.materialRole == "mask" then result.masks[info.materialMask] = input end
      end
    end
  end
  return result
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
    if u < 0 or v < 0 or u >= bounds.width or v >= bounds.height then return 0, 0, 0, 0 end
    local index = v * stride + u * 4 + 1
    return bytes:byte(index, index + 3)
  end
end

local function targetFor(site, scope)
  if not scope then return Aseprite.textureTarget(site, "Layer Pixels") end
  local bounds = scope.bounds
  local left, top = math.max(0, bounds.x), math.max(0, bounds.y)
  local width = math.min(site.sprite.width, bounds.x + bounds.width) - left
  local height = math.min(site.sprite.height, bounds.y + bounds.height) - top
  if width < 1 or height < 1 then return nil, "The saved selection is outside the canvas." end
  local source, selection = reader(site.cel), reader(scope)
  local mask, alpha, focusX, focusY, nearest = {}, {}, 0, 0, math.huge
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local _, _, _, selected = selection(x + left, y + top)
      local _, _, _, opacity = source(x + left, y + top)
      if selected > 0 and opacity > 0 then
        local index = y * width + x + 1
        mask[index], alpha[index] = true, opacity
        local distance = math.abs(x - (width - 1) / 2) + math.abs(y - (height - 1) / 2)
        if distance < nearest then focusX, focusY, nearest = x, y, distance end
      end
    end
  end
  if nearest == math.huge then return nil, "The saved selection has no visible source pixels." end
  return {
    x = left, y = top, width = width, height = height, site = site, read = source, mask = mask,
    focusX = focusX, focusY = focusY,
    alphaAt = function(x, y) return alpha[y * width + x + 1] or 0 end,
  }
end

local function settingsFor(group, layers, frame, target)
  local data = properties(group)
  local settings = data.materialSettings or {}
  -- Earlier projects stored a shadow toggle for the preview only.
  if settings.lightingVersion ~= lightingVersion then settings.shadows = nil end
  settings.recipe = Catalog.recipe(settings.recipeId)
  if settings.recipe and settings.palette and #settings.palette > 0 then
    settings.recipe.palette = settings.palette
  end
  settings.heightLayer = layers.height
  settings.useSelection = layers.scope and layers.scope:cel(frame) ~= nil or false
  settings.masks = {}
  if not target then return settings end
  local offsetX, offsetY = target.x, target.y
  for id, mask in pairs(layers.masks) do
    local cel = mask:cel(frame)
    if cel then
      local read = reader(cel)
      settings.masks[id] = function(x, y)
        local r, g, b, a = read(x + offsetX, y + offsetY)
        return (2126 * r + 7152 * g + 722 * b) * a / (10000 * 255 * 255)
      end
    end
  end
  if settings.heightMode == "Luminance" or settings.heightMode == "Height Map Layer" and layers.height then
    local heights, count = Aseprite.heightSamples(target, layers.height, {
      channel = settings.heightChannel, invert = settings.heightInvert,
    }, true)
    if count > 0 then settings.heights = heights end
  end
  return settings
end

function Project.open(site)
  local group = findGroup(site)
  if not group then return end
  local layers = children(group)
  local frame = site.frame
  local sourceSite = {
    sprite = site.sprite, layer = layers.source, frame = frame,
    cel = layers.source and layers.source:cel(frame),
  }
  local target, message
  if layers.source then
    target, message = targetFor(sourceSite, layers.scope and layers.scope:cel(frame))
  else
    message = "The material project has no source layer."
  end
  return {
    sprite = site.sprite, group = group, site = sourceSite, target = target, message = message,
    settings = settingsFor(group, layers, frame, target),
  }
end

local function namedLayer(sprite, parent, role, name, isGroup)
  local layer = isGroup and sprite:newGroup() or sprite:newLayer()
  layer.name, layer.parent = name, parent
  properties(layer).materialRole = role
  return layer
end

local function newImage(sprite, width, height)
  return Image(ImageSpec {
    width = width or sprite.width, height = height or sprite.height,
    colorMode = ColorMode.RGB, colorSpace = sprite.colorSpace,
  })
end

local function selectionImage(sprite)
  if sprite.selection.isEmpty then return end
  local bounds = sprite.selection.bounds
  local x, y = math.max(0, bounds.x), math.max(0, bounds.y)
  local width = math.min(sprite.width, bounds.x + bounds.width) - x
  local height = math.min(sprite.height, bounds.y + bounds.height) - y
  if width < 1 or height < 1 then return end
  local image = newImage(sprite, width, height)
  local white = app.pixelColor.rgba(255, 255, 255, 255)
  for j = 0, height - 1 do
    for i = 0, width - 1 do
      if sprite.selection:contains(x + i, y + j) then image:drawPixel(i, j, white) end
    end
  end
  return image, Point(x, y)
end

local function serialized(settings, previous)
  local recipe = settings.recipeId or (settings.recipe and settings.recipe.id) or previous.recipeId
  local material = Catalog.recipe(recipe)
  if not material then return nil, "Choose a material before applying." end
  local final = { recipeId = material.id, lightingVersion = lightingVersion }
  for _, key in ipairs(settingKeys) do
    local value = settings[key]
    if value == nil and (key ~= "shadows" or previous.lightingVersion == lightingVersion) then value = previous[key] end
    final[key] = copy(value)
  end
  final.lightElevation = settings.lightElevation or settings.shadowElevation or final.lightElevation
  local ids, reserved = {}, {}
  local nextId = math.max(1, math.tointeger(final.nextLayerId) or 1)
  final.layers = final.layers or material.layers or {}
  for _, layer in ipairs(final.layers) do
    if layer.id ~= nil then reserved[tostring(layer.id)] = true end
  end
  for _, layer in ipairs(final.layers) do
    local id = layer.id ~= nil and tostring(layer.id)
    if not id or id == "" or ids[id] then
      repeat id, nextId = "layer-" .. nextId, nextId + 1 until not (ids[id] or reserved[id])
    end
    layer.id, ids[id] = id, true
    layer.maskValues = nil
  end
  final.nextLayerId = nextId
  return final
end

local function syncMasks(sprite, layers, frame, settings, requestedId)
  local enabled = {}
  for _, entry in ipairs(settings.layers) do
    local id = entry.id
    local layer = layers.masks[id]
    enabled[id] = true
    if layer or entry.mask == "Painted Mask" or id == requestedId then
      local label = (entry.name or entry.style or entry.kind or "Layer") .. " Mask"
      if not layer then
        layer = namedLayer(sprite, layers.inputs, "mask", label)
        properties(layer).materialMask = id
        layer.isVisible = false
        layers.masks[id] = layer
      elseif layer.name ~= label then
        layer.name = label
      end
      if not layer:cel(frame) then
        local image = newImage(sprite)
        image:clear(app.pixelColor.rgba(255, 255, 255, 255))
        sprite:newCel(layer, frame, image, Point(0, 0))
      end
    end
  end
  for id, layer in pairs(layers.masks) do
    if not enabled[id] then
      sprite:deleteLayer(layer)
      layers.masks[id] = nil
    end
  end
end

local function sourceRows(cel, width, blank)
  local image, bounds = cel.image, cel.bounds
  local bytes, stride = image.bytes, image.rowStride
  local left, right = math.max(bounds.x, 0), math.min(bounds.x + bounds.width, width)
  local start, length = (left - bounds.x) * 4, (right - left) * 4
  if length <= 0 then return function() return blank end end
  local prefix, suffix = blank:sub(1, left * 4), blank:sub(right * 4 + 1)
  return function(y)
    local row = y - bounds.y
    if row < 0 or row >= bounds.height then return blank end
    local offset = row * stride + start
    return prefix .. bytes:sub(offset + 1, offset + length) .. suffix
  end
end

local function frameImage(sprite, group, layers, frame, replacement)
  local source = layers.source and layers.source:cel(frame)
  local output = newImage(sprite)
  if not source then return output end
  local site = { sprite = sprite, frame = frame, layer = layers.source, cel = source }
  local target = targetFor(site, layers.scope and layers.scope:cel(frame))
  local opaque = layers.source.opacity == 255 and source.opacity == 255
  if not replacement and (not target or not opaque) then return output end
  local preview
  if target then
    local message
    preview, message = Workspace.preview(target, settingsFor(group, layers, frame, target),
      { x = 0, y = 0, width = target.width, height = target.height }, "Color")
    if not preview then return nil, message end
  end
  local blank = string.rep("\0", output.rowStride)
  local originalRow = sourceRows(source, sprite.width, blank)
  local previewBytes, previewStride
  if preview then previewBytes, previewStride = preview.bytes, preview.rowStride end
  local rows = {}
  for y = 0, sprite.height - 1 do
    local base = replacement and originalRow(y) or blank
    if preview and y >= target.y and y < target.y + target.height then
      local original = replacement and base or originalRow(y)
      local offset = (y - target.y) * previewStride
      local start, finish = target.x * 4, (target.x + target.width) * 4
      local row = { base:sub(1, start) }
      for column = 0, target.width - 1 do
        local index = column * 4
        local result = previewBytes:sub(offset + index + 1, offset + index + 4)
        local prior = original:sub(start + index + 1, start + index + 4)
        local alpha = result:byte(4)
        if replacement then
          row[#row + 1] = alpha > 0 and result or prior
        else
          row[#row + 1] = alpha == 255 and result ~= prior and result or "\0\0\0\0"
        end
      end
      row[#row + 1] = base:sub(finish + 1)
      base = table.concat(row)
    end
    rows[y + 1] = base
  end
  output.bytes = table.concat(rows)
  return output
end

local function replacement(sprite)
  return #sprite.frames == 1
end

local function syncPresentation(layers, cel, replace)
  local source = layers.source
  local original = source and source:cel(cel.frame)
  local layerOpacity = replace and source and source.opacity or 255
  local celOpacity = replace and original and original.opacity or 255
  local blend = replace and source and source.blendMode or BlendMode.NORMAL
  if layers.output.opacity ~= layerOpacity then layers.output.opacity = layerOpacity end
  if layers.output.blendMode ~= blend then layers.output.blendMode = blend end
  if cel.opacity ~= celOpacity then cel.opacity = celOpacity end
end

function Project.refresh(sprite, group)
  if not sprite or sprite.colorMode ~= ColorMode.RGB or not isProject(group) or group.sprite ~= sprite then
    return nil, "Choose an RGB material project."
  end
  local layers = children(group)
  if not layers.output then return nil, "The material project has no result layer." end
  local replace = replacement(sprite)
  if layers.source and not replace and not layers.source.isVisible then layers.source.isVisible = true end
  local changed = false
  for _, cel in ipairs(layers.output.cels) do
    local image, message = frameImage(sprite, group, layers, cel.frame, replace)
    if not image then return nil, message end
    if cel.image.width == image.width and cel.image.height == image.height
        and cel.position.x == 0 and cel.position.y == 0 then
      local bytes = image.bytes
      if bytes ~= cel.image.bytes then
        -- Derived pixels should not add a history item after every brush stroke.
        cel.image.bytes = bytes
        changed = true
      end
    else
      cel.image, cel.position = image, Point(0, 0)
      changed = true
    end
    syncPresentation(layers, cel, replace)
  end
  return changed
end

local function show(group, frame, visibleLayer)
  local sprite, layers = group.sprite, children(group)
  if not layers.source or not layers.output or not layers.inputs then return nil, "The project is missing layers." end
  group.isVisible = true
  layers.output.isVisible = visibleLayer == layers.output
  layers.source.isVisible = visibleLayer == layers.source or not replacement(sprite)
  layers.inputs.isVisible = visibleLayer ~= layers.source and visibleLayer ~= layers.output
  for _, layer in pairs(layers.masks) do layer.isVisible = layer == visibleLayer end
  if layers.inputs.isVisible then layers.inputs.isCollapsed = false end
  if app.sprite == sprite then
    if frame then app.frame = frame end
    app.layer = visibleLayer
    app.refresh()
  end
  return visibleLayer
end

function Project.editMask(group, id, frame)
  if not isProject(group) then return nil, "Choose a material project." end
  local layer = children(group).masks[tostring(id)]
  if not layer then return nil, "Apply the material to create the mask." end
  return show(group, frame, layer)
end

function Project.editSource(group, frame)
  if not isProject(group) then return nil, "Choose a material project." end
  local source = children(group).source
  if not source then return nil, "The material project has no source layer." end
  return show(group, frame, source)
end

function Project.showResult(group, frame)
  if not isProject(group) then return nil, "Choose a material project." end
  local result = children(group).output
  if not result then return nil, "The material project has no result layer." end
  local _, message = Project.refresh(group.sprite, group)
  if message then return nil, message end
  return show(group, frame, result)
end

function Project.apply(target, settings, context)
  settings = settings or {}
  local site = target and target.site or context and context.site
  local sprite, source, frame
  if site then sprite, source, frame = site.sprite, site.layer, site.frame end
  if not sprite or sprite.colorMode ~= ColorMode.RGB then return nil, "Live materials require an RGB sprite." end
  if not isRaster(source, sprite) or not frame or not source:cel(frame) then
    return nil, "Choose a raster source layer with visible artwork."
  end
  local group = context and context.group or findGroup(site)
  local previous = group and properties(group).materialSettings or {}
  local recipe, message = serialized(settings, previous)
  if not recipe then return nil, message end
  local existing = group and children(group)
  if existing and (not existing.output or not existing.inputs or not existing.scope) then
    return nil, "The material project is missing generated layers."
  end
  local height = settings.heightLayer
  if height == nil and existing then height = existing.height end
  if recipe.heightMode ~= "Height Map Layer" then height = nil end
  if recipe.heightMode == "Height Map Layer" and not isRaster(height, sprite) then
    return nil, "Choose an RGB raster height map layer."
  end
  local scope = existing and existing.scope:cel(frame)
  local useSelection = settings.useSelection
  if useSelection == nil then useSelection = scope ~= nil or not group and not sprite.selection.isEmpty end
  local scopeImage, scopePosition
  if useSelection and (not scope or settings.replaceScope) then
    scopeImage, scopePosition = selectionImage(sprite)
    if not scopeImage then return nil, "Make a selection to use this target." end
  end
  app.transaction("Apply Substanceprite Material", function()
    if not group then
      group = sprite:newGroup()
      group.name = "Material — " .. source.name
      group.parent = source.parent
      group.stackIndex = source.stackIndex + 1
      group.properties(namespace, { materialVersion = version, sourceLink = remember(source) })
      local output = namedLayer(sprite, group, "result", "Material Result")
      output.isEditable = false
      local inputs = namedLayer(sprite, group, "inputs", "Material Masks (white reveals)", true)
      inputs.isVisible, inputs.isCollapsed = false, true
      local selection = namedLayer(sprite, inputs, "scope", "Saved Selection")
      selection.isVisible, selection.isEditable = false, false
      existing = { output = output, inputs = inputs, scope = selection, source = source, masks = {} }
    end
    local data = properties(group)
    local heightLink = remember(height)
    if not equal(previous, recipe) then data.materialSettings = recipe end
    if data.heightLink ~= heightLink then data.heightLink = heightLink end
    existing.height = height
    if scopeImage then
      if scope then scope.image, scope.position = scopeImage, scopePosition
      else sprite:newCel(existing.scope, frame, scopeImage, scopePosition) end
    elseif scope and not useSelection then
      sprite:deleteCel(scope)
    end
    local requestedId = settings.createMask and tostring(settings.createMask)
    syncMasks(sprite, existing, frame, recipe, requestedId)
    local replace = replacement(sprite)
    local image, failure = frameImage(sprite, group, existing, frame, replace)
    if not image then error(failure) end
    local output = existing.output:cel(frame)
    if not output then
      output = sprite:newCel(existing.output, frame, image, Point(0, 0))
    else
      if not image:isEqual(output.image) then output.image = image end
      if output.position.x ~= 0 or output.position.y ~= 0 then output.position = Point(0, 0) end
    end
    syncPresentation(existing, output, replace)
    show(group, frame, existing.output)
  end)
  return group
end

return Project
