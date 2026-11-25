local AO = require("lib.ambient_occlusion")
local CastShadow = require("lib.cast_shadow")
local Details = require("lib.prop_details")
local Lighting = require("lib.material_lighting")
local Paint = require("lib.paint_native")
local Project = require("lib.material_project")
local Surface = require("lib.surface")

local Native = {}
local namespace = "substanceprite/substanceprite"
local version = 1
local defaultPreset = "Cargo Container"

local function props(layer)
  return layer.properties(namespace)
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

local function isDetailGroup(layer)
  return layer and layer.isGroup and props(layer).detailVersion == version
end

local function walk(layers, visit)
  for _, layer in ipairs(layers) do
    visit(layer)
    if layer.isGroup then walk(layer.layers, visit) end
  end
end

function Native.list(sprite)
  local result = {}
  if sprite and sprite.colorMode == ColorMode.RGB then
    walk(sprite.layers, function(layer)
      if isDetailGroup(layer) then result[#result + 1] = layer end
    end)
  end
  return result
end

function Native.layers(group)
  if not isDetailGroup(group) then return nil end
  local result = { outputs = {} }
  for _, layer in ipairs(group.layers) do
    local data = props(layer)
    if data.detailRole == "output" and data.detailEntryId then
      result.outputs[data.detailEntryId] = layer
    elseif data.detailRole == "relief" then
      result.relief = layer
    elseif data.detailRole == "inputs" and layer.isGroup then
      result.inputs = layer
      for _, input in ipairs(layer.layers) do
        local role = props(input).detailRole
        if role then result[role] = input end
      end
    end
  end
  return result
end

local function remember(layer)
  if not layer then return "" end
  local data = props(layer)
  if not data.detailLink then data.detailLink = tostring(layer.uuid) end
  return data.detailLink
end

local function resolve(group, id, adjacent)
  if not id or id == "" then return nil end
  local below = adjacent and group.parent.layers[group.stackIndex - 1]
  if below and props(below).detailLink == id then return below end
  local match, count = nil, 0
  walk(group.sprite.layers, function(layer)
    if props(layer).detailLink == id then match, count = layer, count + 1 end
  end)
  if count == 1 then return match end
end

local function frameFor(group)
  local parts = Native.layers(group)
  local cel = parts.mask and parts.mask.cels[1]
  return cel and cel.frame or group.sprite.frames[props(group).detailFrame or 1]
end

local function findGroup(site, frame)
  local layer = site.layer
  while layer and layer ~= site.sprite do
    if isDetailGroup(layer) then return layer end
    layer = layer.parent
  end
  local id = props(site.layer).detailLink
  if not id then return nil end
  for _, group in ipairs(Native.list(site.sprite)) do
    if props(group).detailInput == id and frameFor(group) == frame then return group end
  end
end

local function image(sprite, width, height)
  return Image(ImageSpec{
    width = width or sprite.width, height = height or sprite.height,
    colorMode = ColorMode.RGB, colorSpace = sprite.colorSpace,
  })
end

local function emptyPixel()
  return 0, 0, 0, 0
end

local function rgbaReader(pixels, position)
  if not pixels then return emptyPixel end
  local left, top = position.x, position.y
  local width, height = pixels.width, pixels.height
  local bytes, stride = pixels.bytes, pixels.rowStride
  return function(x, y)
    local u, v = x - left, y - top
    if u < 0 or v < 0 or u >= width or v >= height then return 0, 0, 0, 0 end
    local index = v * stride + u * 4 + 1
    return bytes:byte(index, index + 3)
  end
end

local function celReader(cel)
  if not cel then return emptyPixel end
  return rgbaReader(cel.image, cel.position)
end

local function artwork(sprite, layer, frame, canvas, root)
  if layer.isTilemap or layer.isReference or isDetailGroup(layer) then return end
  local opacity, blend = layer.opacity or 255, layer.blendMode or BlendMode.NORMAL
  if layer.isGroup then
    local content = image(sprite)
    local related = { sprite = sprite, layer = layer, frame = frame }
    local paint = Paint.layers(layer) and Paint.context(related)
    local material = props(layer).materialVersion ~= nil
    if paint then
      content:drawImage(paint.original, Point(0, 0))
    elseif material then
      local source = Project.sourceFor(related)
      if source and source.isVisible then artwork(sprite, source, frame, content, false) end
    end
    for _, child in ipairs(layer.layers) do
      if child.isVisible and (not paint or not child.isGroup)
          and (not material or props(child).materialRole == "result") then
        artwork(sprite, child, frame, content, false)
      end
    end
    canvas:drawImage(content, Point(0, 0), opacity, root and BlendMode.NORMAL or blend)
  else
    local cel = layer:cel(frame)
    if cel then
      canvas:drawImage(cel.image, cel.position, (opacity * cel.opacity + 127) // 255, root and BlendMode.NORMAL or blend)
    end
  end
end

local function finishedSource(sprite, source, frame)
  local project = Project.open{ sprite = sprite, layer = source, frame = frame }
  if project and project.group.isVisible then source = project.group end
  local paint = Paint.context{ sprite = sprite, layer = source, frame = frame }
  if paint and paint.group and paint.frame == frame and paint.group.isVisible then
    return paint.group
  end
  return source
end

local function makeTarget(sprite, source, frame, selection, savedScope)
  local pixels = image(sprite)
  artwork(sprite, source, frame, pixels, true)
  local bounds = pixels:shrinkBounds()
  local left, top, right, bottom = bounds.x, bounds.y, bounds.x + bounds.width, bounds.y + bounds.height
  local scope = savedScope and savedScope.bounds or selection and selection.bounds
  if scope then
    left, top = math.max(left, scope.x), math.max(top, scope.y)
    right, bottom = math.min(right, scope.x + scope.width), math.min(bottom, scope.y + scope.height)
  end
  if right <= left or bottom <= top then return nil, "The area has no artwork to detail." end
  local width, height = right - left, bottom - top
  local read = rgbaReader(pixels, Point(0, 0))
  local scopeReader = celReader(savedScope)
  local alpha, allowed, focusX, focusY, nearest = {}, {}, 0, 0, math.huge
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local xx, yy = left + x, top + y
      local permitted = not selection or selection:contains(xx, yy)
      if savedScope then permitted = select(4, scopeReader(xx, yy)) > 0 end
      if permitted then
        local a = select(4, read(xx, yy))
        local index = y * width + x + 1
        if a > 0 then alpha[index] = a end
        if a == 255 then
          allowed[index] = true
          local distance = math.abs(x - (width - 1) / 2) + math.abs(y - (height - 1) / 2)
          if distance < nearest then focusX, focusY, nearest = x, y, distance end
        end
      end
    end
  end
  if not next(allowed) then return nil, "Select an area with fully opaque source pixels." end
  return {
    x = left, y = top, width = width, height = height, read = read, mask = allowed,
    focusX = focusX, focusY = focusY,
    alphaAt = function(x, y) return alpha[y * width + x + 1] or 0 end,
  }
end

function Native.context(site, useSelection)
  local sprite = site and site.sprite
  if not sprite or sprite.colorMode ~= ColorMode.RGB then return nil, "Prop Details requires an RGB sprite." end
  local source = site.layer
  if not source or source.isTilemap or source.isReference then return nil, "Choose an artwork layer or group." end
  local frame = site.frame
  if type(frame) == "number" then frame = sprite.frames[frame] end
  frame = frame or sprite.frames[1]
  local group = findGroup(site, frame)
  if not group then
    local finished = finishedSource(sprite, source, frame)
    if finished ~= source then
      source = finished
      group = findGroup({ sprite = sprite, layer = source }, frame)
    end
  end
  local settings, parts, scope
  if group then
    source = resolve(group, props(group).detailInput, true)
    if not source then return nil, "The original artwork layer is missing." end
    frame, parts = frameFor(group), Native.layers(group)
    if not frame or not parts.inputs or not parts.mask then return nil, "This detail group is missing its inputs." end
    settings = props(group).detailSettings or {}
    settings.heightLayer = resolve(group, props(group).detailHeightInput)
    scope = parts.scope and parts.scope:cel(frame)
  else
    settings = { entries = Details.preset(defaultPreset), seed = 1, preset = defaultPreset,
      heightMode = "Luminance", reliefShadows = true }
  end
  if not group and useSelection == nil then useSelection = not sprite.selection.isEmpty end
  local selection = not group and useSelection and sprite.selection or nil
  if selection and selection.isEmpty then return nil, "Make a selection or use the whole layer." end
  settings.useSelection = selection ~= nil or scope ~= nil
  local target, message = makeTarget(sprite, source, frame, selection, scope)
  if not target then return nil, message end
  return { sprite = sprite, source = source, frame = frame, group = group, parts = parts,
    settings = settings, target = target, selection = selection, site = site }
end

local function byte(value)
  return math.floor(math.max(0, math.min(255, value)) + 0.5)
end

local function merged(context, settings)
  settings = settings or {}
  local result = {}
  for _, key in ipairs({ "entries", "seed", "preset", "heightMode", "heightLayer", "reliefShadows" }) do
    local value = settings[key]
    if value == nil then value = context.settings[key] end
    result[key] = key ~= "heightLayer" and copy(value) or value
  end
  result.entries = result.entries or {}
  local reserved, assigned, nextId = {}, {}, 1
  for _, entry in ipairs(result.entries) do
    if entry.id ~= nil then reserved[tostring(entry.id)] = true end
  end
  for _, entry in ipairs(result.entries) do
    local id = entry.id and tostring(entry.id)
    if not id or id == "" or assigned[id] then
      repeat id, nextId = "detail-" .. nextId, nextId + 1 until not reserved[id] and not assigned[id]
    end
    entry.id, assigned[id] = id, true
  end
  return result
end

local function affectedLayers(context, settings)
  local target, width, height = context.target, context.target.width, context.target.height
  local heightLayer = settings.heightMode == "Height Map Layer" and settings.heightLayer or nil
  heightLayer = Paint.effectiveHeightLayer(heightLayer, context.frame)
  local guide = celReader(heightLayer and heightLayer:cel(context.frame))
  local matteCel = context.parts and context.parts.mask:cel(context.frame)
  local matte = celReader(matteCel)
  local base, coverage, active = {}, {}, {}
  local function read(x, y) return target.read(target.x + x, target.y + y) end
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local index = y * width + x + 1
      if target.mask[index] then
        local xx, yy = target.x + x, target.y + y
        local r, g, b, a = guide(xx, yy)
        if a == 0 then r, g, b = read(x, y) end
        base[index] = settings.heightMode == "Flat" and 0.5 or Surface.luminance(r, g, b)
        local weight = 1
        if matteCel then
          r, g, b, a = matte(xx, yy)
          weight = Surface.luminance(r, g, b) * a / 255
        end
        coverage[index] = weight
        if weight > 0 then active[index] = true end
      end
    end
  end
  local rendered = Details.render(width, height, read, {
    entries = settings.entries, mask = active, heights = base, seed = settings.seed,
  })
  local depth, change = {}, false
  for index, original in pairs(base) do
    local z = rendered.heights[index] or original
    depth[index] = original + (z - original) * coverage[index]
    if math.abs(depth[index] - original) > 0.004 then change = true end
  end
  for _, layer in ipairs(rendered.layers) do
    for index, packed in pairs(layer.pixels) do
      local alpha = byte(((packed >> 24) & 255) * (coverage[index] or 0))
      layer.pixels[index] = alpha > 0 and (packed & 0x00ffffff) | (alpha << 24) or nil
    end
  end
  local shadow = {}
  if settings.reliefShadows and change then
    local lighting = { lightAngle = 135, lightElevation = 44, aoRadius = 4, shadowReach = 5, shadowSoftness = 46 }
    local function difference(channel)
      return Lighting.map(width, height, depth, lighting, target.mask, nil, channel),
        Lighting.map(width, height, base, lighting, target.mask, nil, channel)
    end
    local ao, baseAO = difference(Lighting.aoChannel)
    local cast, baseCast = difference(Lighting.shadowChannel)
    for index in pairs(active) do
      local dark = math.max(0, ao[index] - baseAO[index]) * AO.maxDarkening * 0.42
      local shade = math.max(0, cast[index] - baseCast[index]) * CastShadow.maxDarkening * 0.27
      local alpha = byte(255 * (1 - (1 - dark) * (1 - shade)) * coverage[index])
      if alpha > 0 then shadow[index] = alpha << 24 end
    end
  end
  return rendered.layers, depth, shadow
end

local function localImage(context, packed, width, height)
  local pixels = image(context.sprite, width, height)
  for index, value in pairs(packed) do
    if value ~= 0 then pixels:putPixel((index - 1) % width, (index - 1) // width, value) end
  end
  return pixels
end

local function canvasImage(context, packed)
  local target = context.target
  local output = image(context.sprite)
  for index, value in pairs(packed) do
    if value ~= 0 then
      output:putPixel(target.x + (index - 1) % target.width, target.y + (index - 1) // target.width, value)
    end
  end
  return output
end

local function grayscale(values)
  local result = {}
  for index, value in pairs(values) do
    local gray = byte(value * 255)
    result[index] = 0xff000000 | (gray << 16) | (gray << 8) | gray
  end
  return result
end

function Native.preview(context, settings, rect, channel)
  local target = context.target
  rect = rect or Rectangle(0, 0, target.width, target.height)
  local output = image(context.sprite, rect.width, rect.height)
  local rgba = app.pixelColor.rgba
  if channel == "Mask" then
    local cel = context.parts and context.parts.mask:cel(context.frame)
    local readMask = celReader(cel)
    for y = 0, rect.height - 1 do
      for x = 0, rect.width - 1 do
        local u, v = rect.x + x, rect.y + y
        if target.mask[v * target.width + u + 1] then
          local r, g, b, a = readMask(target.x + u, target.y + v)
          local gray = cel and byte(Surface.luminance(r, g, b) * a) or 255
          output:putPixel(x, y, rgba(gray, gray, gray, 255))
        end
      end
    end
    return output
  end
  if channel ~= "Height Map" then
    for y = 0, rect.height - 1 do
      for x = 0, rect.width - 1 do
        local u, v = rect.x + x, rect.y + y
        local a = target.alphaAt(u, v)
        if a > 0 then
          local r, g, b = target.read(target.x + u, target.y + v)
          output:putPixel(x, y, rgba(r, g, b, a))
        end
      end
    end
    if channel == "Original" then return output end
  end
  local stages, height, shadows = affectedLayers(context, merged(context, settings))
  local offset = Point(-rect.x, -rect.y)
  local function draw(packed)
    output:drawImage(localImage(context, packed, target.width, target.height), offset)
  end
  if channel == "Height Map" then draw(grayscale(height)); return output end
  for _, stage in ipairs(stages) do
    local native = context.parts and context.parts.outputs[tostring(stage.id)]
    if not native or native.isVisible then draw(stage.pixels) end
  end
  if not context.parts or not context.parts.relief or context.parts.relief.isVisible then draw(shadows) end
  return output
end

local function named(sprite, parent, role, name, group)
  local layer = group and sprite:newGroup() or sprite:newLayer()
  layer.parent, layer.name = parent, name
  props(layer).detailRole = role
  return layer
end

local function write(context, layer, pixels, live)
  local cel = layer:cel(context.frame)
  if not cel then
    context.sprite:newCel(layer, context.frame, pixels, Point(0, 0))
    return true
  end
  local old, position = cel.image, cel.position
  local matching = old.width == pixels.width and old.height == pixels.height and position.x == 0 and position.y == 0
  if matching and old.bytes == pixels.bytes then return false end
  if matching and live then
    old.bytes = pixels.bytes
  else
    cel.image, cel.position = pixels, Point(0, 0)
  end
  return true
end

local function sync(context, settings, live)
  local stages, height, shadows = affectedLayers(context, settings)
  local sprite, group, parts = context.sprite, context.group, context.parts
  local byId, wanted, changed = {}, {}, false
  for _, stage in ipairs(stages) do byId[tostring(stage.id)] = stage end
  for _, entry in ipairs(settings.entries) do
    local id, stage = entry.id, byId[entry.id]
    local layer = parts.outputs[id]
    local name = stage and stage.name or Details.nameOf(entry)
    wanted[id] = true
    if not layer and not live then
      layer = named(sprite, group, "output", name)
      props(layer).detailEntryId = id
      layer.isEditable = false
      parts.outputs[id] = layer
    end
    if layer then
      if not live then layer.name = name end
      if write(context, layer, canvasImage(context, stage and stage.pixels or {}), live) then changed = true end
    end
  end
  if not live then
    for id, layer in pairs(parts.outputs) do
      if not wanted[id] then sprite:deleteLayer(layer); parts.outputs[id] = nil end
    end
    for index, entry in ipairs(settings.entries) do parts.outputs[entry.id].stackIndex = index end
    parts.relief.stackIndex = #settings.entries + 1
    parts.inputs.stackIndex = #group.layers
  end
  if parts.relief and write(context, parts.relief, canvasImage(context, shadows), live) then changed = true end
  if parts.height and write(context, parts.height, canvasImage(context, grayscale(height)), live) then changed = true end
  return changed
end

function Native.apply(context, settings)
  if not context or not context.target then return nil, "Choose artwork to detail." end
  local options = merged(context, settings)
  local sprite, frame, source, group = context.sprite, context.frame, context.source, context.group
  local height = options.heightMode == "Height Map Layer" and options.heightLayer or nil
  if options.heightMode == "Height Map Layer" and
      (not height or height.sprite ~= sprite or not height.isImage or height.isTilemap or
       props(height).detailRole or not height:cel(frame)) then
    return nil, "Choose a separate raster height map with pixels in this frame."
  end
  app.transaction(group and "Update Prop Details" or "Create Prop Details", function()
    if not group then
      group = sprite:newGroup()
      group.name, group.parent = "Prop Details — " .. source.name, source.parent
      group.stackIndex = source.stackIndex + 1
      local data = props(group)
      data.detailVersion, data.detailInput, data.detailFrame = version, remember(source), frame.frameNumber
      local parts = { outputs = {} }
      parts.relief = named(sprite, group, "relief", "Detail relief shadows")
      parts.relief.isEditable = false
      parts.inputs = named(sprite, group, "inputs", "Maps and mask", true)
      parts.inputs.isVisible, parts.inputs.isCollapsed = false, true
      parts.height = named(sprite, parts.inputs, "height", "Height Map - Prop Details")
      parts.height.isVisible, parts.height.isEditable = false, false
      parts.mask = named(sprite, parts.inputs, "mask", "Detail Mask")
      local white = image(sprite)
      white:clear(0xffffffff)
      sprite:newCel(parts.mask, frame, white, Point(0, 0))
      if context.selection then
        parts.scope = named(sprite, parts.inputs, "scope", "Saved Selection")
        parts.scope.isVisible, parts.scope.isEditable = false, false
        local selection = image(sprite)
        local bounds = context.selection.bounds
        for y = math.max(0, bounds.y), math.min(sprite.height, bounds.y + bounds.height) - 1 do
          for x = math.max(0, bounds.x), math.min(sprite.width, bounds.x + bounds.width) - 1 do
            if context.selection:contains(x, y) then selection:putPixel(x, y, 0xffffffff) end
          end
        end
        sprite:newCel(parts.scope, frame, selection, Point(0, 0))
      end
      context.group, context.parts = group, parts
    end
    local heightLink = remember(height)
    local data = props(group)
    data.detailHeightInput = heightLink
    local persisted = copy(options)
    persisted.heightLayer = nil
    data.detailSettings = persisted
    sync(context, options, false)
    context.parts.inputs.isVisible = false
  end)
  options.useSelection = context.settings.useSelection
  context.settings = options
  if app.sprite == sprite then app.layer = group end
  app.refresh()
  return group
end

function Native.refresh(sprite, group)
  if not isDetailGroup(group) then return false end
  local frame = frameFor(group)
  if not frame then return false end
  local context = Native.context{ sprite = sprite, layer = group, frame = frame }
  if not context then
    local parts, changed = Native.layers(group), false
    if not parts then return false end
    local empty = image(sprite)
    for _, layer in pairs(parts.outputs) do
      if layer:cel(frame) and write({ sprite = sprite, frame = frame }, layer, empty, true) then changed = true end
    end
    for _, layer in pairs({ parts.height, parts.relief }) do
      if layer:cel(frame) and write({ sprite = sprite, frame = frame }, layer, empty, true) then changed = true end
    end
    return changed
  end
  return sync(context, merged(context), true)
end

function Native.editMask(context)
  local group = type(context) == "table" and context.group or context
  local parts = Native.layers(group)
  if not parts or not parts.inputs or not parts.mask then return nil, "Apply details to create the mask." end
  parts.inputs.isVisible, parts.inputs.isCollapsed, parts.mask.isVisible = true, false, true
  if app.sprite == group.sprite then app.layer = parts.mask end
  app.refresh()
  return parts.mask
end

function Native.showResult(context)
  local group = type(context) == "table" and context.group or context
  local parts = Native.layers(group)
  if not parts or not parts.inputs then return nil, "Select a Prop Details group." end
  parts.inputs.isVisible = false
  Native.refresh(group.sprite, group)
  if app.sprite == group.sprite then app.layer = group end
  app.refresh()
  return group
end

return Native
