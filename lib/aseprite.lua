local Surface = require("lib.surface")
local Material = require("lib.material")
local Deposits = require("lib.deposits")
local Lighting = require("lib.lighting")
local Aseprite = {}

function Aseprite.rgba(color)
  return { r = color.red, g = color.green, b = color.blue, a = color.alpha }
end

function Aseprite.color(rgba)
  return Color{ r = rgba.r, g = rgba.g, b = rgba.b, a = rgba.a }
end

local function colorKey(color)
  return string.char(color.r, color.g, color.b, color.a)
end

local function paletteAt(sprite, frame)
  local number = frame and frame.frameNumber or 1
  local palettes = sprite.palettes
  local result
  for i = 1, #palettes do
    local palette = palettes[i]
    if palette.frameNumber > number then break end
    result = palette
  end
  return result
end

function Aseprite.addRamp(sprite, colors, frame)
  local original = paletteAt(sprite, frame)
  local count = original and #original or 0
  local indexed = sprite.colorMode == ColorMode.INDEXED
  local seen = {}
  for i = 0, count - 1 do
    if not indexed or i ~= sprite.transparentColor then
      seen[colorKey(Aseprite.rgba(original:getColor(i)))] = true
    end
  end

  local additions = {}
  for _, color in ipairs(colors) do
    local key = colorKey(color)
    if not seen[key] then
      additions[#additions + 1] = color
      seen[key] = true
    end
  end

  if #additions == 0 then return 0 end
  if indexed and count + #additions > 256 then
    return nil, "There are not enough free entries in the indexed palette."
  end

  app.transaction("Add Pixel Art Color Ramp", function()
    local palette = original or Palette(#additions)
    palette:resize(count + #additions)
    for i, color in ipairs(additions) do
      palette:setColor(count + i - 1, Aseprite.color(color))
    end
    if not original then sprite:setPalette(palette) end
  end)
  app.refresh()
  return #additions
end

local function overlap(a, b)
  local x, y = math.max(a.x, b.x), math.max(a.y, b.y)
  return {
    x = x, y = y,
    width = math.min(a.x + a.width, b.x + b.width) - x,
    height = math.min(a.y + a.height, b.y + b.height) - y,
  }
end

local function pixelReader(site)
  local layer, cel, sprite = site.layer, site.cel, site.sprite
  if not layer or layer.isGroup or layer.isTilemap or not cel then return nil end

  local image, bounds = cel.image, cel.bounds
  local px = app.pixelColor
  local read
  if sprite.colorMode == ColorMode.INDEXED then
    local palette, transparent = paletteAt(sprite, site.frame), sprite.transparentColor
    local colors = {}
    for index = 0, #palette - 1 do
      if layer.isBackground or index ~= transparent then
        local c = Aseprite.rgba(palette:getColor(index))
        if layer.isBackground then c.a = 255 end
        colors[index] = c
      end
    end
    read = function(pixel)
      local c = colors[pixel]
      if c then return c.r, c.g, c.b, c.a end
      return 0, 0, 0, 0
    end
  elseif sprite.colorMode == ColorMode.GRAY then
    read = function(pixel)
      local v = px.grayaV(pixel)
      return v, v, v, px.grayaA(pixel)
    end
  else
    read = function(pixel)
      return px.rgbaR(pixel), px.rgbaG(pixel), px.rgbaB(pixel), px.rgbaA(pixel)
    end
  end

  return function(x, y)
    local u, v = x - bounds.x, y - bounds.y
    if u >= 0 and v >= 0 and u < bounds.width and v < bounds.height then
      return read(image:getPixel(u, v))
    end
    return 0, 0, 0, 0
  end, bounds
end

function Aseprite.textureTarget(site, scope)
  local sprite = site.sprite
  local selection = sprite.selection
  local useSelection = scope ~= "Layer Pixels" and not selection.isEmpty
  local read, celBounds = pixelReader(site)
  local useLayer = scope ~= "Selection" and read ~= nil

  if scope == "Selection" and not useSelection then
    return nil, "Make a selection to use this target."
  end
  if not useSelection and not useLayer then
    return nil, "Select pixels or choose a raster cel with visible pixels."
  end

  local area = { x = 0, y = 0, width = sprite.width, height = sprite.height }
  if useSelection then area = overlap(area, selection.bounds) end
  if useLayer then area = overlap(area, celBounds) end
  if area.width < 1 or area.height < 1 then
    return nil, "The target does not overlap the sprite."
  end

  local minX, minY = area.x + area.width, area.y + area.height
  local maxX, maxY = area.x - 1, area.y - 1
  local count, rows = 0, {}
  local centerX, centerY = area.x + (area.width - 1) / 2, area.y + (area.height - 1) / 2
  local focusX, focusY, focusDistance = 0, 0, math.huge
  for y = area.y, area.y + area.height - 1 do
    local row = {}
    for x = area.x, area.x + area.width - 1 do
      local alpha = 255
      if useSelection and not selection:contains(x, y) then
        alpha = 0
      elseif useLayer then
        local _, _, _, sourceAlpha = read(x, y)
        alpha = sourceAlpha
      end
      row[#row + 1] = string.char(alpha)
      if alpha > 0 then
        count = count + 1
        minX, minY = math.min(minX, x), math.min(minY, y)
        maxX, maxY = math.max(maxX, x), math.max(maxY, y)
        local distance = math.abs(x - centerX) + math.abs(y - centerY)
        if distance < focusDistance then focusX, focusY, focusDistance = x, y, distance end
      end
    end
    rows[y - area.y + 1] = table.concat(row)
  end
  if count == 0 then return nil, "The target has no visible pixels." end

  local width, height = maxX - minX + 1, maxY - minY + 1
  local function alphaAt(x, y)
    return rows[y + minY - area.y + 1]:byte(x + minX - area.x + 1)
  end
  local mask
  if count < width * height then
    -- Keep one byte per pixel. The pure generator only reads truthiness from mask[i].
    mask = setmetatable({}, { __index = function(_, index)
      local x, y = (index - 1) % width, (index - 1) // width
      if y < 0 or y >= height then return false end
      return alphaAt(x, y) > 0
    end })
  end

  return { x = minX, y = minY, width = width, height = height,
           focusX = focusX - minX, focusY = focusY - minY,
           mask = mask, alphaAt = alphaAt, read = read, site = site }
end

local function paletteColors(sprite, frame)
  local palette, transparent = paletteAt(sprite, frame), sprite.transparentColor
  local colors = {}
  for index = 0, #palette - 1 do
    if index ~= transparent then
      local c = Aseprite.rgba(palette:getColor(index))
      if c.a > 0 then
        colors[#colors + 1] = { index = index, color = c }
      end
    end
  end
  return colors
end

local function nearestPaletteColor(colors, r, g, b, alpha)
  local best, distance = nil, math.huge
  for _, entry in ipairs(colors) do
    local c = entry.color
    local dr, dg, db, da = c.r - r, c.g - g, c.b - b, c.a - alpha
    local score = 2 * dr * dr + 4 * dg * dg + 3 * db * db + da * da
    if score < distance then
      best, distance = entry, score
    end
  end
  return best
end

local function grayByte(r, g, b)
  return (2126 * r + 7152 * g + 722 * b + 5000) // 10000
end

function Aseprite.rgbPainter(site)
  local mode, px = site.sprite.colorMode, app.pixelColor
  if mode == ColorMode.GRAY then
    return function(r, g, b, a)
      local value = grayByte(r, g, b)
      return px.graya(value, a), value, value, value, a
    end
  end
  if mode == ColorMode.INDEXED then
    local colors = paletteColors(site.sprite, site.frame)
    if #colors == 0 then return nil, "The indexed palette has no visible colors." end
    local matches = {}
    return function(r, g, b, a)
      local key = px.rgba(r, g, b, a)
      local match = matches[key]
      if not match then
        match = nearestPaletteColor(colors, r, g, b, a)
        matches[key] = match
      end
      local c = match.color
      return match.index, c.r, c.g, c.b, c.a
    end
  end
  return function(r, g, b, a) return px.rgba(r, g, b, a), r, g, b, a end
end

function Aseprite.texturePaint(sprite, colors, frame)
  local mode, px = sprite.colorMode, app.pixelColor
  local indexed = mode == ColorMode.INDEXED and paletteColors(sprite, frame)
  local paint = {}
  for i, color in ipairs(colors) do
    if color.a == 0 then
      paint[i] = { transparent = true }
    elseif indexed then
      local choice = nearestPaletteColor(indexed, color.r, color.g, color.b, color.a)
      if not choice then return nil, "The indexed palette has no visible colors." end
      paint[i] = choice
    elseif mode == ColorMode.GRAY then
      local gray = grayByte(color.r, color.g, color.b)
      paint[i] = { color = { r = gray, g = gray, b = gray, a = color.a } }
    else
      paint[i] = { color = color }
    end
  end

  return function(level, coverage)
    local entry = paint[level]
    if not entry or entry.transparent then return nil end
    local c = entry.color
    if mode == ColorMode.INDEXED then return entry.index, c.r, c.g, c.b, c.a end
    local alpha = (c.a * coverage + 127) // 255
    if alpha == 0 then return nil end
    local pixel = mode == ColorMode.GRAY and px.graya(c.r, alpha)
                  or px.rgba(c.r, c.g, c.b, alpha)
    return pixel, c.r, c.g, c.b, alpha
  end
end

local function depositPainter(sprite, style, colors, frame, shade)
  local paint, message = Aseprite.rgbPainter{ sprite = sprite, frame = frame }
  if not paint then return nil, message end
  local indexed = sprite.colorMode == ColorMode.INDEXED
  local samples, swatchFor = {}, Deposits.sampler(style, colors)
  return function(sample, coverage, underR, underG, underB, x, y)
    if sample == 0 or coverage == 0 then return nil end
    local swatch = samples[sample]
    if not swatch then
      local r, g, b, a = swatchFor(sample)
      if not r then return nil end
      swatch = { r, g, b, a }
      samples[sample] = swatch
    end
    local r, g, b = swatch[1], swatch[2], swatch[3]
    local alpha = (swatch[4] * coverage + 127) // 255
    if alpha == 0 then return nil end
    if shade and underR then
      r, g, b = shade(r, g, b, underR, underG, underB, alpha / 255, x, y)
    end
    if indexed and underR then
      -- Indexed overlays cannot store different alpha per pixel.
      r = (r * alpha + underR * (255 - alpha) + 127) // 255
      g = (g * alpha + underG * (255 - alpha) + 127) // 255
      b = (b * alpha + underB * (255 - alpha) + 127) // 255
      local pixel, pr, pg, pb, pa = paint(r, g, b, 255)
      if pr == underR and pg == underG and pb == underB then return nil end
      return pixel, pr, pg, pb, pa
    end
    return paint(r, g, b, alpha)
  end
end

function Aseprite.softDepositPaint(sprite, style, colors, frame)
  return depositPainter(sprite, style, colors, frame)
end

function Aseprite.rustPaint(sprite, colors, frame)
  return Aseprite.softDepositPaint(sprite, "Rust", colors, frame)
end

function Aseprite.depositPaint(target, settings)
  local site, style, colors = target.site, settings.style, settings.colors
  local matching = tonumber(settings.lighting) or Lighting.defaultMatch
  local function read(x, y)
    return target.read(target.x + x, target.y + y)
  end
  local shade
  if matching > 0 and target.read then
    local context = Lighting.sampler(target.width, target.height, read, target.mask, settings.seamless)
    shade = function(r, g, b, baseR, baseG, baseB, opacity, x, y)
      return Lighting.tint(r, g, b, baseR, baseG, baseB, opacity, context(x, y), matching)
    end
  end
  if not shade and not Deposits.controls(style) then
    local legacy, message = Aseprite.texturePaint(site.sprite, colors, site.frame)
    if not legacy then return nil, message end
    return function(sample, _x, _y, coverage) return legacy(sample, coverage) end
  end

  local paint, message = depositPainter(site.sprite, style, colors, site.frame, shade)
  if not paint then return nil, message end
  local readUnderlay = target.read and (shade or site.sprite.colorMode == ColorMode.INDEXED)
  return function(sample, x, y, coverage)
    if readUnderlay then
      local r, g, b, a = read(x, y)
      if a > 0 then return paint(sample, coverage, r, g, b, x, y) end
    end
    return paint(sample, coverage)
  end
end

function Aseprite.materialPaint(target, settings)
  local paint, message = Aseprite.rgbPainter(target.site)
  if not paint then return nil, message end
  local shade = Material.shader(settings)
  local baseR, baseG, baseB = Material.baseColor(settings.style)
  return function(sample, x, y, coverage)
    if sample == 0 then return nil end
    coverage = coverage or target.alphaAt(x, y)
    if coverage == 0 then return nil end

    local r, g, b, sourceAlpha
    if target.read then r, g, b, sourceAlpha = target.read(target.x + x, target.y + y) end
    local hasSource = sourceAlpha ~= nil and sourceAlpha > 0
    if hasSource then
      coverage = math.min(coverage, sourceAlpha)
    else
      r, g, b = baseR, baseG, baseB
    end
    local outR, outG, outB = shade(r, g, b, sample)
    local pixel, paintR, paintG, paintB, paintA = paint(outR, outG, outB, coverage)
    if hasSource and paintR == r and paintG == g and paintB == b and paintA == sourceAlpha then return nil end
    return pixel, paintR, paintG, paintB, paintA
  end
end

function Aseprite.heightSamples(target, sourceLayer, options, clipToTarget)
  local read = target.read
  if sourceLayer then
    read = pixelReader{
      sprite = target.site.sprite, frame = target.site.frame,
      layer = sourceLayer, cel = sourceLayer:cel(target.site.frame),
    }
  end
  if not read then return {}, 0 end

  return Surface.build(target.width, target.height, function(x, y)
    if clipToTarget and target.alphaAt(x, y) == 0 then return end
    return read(target.x + x, target.y + y)
  end, options)
end

function Aseprite.newTextureImage(target)
  local sprite = target.site.sprite
  return Image(ImageSpec{
    width = target.width, height = target.height, colorMode = sprite.colorMode,
    transparentColor = sprite.transparentColor, colorSpace = sprite.colorSpace,
  })
end

local function heightPixels(site)
  local mode, px = site.sprite.colorMode, app.pixelColor
  if mode ~= ColorMode.INDEXED then
    return function(value)
      local gray = math.floor(value * 255 + 0.5)
      local pixel = mode == ColorMode.GRAY and px.graya(gray, 255) or px.rgba(gray, gray, gray, 255)
      return pixel, gray
    end
  end

  local palette, transparent = paletteAt(site.sprite, site.frame), site.sprite.transparentColor
  local shades = {}
  for index = 0, #palette - 1 do
    local c = Aseprite.rgba(palette:getColor(index))
    if index ~= transparent and c.a > 0 then
      local height = Surface.luminance(c.r, c.g, c.b)
      local chroma = math.max(c.r, c.g, c.b) - math.min(c.r, c.g, c.b)
      shades[#shades + 1] = { index = index, height = height, chroma = chroma }
    end
  end
  if #shades == 0 then return nil, "The indexed palette has no visible colors." end

  local lookup = {}
  return function(value)
    local gray = math.floor(value * 255 + 0.5)
    local best = lookup[gray]
    if not best then
      local distance = math.huge
      for _, shade in ipairs(shades) do
        local candidate = math.abs(shade.height * 255 - gray)
        if candidate < distance or (candidate == distance and shade.chroma < best.chroma) then
          best, distance = shade, candidate
        end
      end
      lookup[gray] = best
    end
    return best.index, math.floor(best.height * 255 + 0.5)
  end
end

local function renderHeightMap(target, heights, rect, image, isPreview)
  local paint, message = heightPixels(target.site)
  if not paint then return nil, message end
  local rgba = app.pixelColor.rgba
  for y = 0, rect.height - 1 do
    for x = 0, rect.width - 1 do
      local value = heights[(rect.y + y) * target.width + rect.x + x + 1]
      if value ~= nil then
        local pixel, gray = paint(value)
        image:drawPixel(x, y, isPreview and rgba(gray, gray, gray, 255) or pixel)
      end
    end
  end
  return image
end

function Aseprite.heightMapImage(target, heights)
  local rect = { x = 0, y = 0, width = target.width, height = target.height }
  return renderHeightMap(target, heights, rect, Aseprite.newTextureImage(target), false)
end

function Aseprite.heightMapPreview(target, heights, rect)
  return renderHeightMap(target, heights, rect, Image(rect.width, rect.height, ColorMode.RGB), true)
end

local function addLayer(target, image, action, name, visible)
  local site = target.site
  local layer
  app.transaction(action, function()
    layer = site.sprite:newLayer()
    layer.name = name
    if site.layer then
      layer.parent = site.layer.parent
      layer.stackIndex = site.layer.stackIndex + 1
    end
    site.sprite:newCel(layer, site.frame, image, Point(target.x, target.y))
    layer.isVisible = visible
  end)
  app.layer = visible and layer or site.layer
  app.refresh()
  return layer
end

function Aseprite.addTextureLayer(target, image, style)
  return addLayer(target, image, "Add " .. style .. " Texture", "Texture - " .. style, true)
end

function Aseprite.addHeightMapLayer(target, image)
  local name = target.site.layer and "Height Map - " .. target.site.layer.name or "Height Map"
  return addLayer(target, image, "Create Height Map", name, false)
end

function Aseprite.addMaterialGroup(target, images, name, liveGroup)
  local site, group = target.site
  app.transaction("Bake Material Layers", function()
    group = site.sprite:newGroup()
    group.name = name
    group.properties("substanceprite/substanceprite").materialBake = true
    if site.layer then
      group.parent = site.layer.parent
      group.stackIndex = (liveGroup or site.layer).stackIndex + 1
      if liveGroup then
        liveGroup.isVisible = false
        site.layer.isVisible = true
      end
    end
    for _, item in ipairs(images) do
      local layer = site.sprite:newLayer()
      layer.name = item.name
      layer.parent = group
      site.sprite:newCel(layer, site.frame, item.image, Point(target.x, target.y))
    end
  end)
  app.refresh()
  return group
end

return Aseprite
