local CastShadow = require("lib.cast_shadow")
local Lighting = require("lib.material_lighting")
local Normal = require("lib.normal")
local SceneLighting = require("lib.scene_lighting")
local Surface = require("lib.surface")

local Native = {}
local namespace, version = "substanceprite/substanceprite", 1
local fields = {
  "directLight", "lightAngle", "lightElevation", "lightStrength", "lightColor", "normalStrength", "smoothing",
  "shadows", "shadowStrength", "shadowReach", "shadowSoftness",
  "ao", "aoStrength", "aoRadius", "heightMode", "seamless", "useSelection",
}
local defaults = {
  directLight = true, lightAngle = Lighting.defaults.angle, lightElevation = CastShadow.defaults.elevation,
  lightStrength = 55, lightColor = { r = 255, g = 255, b = 255, a = 255 },
  normalStrength = Normal.defaults.strength, smoothing = 1,
  shadows = true, shadowStrength = 35, shadowReach = 7, shadowSoftness = 42,
  ao = true, aoStrength = 36, aoRadius = 5, heightMode = "Luminance", seamless = false, useSelection = false,
}
local stages = {
  { id = "light", name = "Direct light" },
  { id = "ao", name = "Ambient occlusion" },
  { id = "shadows", name = "Cast shadows" },
}

local function props(layer)
  return layer.properties(namespace)
end

local function isGroup(layer)
  return layer and layer.isGroup and props(layer).sceneLightingVersion == version
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
      if isGroup(layer) then result[#result + 1] = layer end
    end)
  end
  return result
end

function Native.layers(group)
  if not isGroup(group) then return nil end
  local result = {}
  walk(group.layers, function(layer)
    local role = props(layer).sceneLightingRole
    if role then result[role] = layer end
  end)
  return result
end

local function appliesTo(group, frame)
  local layers = Native.layers(group)
  if layers.scope and #layers.scope.cels > 0 then return layers.scope:cel(frame) ~= nil end
  return frame.frameNumber == (props(group).sceneLightingFrame or 1)
end

local function groupFor(site, frame)
  local cursor = site.layer
  while cursor and cursor ~= site.sprite do
    if isGroup(cursor) and appliesTo(cursor, frame) then return cursor end
    cursor = cursor.parent
  end
  for _, group in ipairs(Native.list(site.sprite)) do
    if appliesTo(group, frame) then return group end
  end
end

local function isGuide(layer, sprite)
  return layer and layer.sprite == sprite and layer.isImage and not layer.isTilemap
    and not layer.isReference and not props(layer).sceneLightingRole
end

local function findGuide(sprite, id)
  if not id or id == "" then return nil end
  local result, count
  count = 0
  walk(sprite.layers, function(layer)
    if isGuide(layer, sprite) and props(layer).sceneLightingHeightId == id then
      result, count = layer, count + 1
    end
  end)
  if count == 1 then return result end
end

local function rememberGuide(layer)
  if not layer then return "" end
  local data = props(layer)
  if not data.sceneLightingHeightId then data.sceneLightingHeightId = tostring(layer.uuid) end
  return data.sceneLightingHeightId
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

local function settingsFor(first, second)
  local result = {}
  first, second = first or {}, second or {}
  for _, key in ipairs(fields) do
    local value = first[key]
    if value == nil then value = second[key] end
    if value == nil then value = defaults[key] end
    result[key] = copy(value)
  end
  result.heightLayer = first.heightLayer or second.heightLayer
  return result
end

local function image(sprite, width, height)
  return Image(ImageSpec{
    width = width or sprite.width, height = height or sprite.height,
    colorMode = ColorMode.RGB, colorSpace = sprite.colorSpace,
  })
end

local function unlitImage(sprite, frame)
  local hidden = {}
  local output = image(sprite)
  local ok, failure = pcall(function()
    for _, group in ipairs(Native.list(sprite)) do
      if group.isVisible then
        hidden[#hidden + 1] = group
        group.isVisible = false
      end
    end
    output:drawSprite(sprite, frame.frameNumber)
  end)
  for i = #hidden, 1, -1 do hidden[i].isVisible = true end
  if not ok then return nil, tostring(failure) end
  return output
end

local function emptyPixel()
  return 0, 0, 0, 0
end

local function reader(bitmap, left, top)
  if not bitmap then return emptyPixel end
  local bytes, stride = bitmap.bytes, bitmap.rowStride
  local width, height = bitmap.width, bitmap.height
  return function(x, y)
    local u, v = x - left, y - top
    if u < 0 or v < 0 or u >= width or v >= height then return 0, 0, 0, 0 end
    local i = v * stride + u * 4 + 1
    return bytes:byte(i, i + 3)
  end
end

local function celReader(cel)
  if not cel then return emptyPixel end
  return reader(cel.image, cel.position.x, cel.position.y)
end

local function sourceTarget(bitmap, selection, saved)
  local bounds = bitmap:shrinkBounds()
  if bounds.width < 1 or bounds.height < 1 then return nil, "The frame has no visible artwork." end
  local sceneRead = reader(bitmap, 0, 0)
  local function read(x, y) return sceneRead(x + bounds.x, y + bounds.y) end
  local selected = celReader(saved)
  local mask, active, focusX, focusY, nearest = {}, {}, 0, 0, math.huge
  for y = 0, bounds.height - 1 do
    for x = 0, bounds.width - 1 do
      local xx, yy = bounds.x + x, bounds.y + y
      local _, _, _, a = read(x, y)
      if a == 255 then
        local i = y * bounds.width + x + 1
        mask[i] = true
        local allowed = not selection or selection:contains(xx, yy)
        if saved then allowed = select(4, selected(xx, yy)) > 0 end
        if allowed then
          active[i] = true
          local distance = math.abs(x - (bounds.width - 1) / 2) + math.abs(y - (bounds.height - 1) / 2)
          if distance < nearest then focusX, focusY, nearest = x, y, distance end
        end
      end
    end
  end
  if not next(active) then return nil, "Choose an area with fully opaque artwork." end
  return {
    x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height, read = read,
    mask = mask, active = active, bitmap = bitmap, focusX = focusX, focusY = focusY,
  }
end

function Native.context(site, useSelection)
  local sprite = site and site.sprite
  if not sprite or sprite.colorMode ~= ColorMode.RGB then return nil, "Lighting requires an RGB sprite." end
  local frame = site.frame
  if type(frame) == "number" then frame = sprite.frames[frame] end
  frame = frame or sprite.frames[1]
  if not frame then return nil, "The lighting frame is missing." end
  local group = groupFor(site, frame)
  local layers = group and Native.layers(group)
  local stored = group and props(group).sceneLightingSettings
  local settings = settingsFor(stored)
  if group then settings.heightLayer = findGuide(sprite, props(group).sceneLightingHeight) end
  local scope = group and layers.scope and layers.scope:cel(frame)
  local selected, saved
  if useSelection == nil then
    if group then
      saved = settings.useSelection and scope or nil
      if settings.useSelection and not saved then return nil, "The saved lighting selection is missing." end
    elseif not sprite.selection.isEmpty then
      selected = sprite.selection
    end
  elseif useSelection then
    if not sprite.selection.isEmpty then selected = sprite.selection
    elseif settings.useSelection and scope then saved = scope
    else return nil, "Make a selection or use the whole sprite." end
  end
  settings.useSelection = selected ~= nil or saved ~= nil
  local bitmap, failure = unlitImage(sprite, frame)
  if not bitmap then return nil, failure end
  local target, message = sourceTarget(bitmap, selected, saved)
  if not target then return nil, message end
  return {
    sprite = sprite, frame = frame, group = group, layers = layers, settings = settings,
    target = target, selection = selected, site = site,
  }
end

local function byte(value)
  return math.floor(math.max(0, math.min(255, value)) + 0.5)
end

local function inputs(context, settings)
  local target = context.target
  local heightLayer = settings.heightMode == "Height Map Layer" and settings.heightLayer or nil
  local heightAt = celReader(heightLayer and heightLayer:cel(context.frame))
  local maskLayer = context.layers and context.layers.mask
  local mask = maskLayer and maskLayer:cel(context.frame)
  local matte = celReader(mask)
  local maskBounds = mask and mask.bounds
  local heights, opacity = {}, {}
  for i in pairs(target.mask) do
    local x, y = (i - 1) % target.width, (i - 1) // target.width
    local xx, yy = target.x + x, target.y + y
    local r, g, b, a = heightAt(xx, yy)
    if a == 0 then r, g, b = target.read(x, y) end
    heights[i] = settings.heightMode == "Flat" and 0.5 or Surface.luminance(r, g, b)
    if target.active[i] then
      if maskBounds and xx >= maskBounds.x and yy >= maskBounds.y
          and xx < maskBounds.x + maskBounds.width and yy < maskBounds.y + maskBounds.height then
        r, g, b, a = matte(xx, yy)
        opacity[i] = Surface.luminance(r, g, b) * a / 255
      else
        opacity[i] = 1
      end
    end
  end
  return heights, opacity
end

local function overlays(context, settings, rect)
  local target = context.target
  local heights, opacity = inputs(context, settings)
  local result = SceneLighting.render(target.width, target.height, heights, settings, target.mask, target.read, rect)
  local fullWidth = target.width
  for _, stage in ipairs(stages) do
    local layer = result[stage.id]
    for i, pixel in pairs(layer) do
      local x, y = rect.x + (i - 1) % rect.width, rect.y + (i - 1) // rect.width
      local a = byte(((pixel >> 24) & 255) * (opacity[y * fullWidth + x + 1] or 0))
      layer[i] = a > 0 and (pixel & 0x00ffffff) | (a << 24) or nil
    end
  end
  return result
end

local function fullArea(target)
  return Rectangle(0, 0, target.width, target.height)
end

local function bitmapFor(sprite, packed, rect, canvas)
  local result = canvas and image(sprite) or image(sprite, rect.width, rect.height)
  local left, top = canvas and rect.x or 0, canvas and rect.y or 0
  for i, pixel in pairs(packed) do
    result:putPixel(left + (i - 1) % rect.width, top + (i - 1) // rect.width, pixel)
  end
  return result
end

function Native.preview(context, settings, rect, channel)
  local target = context.target
  rect = rect or fullArea(target)
  local current = settingsFor(settings, context.settings)
  if channel == "AO" then channel = Lighting.aoChannel end
  if channel == "Height Map" or channel == "Mask" or Lighting.isMap(channel) then
    local heights, opacity = inputs(context, current)
    local map
    if Lighting.isMap(channel) then
      map = SceneLighting.map(target.width, target.height, heights, current, target.mask, target.read, rect, channel)
    end
    local result = image(context.sprite, rect.width, rect.height)
    local rgba = app.pixelColor.rgba
    for y = 0, rect.height - 1 do
      for x = 0, rect.width - 1 do
        local i = (rect.y + y) * target.width + rect.x + x + 1
        if target.active[i] then
          local value
          if map then value = 1 - map[y * rect.width + x + 1]
          elseif channel == "Mask" then value = opacity[i]
          else value = heights[i] end
          local gray = byte((value or 0) * 255)
          result:putPixel(x, y, rgba(gray, gray, gray, 255))
        end
      end
    end
    return result
  end

  local original = Image(target.bitmap, Rectangle(target.x + rect.x, target.y + rect.y, rect.width, rect.height))
  if channel == "Original" then return original end
  local result = overlays(context, current, rect)
  local combined = image(context.sprite, rect.width, rect.height)
  for _, stage in ipairs(stages) do
    local layer = context.layers and context.layers[stage.id]
    if not layer or layer.isVisible then
      local cel = layer and layer:cel(context.frame)
      local opacity = layer and ((layer.opacity or 255) * (cel and cel.opacity or 255) + 127) // 255 or 255
      combined:drawImage(bitmapFor(context.sprite, result[stage.id], rect), Point(0, 0), opacity,
        layer and layer.blendMode or BlendMode.NORMAL)
    end
  end
  local group = context.group
  original:drawImage(combined, Point(0, 0), group and group.opacity or 255, group and group.blendMode or BlendMode.NORMAL)
  return original
end

local function named(sprite, parent, role, name, group)
  local layer = group and sprite:newGroup() or sprite:newLayer()
  layer.parent, layer.name = parent, name
  props(layer).sceneLightingRole = role
  return layer
end

local function setPixels(context, layer, newImage, live)
  local cel = layer:cel(context.frame)
  if not cel then
    context.sprite:newCel(layer, context.frame, newImage, Point(0, 0))
    return true
  end
  local current, position = cel.image, cel.position
  local same = current.width == newImage.width and current.height == newImage.height and position.x == 0 and position.y == 0
  if same and current.bytes == newImage.bytes then return false end
  if live and same then
    current.bytes = newImage.bytes
  else
    cel.image, cel.position = newImage, Point(0, 0)
  end
  return true
end

local function sync(context, settings, live)
  local target = context.target
  local result = target and overlays(context, settings, fullArea(target))
  local changed = false
  for _, stage in ipairs(stages) do
    local layer = context.layers[stage.id]
    if layer then
      local bitmap = result and bitmapFor(context.sprite, result[stage.id],
        Rectangle(target.x, target.y, target.width, target.height), true) or image(context.sprite)
      if setPixels(context, layer, bitmap, live) then changed = true end
    end
  end
  return changed
end

local function forLightingFrames(sprite, group, layers, visit)
  if layers.scope and #layers.scope.cels > 0 then
    for _, cel in ipairs(layers.scope.cels) do visit(cel.frame) end
  else
    local frame = sprite.frames[props(group).sceneLightingFrame or 1]
    if frame then visit(frame) end
  end
end

local function scopeImage(sprite, selection)
  local bitmap = image(sprite)
  if not selection then
    bitmap:clear(0xffffffff)
  else
    local bounds = selection.bounds
    for y = math.max(0, bounds.y), math.min(sprite.height, bounds.y + bounds.height) - 1 do
      for x = math.max(0, bounds.x), math.min(sprite.width, bounds.x + bounds.width) - 1 do
        if selection:contains(x, y) then bitmap:putPixel(x, y, 0xffffffff) end
      end
    end
  end
  return bitmap
end

function Native.apply(context, settings)
  if not context or not context.target then return nil, "Choose a visible RGB frame." end
  settings = settings or {}
  local current = settingsFor(settings, context.settings)
  if current.useSelection ~= context.settings.useSelection then
    local updated, message = Native.context(context.site, current.useSelection)
    if not updated then return nil, message end
    context = updated
  end
  local sprite, group, frame = context.sprite, context.group, context.frame
  local height = current.heightMode == "Height Map Layer" and current.heightLayer or nil
  if current.heightMode == "Height Map Layer" and (not isGuide(height, sprite) or not height:cel(frame)) then
    return nil, "Choose a separate height map with pixels in this frame."
  end
  local oldSelection = group and props(group).sceneLightingSettings and props(group).sceneLightingSettings.useSelection
  app.transaction(group and "Update Scene Lighting" or "Create Scene Lighting", function()
    if not group then
      group = sprite:newGroup()
      group.name = "Scene Lighting"
      local data = props(group)
      data.sceneLightingVersion, data.sceneLightingFrame = version, frame.frameNumber
      local parts = {}
      for _, stage in ipairs(stages) do
        parts[stage.id] = named(sprite, group, stage.id, stage.name)
        parts[stage.id].isEditable = false
        parts[stage.id].isContinuous = false
      end
      parts.inputs = named(sprite, group, "inputs", "Lighting inputs", true)
      parts.inputs.isVisible, parts.inputs.isCollapsed = false, true
      parts.scope = named(sprite, parts.inputs, "scope", "Lighting scope")
      parts.scope.isVisible, parts.scope.isEditable = false, false
      parts.mask = named(sprite, parts.inputs, "mask", "Lighting mask")
      sprite:newCel(parts.mask, frame, scopeImage(sprite), Point(0, 0))
      context.group, context.layers = group, parts
    end
    if not context.layers.scope:cel(frame) or context.selection or oldSelection ~= current.useSelection then
      setPixels(context, context.layers.scope, scopeImage(sprite, context.selection), false)
    end
    local data = props(group)
    local stored = settingsFor(current)
    stored.heightLayer = nil
    data.sceneLightingSettings = stored
    data.sceneLightingHeight = rememberGuide(height)
    context.layers.inputs.isVisible = false
    if group.parent ~= sprite then group.parent = sprite end
    group.stackIndex = #sprite.layers
    group.isVisible = true
    sync(context, current, false)
    forLightingFrames(sprite, group, context.layers, function(otherFrame)
      if otherFrame ~= frame then
        local other = Native.context{ sprite = sprite, frame = otherFrame, layer = group }
        sync(other or { sprite = sprite, frame = otherFrame, layers = context.layers }, current, false)
      end
    end)
  end)
  context.settings = current
  if app.sprite == sprite then app.layer = group end
  app.refresh()
  return group
end

function Native.refresh(sprite, group)
  if not isGroup(group) then return false end
  local layers = Native.layers(group)
  local changed = false
  forLightingFrames(sprite, group, layers, function(frame)
    local context = Native.context{ sprite = sprite, layer = group, frame = frame }
    local updated
    if context then updated = sync(context, context.settings, true)
    else updated = sync({ sprite = sprite, frame = frame, layers = layers }, defaults, true) end
    if updated then changed = true end
  end)
  return changed
end

function Native.editMask(group)
  local parts = Native.layers(group)
  if not parts or not parts.mask then return nil, "Apply the lighting to create its mask." end
  parts.inputs.isVisible, parts.inputs.isCollapsed, parts.mask.isVisible = true, false, true
  if app.sprite == group.sprite then app.layer = parts.mask end
  app.refresh()
  return parts.mask
end

function Native.showResult(group)
  local parts = Native.layers(group)
  if not parts or not parts.inputs then return nil, "Select a Scene Lighting group." end
  parts.inputs.isVisible = false
  Native.refresh(group.sprite, group)
  if app.sprite == group.sprite then app.layer = group end
  app.refresh()
  return group
end

return Native
