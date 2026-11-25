local source = debug.getinfo(1, "S").source
local testsDirectory = source:sub(2):match("^(.*[/\\])") or ""
package.path = testsDirectory .. "../?.lua;" .. package.path

local Aseprite = require("lib.aseprite")
local Material = require("lib.material")

local function equal(actual, expected, context)
  assert(actual == expected, string.format("%s: expected %s, got %s",
    context, tostring(expected), tostring(actual)))
end

local function rgba(r, g, b, a)
  return {r = r, g = g, b = b, a = a or 255}
end

local function paletteFrom(colors)
  local palette = Palette(#colors)
  for i, value in ipairs(colors) do palette:setColor(i - 1, Aseprite.color(value)) end
  return palette
end

local function checkPalette()
  local sprite = Sprite(8, 8, ColorMode.RGB)
  local existing = rgba(79, 120, 89)
  local accent = rgba(212, 102, 67)
  local highlight = rgba(234, 211, 160)
  sprite:setPalette(paletteFrom({rgba(23, 28, 32), existing}))
  local ramp = {existing, accent, highlight, accent}
  equal(Aseprite.addRamp(sprite, ramp), 2, "unique additions")
  equal(#sprite.palettes[1], 4, "new palette size")
  equal(sprite.palettes[1]:getColor(2).red, accent.r, "accent was appended")
  equal(sprite.palettes[1]:getColor(3).red, highlight.r, "highlight was appended")
  equal(Aseprite.addRamp(sprite, ramp), 0, "adding the same ramp is a no-op")
  app.undo()
  equal(#sprite.palettes[1], 2, "one undo reverted the palette change")
  equal(sprite.palettes[1]:getColor(1).green, existing.g, "original palette entry after undo")
  sprite:close()
  print("PASS palette append, de-duplication and Undo")
end

local function checkIndexedTexture()
  local sprite = Sprite(13, 12, ColorMode.INDEXED)
  sprite.transparentColor = 3
  local colors = {
    rgba(22, 28, 33), rgba(125, 40, 22), rgba(150, 65, 60),
    rgba(200, 150, 130), rgba(215, 155, 140), rgba(80, 120, 80),
  }
  sprite:setPalette(paletteFrom(colors))
  local parent = sprite:newGroup()
  local lower = sprite:newLayer()
  lower.parent = parent
  local sourceLayer = sprite:newLayer()
  sourceLayer.parent = parent
  local upper = sprite:newLayer()
  upper.parent = parent

  local frame = sprite:newEmptyFrame(2)
  local sourceImage = Image(ImageSpec{
    width = 5, height = 4, colorMode = ColorMode.INDEXED, transparentColor = 3,
  })
  sourceImage:clear()
  for y = 1, 3 do
    for x = 1, 3 do
      if x ~= 2 or y ~= 2 then sourceImage:drawPixel(x, y, 1) end
    end
  end
  local sourceCel = sprite:newCel(sourceLayer, frame, sourceImage, Point(3, 5))
  local original = sourceCel.image.bytes
  app.layer = sourceLayer
  app.frame = frame
  sprite.selection:select(Rectangle(4, 7, 3, 2))
  local site = app.site
  local selection = assert(Aseprite.textureTarget(site, "Selection"))
  local shape = assert(Aseprite.textureTarget(site, "Layer Pixels"))
  local intersection = assert(Aseprite.textureTarget(site, "Auto"))
  equal(selection.alphaAt(1, 0), 255, "Selection includes transparent pixels")
  equal(shape.x, 4, "trimmed shape left edge")
  equal(shape.y, 6, "trimmed shape top edge")
  equal(shape.width, 3, "trimmed shape width")
  equal(shape.height, 3, "trimmed shape height")
  equal(shape.alphaAt(1, 1), 0, "transparent color index is outside the shape")
  equal(intersection.y, 7, "Auto respects selection bounds")
  equal(intersection.alphaAt(1, 0), 0, "Auto respects the transparent pixel")

  local paint = assert(Aseprite.texturePaint(sprite, {colors[2], colors[3], colors[4]}))
  equal(paint(3, 255), 4, "quantization skips the transparent color index")
  local result = Aseprite.newTextureImage(shape)
  for y = 0, shape.height - 1 do
    for x = 0, shape.width - 1 do
      if shape.alphaAt(x, y) > 0 then result:drawPixel(x, y, paint(3, 255)) end
    end
  end
  equal(result:getPixel(1, 1), 3, "unfilled effect pixels use the sprite transparency index")
  Aseprite.addTextureLayer(shape, result, "Rust")

  local children = parent.layers
  equal(#children, 4, "texture layer belongs to the source group")
  equal(children[1], lower, "lower sibling remains in place")
  equal(children[2], sourceLayer, "source layer remains below the effect")
  equal(children[4], upper, "upper sibling is still above the effect")
  local texture = children[3]
  equal(texture.name, "Texture - Rust", "effect layer name")
  equal(texture:cel(1), nil, "no cel was added to the first frame")
  local effectCel = assert(texture:cel(frame))
  equal(effectCel.position.x, 4, "effect cel x offset")
  equal(effectCel.position.y, 6, "effect cel y offset")
  equal(effectCel.image:getPixel(1, 1), 3, "the effect cel preserves a hole")
  equal(effectCel.image:getPixel(0, 0), 4, "effect uses the nearest visible color")
  equal(sourceCel.image.bytes, original, "source pixels were untouched")

  app.undo()
  equal(#parent.layers, 3, "one undo removed the effect layer and cel")
  equal(parent.layers[3], upper, "layer order after undo")
  equal(sourceLayer:cel(frame).image.bytes, original, "source pixels after undo")
  sprite:close()
  print("PASS indexed transparency, selection, group placement, cel offset and Undo")
end

local function checkFramePalettes()
  -- Both frames have identical indexed pixels. Their blue and orange entries swap indices.
  local path = app.fs.joinPath(testsDirectory, "fixtures", "indexed-frame-palettes.aseprite")
  local sprite = assert(app.open(path))
  app.layer = sprite.layers[1]
  local orange = rgba(225, 102, 54)
  for i = 1, 2 do
    local frame = sprite.frames[i]
    app.frame = frame
    local target = assert(Aseprite.textureTarget(app.site, "Layer Pixels"))
    local r = target.read(0, 0)
    equal(r, i == 1 and 35 or 225, "source pixel uses the frame palette")
    local paint = assert(Aseprite.texturePaint(sprite, {orange}, frame))
    equal(paint(1, 255), i == 1 and 2 or 1, "effect maps to the frame palette")
  end

  local accent = rgba(210, 188, 99)
  equal(Aseprite.addRamp(sprite, {orange, accent}, app.frame), 1, "new color in the second palette")
  equal(#sprite.palettes[1], 4, "first palette is unchanged")
  equal(#sprite.palettes[2], 5, "second palette has one new entry")
  equal(sprite.palettes[2]:getColor(4).red, accent.r, "accent is in the second palette")
  app.undo()
  equal(#sprite.palettes[2], 4, "one undo restores the second palette")
  sprite:close()
  print("PASS per-frame indexed palettes")
end

local function checkAlpha()
  local color = rgba(120, 180, 60, 230)
  for _, mode in ipairs({ColorMode.RGB, ColorMode.GRAY}) do
    local sprite = Sprite(4, 4, mode)
    local paint = assert(Aseprite.texturePaint(sprite, {color, rgba(0, 0, 0, 0)}))
    local pixel, r, g, b, a = paint(1, 127)
    equal(a, 115, "partial source coverage scales the effect alpha")
    if mode == ColorMode.RGB then
      equal(app.pixelColor.rgbaA(pixel), a, "RGB alpha is encoded in the pixel")
      equal(r, 120, "RGB red channel")
    else
      equal(app.pixelColor.grayaA(pixel), a, "grayscale alpha is encoded in the pixel")
      equal(r, g, "grayscale red and green channels")
      equal(g, b, "grayscale green and blue channels")
    end
    equal(paint(2, 255), nil, "transparent brush color skips the pixel")
    sprite:close()
  end
  print("PASS RGB and grayscale coverage")
end

local function checkHeightMap()
  local sprite = Sprite(14, 12, ColorMode.RGB)
  local sourceLayer = sprite.layers[1]
  local sourceImage = Image(5, 4, ColorMode.RGB)
  for y = 0, 3 do
    for x = 0, 4 do
      local height = x < 3 and 35 or 220
      local alpha = 255
      if x == 2 and y == 2 then alpha = 0 end
      sourceImage:drawPixel(x, y, app.pixelColor.rgba(height, height, height, alpha))
    end
  end

  local frame = sprite:newEmptyFrame(2)
  local sourceCel = sprite:newCel(sourceLayer, frame, sourceImage, Point(3, 4))
  local before = sourceCel.image.bytes
  app.layer = sourceLayer
  app.frame = frame
  sprite.selection:select(Rectangle(4, 5, 3, 3))
  local target = assert(Aseprite.textureTarget(app.site, "Auto"))
  local heights, count = Aseprite.heightSamples(target, nil, {channel = "Luminance"}, true)
  equal(target.x, 4, "height field starts at the selection x")
  equal(target.y, 5, "height field starts at the selection y")
  equal(target.width, 3, "height field width")
  equal(target.height, 3, "height field height")
  equal(count, 8, "height field omits a hole in the art")
  equal(heights[5], nil, "height remains missing at a transparent pixel")

  local image = assert(Aseprite.heightMapImage(target, heights))
  local layer = assert(Aseprite.addHeightMapLayer(target, image))
  equal(app.layer, sourceLayer, "creating a map preserves the active artwork layer")
  equal(layer.isVisible, false, "map overlay starts hidden")
  equal(layer:cel(1), nil, "the map is written only in the active frame")
  equal(sprite.layers[2], layer, "the map is immediately above the original")
  local mapCel = assert(layer:cel(frame))
  equal(mapCel.position, Point(4, 5), "map position is aligned to the original pixels")
  equal(app.pixelColor.rgbaR(mapCel.image:getPixel(0, 0)), 35, "low map value")
  equal(app.pixelColor.rgbaR(mapCel.image:getPixel(2, 0)), 220, "high map value")
  equal(app.pixelColor.rgbaA(mapCel.image:getPixel(1, 1)), 0, "map image preserves a hole")

  local reread, rereadCount = Aseprite.heightSamples(target, layer, {
    channel = "Luminance", invert = true,
  }, false)
  equal(rereadCount, 8, "the hidden map is readable at the same coordinates")
  assert(math.abs(reread[1] + heights[1] - 1) < 1e-8, "reading the hidden map did not invert it")
  equal(reread[5], nil, "the map reader preserved missing height data")
  equal(sourceLayer:cel(frame).image.bytes, before, "height extraction preserves source bytes")
  app.undo()
  equal(#sprite.layers, 1, "one undo removes the map and its cel")
  equal(sourceLayer:cel(frame).image.bytes, before, "map undo preserves source bytes")
  sprite:close()
  print("PASS editable height map, alignment, hidden map sampling and Undo")
end

local function checkHeightMapColorModes()
  local sprite = Sprite(6, 6, ColorMode.INDEXED)
  sprite.transparentColor = 3
  local colors = {rgba(16, 16, 16), rgba(246, 246, 246), rgba(97, 97, 97), rgba(109, 109, 109)}
  sprite:setPalette(paletteFrom(colors))
  sprite.selection:select(Rectangle(1, 1, 3, 2))
  local target = assert(Aseprite.textureTarget(app.site, "Selection"))
  local heights = {[1] = 109 / 255, [6] = 1}
  local indexed = assert(Aseprite.heightMapImage(target, heights))
  equal(indexed:getPixel(0, 0), 2, "quantized height skips the closest transparent index")
  equal(indexed:getPixel(1, 0), 3, "missing heights use the actual transparency index")
  equal(indexed:getPixel(2, 1), 1, "the highest value finds the brightest indexed shade")
  local preview = assert(Aseprite.heightMapPreview(target, heights,
    {x = 0, y = 0, width = 2, height = 1}))
  equal(app.pixelColor.rgbaR(preview:getPixel(0, 0)), 97, "indexed preview shows the quantized height")
  equal(app.pixelColor.rgbaA(preview:getPixel(1, 0)), 0, "indexed preview preserves holes")
  equal(#sprite.palettes[1], #colors, "height quantization preserves palette size")
  equal(sprite.palettes[1]:getColor(3).red, 109, "height quantization preserves palette values")
  sprite:close()

  sprite = Sprite(6, 6, ColorMode.GRAY)
  sprite.selection:select(Rectangle(1, 1, 3, 2))
  target = assert(Aseprite.textureTarget(app.site, "Selection"))
  local grayscale = assert(Aseprite.heightMapImage(target, heights))
  equal(grayscale.colorMode, ColorMode.GRAY, "grayscale map uses native pixel format")
  equal(app.pixelColor.grayaV(grayscale:getPixel(0, 0)), 109, "grayscale preserves 8-bit height")
  equal(app.pixelColor.grayaA(grayscale:getPixel(1, 0)), 0, "grayscale map preserves holes")
  sprite:close()
  print("PASS native grayscale and indexed height map formats")
end

local function checkMaterialFinish()
  local sprite = Sprite(30, 22, ColorMode.RGB)
  local sourceLayer = sprite.layers[1]
  local sourceImage = Image(19, 13, ColorMode.RGB)
  local rgbaPixel = app.pixelColor.rgba
  for y = 0, 12 do
    local light = (y >= 4 and y <= 8) and 130 or 78
    for x = 0, 17 do
      local alpha = x < 9 and 255 or 123
      if x == 6 and y == 5 then alpha = 0 end
      sourceImage:drawPixel(x, y, rgbaPixel(light, light + 4, light + 8, alpha))
    end
  end

  local frame = sprite:newEmptyFrame(2)
  local sourceCel = sprite:newCel(sourceLayer, frame, sourceImage, Point(3, 4))
  local before = sourceCel.image.bytes
  app.layer, app.frame = sourceLayer, frame
  local options = {style = "Brushed Steel", seed = 321, density = 100, intensity = 100,
    form = "Horizontal Round"}
  local target = assert(Aseprite.textureTarget(app.site, "Layer Pixels"))
  local paint = assert(Aseprite.materialPaint(target, options))
  local samples = Material.generate(target.width, target.height, options, target.mask)
  local output = Aseprite.newTextureImage(target)
  equal(paint(0, 1, 1), nil, "a neutral material sample makes no edit")
  local partial, opaque = 0, 0
  for y = 0, target.height - 1 do
    for x = 0, target.width - 1 do
      local sample = samples[y * target.width + x + 1]
      local pixel, r, g, b, alpha = paint(sample, x, y)
      if pixel then
        equal(pixel, rgbaPixel(r, g, b, alpha), "rendered color and native pixel agree")
        equal(alpha, target.alphaAt(x, y), "finish respects partial source alpha")
        if alpha < 255 then partial = partial + 1 else opaque = opaque + 1 end
        output:drawPixel(x, y, pixel)
      end
    end
  end
  assert(partial > 0 and opaque > 0, "material finish drew no visible effect on part of the artwork")
  equal(app.pixelColor.rgbaA(output:getPixel(6, 5)), 0, "material finish preserves a transparent hole")
  local layer = assert(Aseprite.addTextureLayer(target, output, options.style))
  equal(layer:cel(1), nil, "material finish only affects the active frame")
  equal(layer:cel(frame).position, Point(3, 4), "material layer aligns to the artwork")
  equal(sourceCel.image.bytes, before, "material finish preserves the source pixels")
  app.undo()
  equal(#sprite.layers, 1, "Undo removes the material finish and its cel")
  equal(sourceLayer:cel(frame).image.bytes, before, "source pixels remain intact after material Undo")

  app.layer, app.frame = sourceLayer, frame
  sprite.selection:select(Rectangle(22, 5, 6, 10))
  target = assert(Aseprite.textureTarget(app.site, "Selection"))
  paint = assert(Aseprite.materialPaint(target, options))
  samples = Material.generate(target.width, target.height, options, target.mask)
  local filled = 0
  for y = 0, target.height - 1 do
    for x = 0, target.width - 1 do
      local index = y * target.width + x + 1
      local pixel, r, g, b, alpha = paint(samples[index], x, y)
      if pixel then
        equal(pixel, rgbaPixel(r, g, b, alpha), "selection fill matches its output color")
        equal(alpha, 255, "explicit selection can fill transparent pixels")
        filled = filled + 1
      end
    end
  end
  assert(filled > 0, "a material finish did not use its base color on an empty selection")
  sprite:close()
  print("PASS material finish alignment, transparency, explicit selection and Undo")
end

checkPalette()
checkIndexedTexture()
checkFramePalettes()
checkAlpha()
checkHeightMap()
checkHeightMapColorModes()
checkMaterialFinish()

local function checkMaterialWorkspace()
  local Catalog = require("lib.material_catalog")
  local Workspace = require("lib.workspace")
  local sprite = Sprite(22, 17, ColorMode.RGB)
  local source = sprite.layers[1]
  local pixels, rgbaPixel = Image(13, 9, ColorMode.RGB), app.pixelColor.rgba
  for y = 0, 8 do
    local value = y >= 3 and y <= 5 and 160 or 75
    for x = 0, 12 do
      if x ~= 5 or y ~= 5 then pixels:drawPixel(x, y, rgbaPixel(value, value, value, 255)) end
    end
  end
  local cel = sprite:newCel(source, 1, pixels, Point(4, 3))
  app.layer = source
  local before = cel.image.bytes
  local target = assert(Aseprite.textureTarget(app.site, "Layer Pixels"))
  local settings = Catalog.recipe("Painted Metal")
  settings.recipe = Catalog.recipe("Painted Metal")
  settings.heights = Aseprite.heightSamples(target)
  settings.normalStrength, settings.smoothing = 75, 0
  local images = assert(Workspace.layerImages(target, settings))
  assert(#images > 1, "Substanceprite recipe should produce separate palette and finish images")
  local group = Aseprite.addMaterialGroup(target, images, "Substanceprite Test")
  equal(group.stackIndex, source.stackIndex + 1, "material group is directly above source")
  equal(#group.layers, #images, "each changed stage produces an editable native layer")
  equal(group.layers[1]:cel(1).position, Point(4, 3), "stack keeps source cel offset")
  equal(cel.image.bytes, before, "baking keeps source pixel data intact")
  local flattened = Image(sprite.width, sprite.height, ColorMode.RGB)
  flattened:drawSprite(sprite, 1)
  local preview = assert(Workspace.preview(target, settings,
    {x = 0, y = 0, width = 13, height = 9}, "Color"))
  equal(flattened:getPixel(4, 6), preview:getPixel(0, 3), "baked opaque pixels match the color preview")
  equal(app.pixelColor.rgbaA(flattened:getPixel(9, 8)), 0, "material stack preserves holes")
  local normal = Workspace.normalImage(target, settings, true)
  equal(normal.width, sprite.width, "normal map has full sprite width")
  equal(normal.height, sprite.height, "normal map has full sprite height")
  equal(normal:getPixel(0, 0), rgbaPixel(128, 128, 255, 255), "normal map padding is opaque neutral")
  equal(normal:getPixel(9, 8), rgbaPixel(128, 128, 255, 255), "normal map holes have neutral padding")
  assert(normal:getPixel(6, 5) ~= rgbaPixel(128, 128, 255, 255), "relief produces a non-flat normal")
  app.undo()
  equal(#sprite.layers, 1, "one Undo removes the full material group")
  equal(cel.image.bytes, before, "Undo preserves source pixel data")
  local normalSprite = Workspace.openNormalSprite(normal)
  equal(normalSprite.cels[1].image.bytes, normal.bytes, "the standalone normal sprite keeps exact RGB bytes")
  normalSprite:close()
  sprite:close()
  print("PASS Substanceprite material stack, normal-map padding, preview parity and Undo")
end

checkMaterialWorkspace()

local function checkSoftRustPixels()
  local Texture = require("lib.texture")
  local sprite = Sprite(40, 27, ColorMode.RGB)
  local colors = Texture.defaultColors("Rust")
  local paint = assert(Aseprite.rustPaint(sprite, colors, app.frame))
  equal(paint(0, 255), nil, "empty rust sample does not paint")
  local sample = (128 << 8) | 128
  local pixel, r, g, b, a = paint(sample, 255)
  local baseR, baseG, baseB, baseA = Texture.rustSample(sample, colors)
  equal(pixel, app.pixelColor.rgba(r, g, b, a), "soft rust keeps the native RGBA pixel")
  equal(pixel, app.pixelColor.rgba(baseR, baseG, baseB, baseA), "soft rust matches its procedural swatch")
  local _, _, _, _, partial = paint(sample, 128)
  assert(partial > 0 and partial < a, "partial source alpha attenuates soft rust")
  equal(paint(sample, 0), nil, "soft rust cannot cross the silhouette")
  sprite:close()
  print("PASS soft Rust native swatches, opacity steps and silhouette")
end

checkSoftRustPixels()

local function checkWeatheredPaint()
  local Deposits = require("lib.deposits")
  local sprite = Sprite(32, 26, ColorMode.RGB)
  local mask, heights = {}, {}
  for y = 0, 25 do
    for x = 0, 31 do
      local index = y * 32 + x + 1
      mask[index] = x ~= 8
      if mask[index] then heights[index] = y < 8 and 0.80 or (y == 18 and 0.70 or 0.28) end
    end
  end
  local rgbaPixel = app.pixelColor.rgba
  for _, style in ipairs({ "Dirt", "Moss", "Paint Chips" }) do
    local options = {style = style, seed = 219, density = 95, intensity = 90, scale = 4,
      surface = {heights = heights, strength = 55}, runoff = 100}
    local colors = Deposits.defaultColors(style)
    local swatch = Deposits.sampler(style, colors)
    local paint = assert(Aseprite.softDepositPaint(sprite, style, colors, app.frame))
    local samples = Deposits.generator(style)(32, 26, options, mask)
    local count = 0
    for index, sample in ipairs(samples) do
      local pixel = paint(sample, 255)
      if not mask[index] then equal(pixel, nil, style .. " keeps gaps transparent") end
      if pixel then
        local r, g, b, a = swatch(sample)
        equal(pixel, rgbaPixel(r, g, b, a), style .. " uses its soft swatch in Aseprite")
        count = count + 1
      end
    end
    assert(count > 10, style .. " produced too little coverage in this test")
  end
  sprite:close()
  print("PASS soft dirt, moss and exposed paint chips in Aseprite")
end

checkWeatheredPaint()

local function checkRustTrails()
  local Chips = require("lib.chips")
  local Deposits = require("lib.deposits")
  local sprite = Sprite(48, 42, ColorMode.RGB)
  local heights, mask = {}, {}
  for y = 0, 41 do
    for x = 0, 47 do
      local i = y * 48 + x + 1
      mask[i] = x ~= 3 and not (y == 27 and x < 12)
      if mask[i] then heights[i] = y < 12 and 0.79 or (x > 18 and x < 26 and 0.28 or 0.53) end
    end
  end
  local options = {seed = 219, density = 68, intensity = 89, scale = 4, runoff = 100,
    surface = {heights = heights, strength = 55}, trails = 0}
  local without = Chips.generate(48, 42, options, mask)
  options.trails = 100
  local with = Chips.generate(48, 42, options, mask)
  local colors = Deposits.defaultColors(Chips.style)
  local paint = assert(Aseprite.softDepositPaint(sprite, Chips.style, colors, app.frame))
  local stained = 0
  for i, sample in ipairs(with) do
    if not mask[i] then equal(sample, 0, "rust pigment stays inside the paint silhouette") end
    if without[i] ~= 0 then
      equal(paint(sample, 255), paint(without[i], 255), "rust trails leave the original chip pixel intact")
    elseif sample ~= 0 then
      local pixel, r, _, b, alpha = paint(sample, 255)
      assert(pixel and r > b and alpha > 0 and alpha < 255, "native stain must be warm and translucent")
      equal(paint(sample, 0), nil, "no rust pigment over transparent source")
      stained = stained + 1
    end
  end
  assert(stained > 5, "this material did not draw enough native rust trail pixels")
  sprite:close()
  print("PASS native warm rust trails on paint keep every original chip pixel")
end

checkRustTrails()

local function checkDepositLighting()
  local Deposits = require("lib.deposits")
  local sprite = Sprite(28, 20, ColorMode.RGB)
  local px = app.pixelColor
  local image = Image(22, 16, ColorMode.RGB)
  for y = 0, 15 do
    for x = 0, 21 do
      local value = y == 7 and 40 or (y == 8 and 205 or 112)
      image:drawPixel(x, y, px.rgba(value, value, value, 255))
    end
  end
  local source = sprite.layers[1]
  local cel = sprite:newCel(source, 1, image, Point(3, 2))
  app.layer = source
  local target = assert(Aseprite.textureTarget(app.site, "Layer Pixels"))
  local settings = {style = "Rust", colors = Deposits.defaultColors("Rust"), lighting = 0}
  local flat = assert(Aseprite.depositPaint(target, settings))
  settings.lighting = 100
  local lit = assert(Aseprite.depositPaint(target, settings))
  local sample = (128 << 8) | 231
  local plainDark, _, _, _, plainAlpha = flat(sample, 11, 7, 255)
  equal(plainDark, flat(sample, 11, 8, 255), "ordinary overlays ignore the underlay's luminance")
  local _, dr, dg, db, lowAlpha = lit(sample, 11, 7, 255)
  local _, lr, lg, lb, highAlpha = lit(sample, 11, 8, 255)
  assert(lr > dr and lg > dg and lb > db, "tinted rust retains the light next to a dark seam")
  equal(lowAlpha, plainAlpha, "matching shadows keeps the layer opacity")
  equal(highAlpha, plainAlpha, "matching highlights keeps the layer opacity")
  equal(cel.image.bytes, image.bytes, "lighting must not edit the source artwork")
  sprite:close()
  print("PASS native deposit lighting keeps adjacent highlights and seams")
end

checkDepositLighting()

local function checkLinkedWeathering()
  local Native = require("lib.linked_native")
  local sprite = Sprite(56, 50, ColorMode.RGB)
  local rgbaPixel = app.pixelColor.rgba
  local source = sprite.layers[1]
  source.name = "Painted steel"
  local image = Image(48, 42, ColorMode.RGB)
  local heightImage = Image(image)
  for y = 0, 41 do
    for x = 0, 47 do
      if x ~= 3 or y < 20 or y > 28 then
        local light = 50 + y * 2
        local height = x > 18 and x < 26 and 71 or 143
        image:putPixel(x, y, rgbaPixel(light, light + 12, light + 5, 255))
        heightImage:putPixel(x, y, rgbaPixel(height, height, height, 255))
      end
    end
  end
  local cel = sprite:newCel(source, 1, image, Point(4, 3))
  local height = sprite:newLayer()
  height.name = "Height Map"
  height.isVisible = false
  sprite:newCel(height, 1, heightImage, cel.position)
  app.layer = source
  local target = assert(Aseprite.textureTarget(app.site, "Layer Pixels"))
  local group = assert(Native.create(target, {
    seed = 219, density = 68, intensity = 89, scale = 4, runoff = 100, trails = 100,
    lighting = 100, heightLayer = height,
  }))
  equal(#Native.list(sprite), 1, "new group is linked")
  local layers = assert(Native.layers(group))
  equal(layers.source, source, "link resolves source above the canvas offset")
  equal(layers.height, height, "link resolves the height layer")
  assert(not layers.masksGroup.isVisible and layers.masks.chips.isEditable)
  local original, masks, lit = image.bytes, {}, {}
  local stages = { "chips", "rust", "trails" }
  local function output(stage) return layers.outputs[stage]:cel(1).image end
  local function mask(stage) return layers.masks[stage]:cel(1).image end
  for _, stage in ipairs(stages) do
    lit[stage], masks[stage] = output(stage).bytes, mask(stage).bytes
    assert(lit[stage]:find("[^\0]"), "empty generated " .. stage)
    assert(output(stage):getPixel(7, 25) == 0, "effect leaks into source transparency")
  end
  equal(cel.image.bytes, original, "creating linked cels preserves the source")
  local brighter = Image(image)
  for it in brighter:pixels() do
    local value = it()
    if value ~= 0 then it(rgbaPixel(178, 205, 185, 255)) end
  end
  app.transaction("Repaint source lighting", function() cel.image = brighter end)
  assert(Native.refresh(sprite, group), "repaint should change linked colors")
  for _, stage in ipairs(stages) do
    assert(output(stage).bytes ~= lit[stage], "repaint left " .. stage .. " unchanged")
    equal(mask(stage).bytes, masks[stage], "repaint preserves " .. stage .. " mask")
    for offset = 4, #lit[stage], 4 do
      equal(output(stage).bytes:byte(offset), lit[stage]:byte(offset), "repaint keeps alpha")
    end
  end
  app.undo()
  assert(Native.refresh(sprite, group))
  equal(cel.image.bytes, original, "one Undo reverts the actual repaint")
  for _, stage in ipairs(stages) do equal(output(stage).bytes, lit[stage], "Undo restores " .. stage) end
  local heightCel = height:cel(1)
  local changedHeight = Image(heightCel.image)
  for it in changedHeight:pixels() do
    if it() ~= 0 then
      local value = it.x > 10 and it.x < 15 and 30 or 220
      it(rgbaPixel(value, value, value, 255))
    end
  end
  app.transaction("Move the drainage channel", function() heightCel.image = changedHeight end)
  assert(Native.refresh(sprite, group))
  assert(output("trails").bytes ~= lit.trails, "sculpting height changes the trail route")
  for _, stage in ipairs(stages) do equal(mask(stage).bytes, masks[stage], "height edit preserves masks") end
  equal(output("chips").bytes, lit.chips, "moving a channel preserves existing chips")
  equal(output("rust").bytes, lit.rust, "moving a channel preserves existing rust")
  app.undo()
  assert(Native.refresh(sprite, group))
  local disabled = Image(mask("chips"))
  disabled:clear()
  app.transaction("Hide open metal", function() layers.masks.chips:cel(1).image = disabled end)
  assert(Native.refresh(sprite, group))
  for _, stage in ipairs(stages) do
    assert(not output(stage).bytes:find("[^\0]"), "chip removal leaves " .. stage)
  end
  equal(mask("rust").bytes, masks.rust, "dependent update preserves authored rust mask")
  app.undo()
  assert(Native.refresh(sprite, group))
  assert(not Native.refresh(sprite, group), "unchanged linked cels are a no-op")
  sprite:close()
  print("PASS linked RGB layers, source repaint, editable masks and Undo in Aseprite")
end

checkLinkedWeathering()

local function checkCastShadows()
  local Native = require("lib.linked_native")
  local Workspace = require("lib.workspace")
  local px = app.pixelColor
  local width, height = 24, 16
  local sprite = Sprite(width + 4, height + 4, ColorMode.RGB)
  local source, position = sprite.layers[1], Point(2, 2)
  local art, relief = Image(width, height, ColorMode.RGB), Image(width, height, ColorMode.RGB)
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      if x ~= 10 or y ~= 7 then
        local level = x == 12 and 220 or 45
        art:putPixel(x, y, px.rgba(124, 138, 125, 255))
        relief:putPixel(x, y, px.rgba(level, level, level, 255))
      end
    end
  end
  local cel = sprite:newCel(source, 1, art, position)
  local heightLayer = sprite:newLayer()
  heightLayer.isVisible = false
  local mapCel = sprite:newCel(heightLayer, 1, relief, position)
  app.layer = source
  local target = assert(Aseprite.textureTarget(app.site, "Layer Pixels"))
  local settings = { heightLayer = heightLayer, shadowAngle = 0, shadowElevation = 35,
    shadowReach = 12, shadowSoftness = 0, shadowStrength = 70 }
  local group = assert(Native.create(target, settings))
  assert(not Native.layers(group).outputs.shadows, "previous recipes start with shadows off")
  settings.shadows = true
  local preview = assert(Native.preview(target, settings)).shadows
  assert(Native.setSettings(sprite, group, settings))
  local layers = Native.layers(group)
  local shadow = assert(layers.outputs.shadows, "existing group gains an independent stage")
  assert(shadow.stackIndex > layers.outputs.trails.stackIndex and shadow.stackIndex < layers.masksGroup.stackIndex)
  local function shadowImage() return shadow:cel(1).image end
  local initial = shadowImage().bytes
  local function alpha(x, y) return px.rgbaA(shadowImage():getPixel(x + 2, y + 2)) end
  assert(alpha(9, 7) > 0 and alpha(10, 7) == 0 and alpha(13, 7) == 0, "shadow follows the ridge and silhouette")
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      equal(shadowImage():getPixel(x + 2, y + 2), preview[y * width + x + 1] or 0, "linked preview matches output")
    end
  end
  local heights = Aseprite.heightSamples(target, heightLayer)
  local rect = { x = 7, y = 6, width = 3, height = 3 }
  local litSettings = { heights = heights, lightAngle = 0 }
  local lit = assert(Workspace.preview(target, litSettings, rect, "Lit"))
  litSettings.shadows = true
  local shaded = assert(Workspace.preview(target, litSettings, rect, "Lit"))
  assert(px.rgbaR(shaded:getPixel(2, 1)) < px.rgbaR(lit:getPixel(2, 1)), "offscreen ridge shadows Lit crop")
  local flat = Image(relief)
  flat:clear(px.rgba(45, 45, 45, 255))
  app.transaction("Flatten the ridge", function() mapCel.image = flat end)
  assert(Native.refresh(sprite, group) and shadowImage():isEmpty())
  app.undo()
  assert(Native.refresh(sprite, group))
  equal(shadowImage().bytes, initial, "one Undo restores the shadow after a height edit")
  equal(cel.image.bytes, art.bytes, "cast shadows preserve painted source pixels")
  sprite:close()
  print("PASS cast shadows match the native preview, respect silhouette and follow authored height")
end

checkCastShadows()

local function checkMaterialSpheres()
  local Catalog = require("lib.material_catalog")
  local Workspace = require("lib.workspace")
  local px = app.pixelColor
  local seen = {}
  for _, name in ipairs(Catalog.names) do
    local image = Workspace.materialSphere(Catalog.recipe(name), nil, 46)
    equal(image.width, 46, "thumbnail dimensions")
    equal(image:getPixel(0, 0), 0, "transparent area around the sphere")
    equal(px.rgbaA(image:getPixel(23, 23)), 255, "sphere has an opaque center")
    assert(not seen[image.bytes], "thumbnail repeats another recipe: " .. name)
    seen[image.bytes] = true
  end
  local recipe = Catalog.recipe("Painted Metal")
  local sample = Workspace.materialSample(recipe)
  local first = Workspace.renderSphere(sample, nil, 52)
  equal(Workspace.materialSphere(recipe, nil, 52).bytes, first.bytes, "same recipe renders deterministically")
  assert(Workspace.materialSphere(recipe, { layers = {} }, 52).bytes ~= first.bytes, "layers affect the preview")
  assert(Workspace.materialSphere(recipe, { seed = 39 }, 52).bytes ~= first.bytes, "seed affects the preview")
  assert(Workspace.renderSphere(sample, { lightAngle = 25 }, 52).bytes ~= first.bytes, "light affects the preview")
  assert(Workspace.renderSphere(sample, { rotation = 90 }, 52).bytes ~= first.bytes, "rotation affects the preview")
  print(("PASS %d procedural Aseprite spheres, updated layer stack, seed, light and rotation"):format(#Catalog.names))
end

checkMaterialSpheres()

local function checkPaintedMetal()
  local Paint = require("lib.paint_native")
  local px = app.pixelColor
  local sprite = Sprite(24, 18, ColorMode.RGB)
  local source = sprite.layers[1]
  local image = Image(18, 14, ColorMode.RGB)
  for y = 0, image.height - 1 do
    for x = 0, image.width - 1 do
      if x ~= 5 or y ~= 4 then
        local value = 85 + x * 7
        image:putPixel(x, y, px.rgba(value, value, value, 255))
      end
    end
  end
  local cel = sprite:newCel(source, 1, image, Point(3, 2))
  app.layer = source
  sprite.selection:select(Rectangle(6, 5, 8, 7))
  local full = assert(Paint.context(app.site))
  local selected = assert(Paint.context(app.site, true))
  equal(full.target.width, 18, "whole painted silhouette by default")
  equal(selected.target.width, 8, "painting can use the selection explicitly")
  local group = assert(Paint.apply(selected, { color = { r = 24, g = 95, b = 170 },
    chips = 0, corrosion = 100 }))
  local layers = assert(Paint.layers(group))
  local paint = layers.outputs.paint:cel(1)
  local metal = layers.metalMap:cel(1)
  local heightBytes = layers.heightMap:cel(1).image.bytes
  local savedPaint = paint.image.bytes
  equal(paint.position.x, 6, "coat starts at the selected region")
  equal(paint.image:getPixel(2, 1), 0, "coat keeps the original hole")
  local exposed = Image(metal.image)
  exposed:putPixel(4, 3, px.rgba(255, 255, 255, 255))
  app.transaction("Author metal", function() metal.image = exposed end)
  assert(Paint.refresh(sprite, group))
  equal(paint.image:getPixel(4, 3), 0, "paint is removed where metal is authored")
  assert(layers.outputs.rust:cel(1).image:getPixel(4, 3) ~= 0, "authored metal can rust")
  local editable = assert(Paint.context{ sprite = sprite, layer = layers.outputs.rust, frame = 1 })
  equal(editable.group, group, "any painted child reopens the original group")
  equal(Paint.apply(editable, { color = { r = 190, g = 65, b = 33 } }), group, "recolor updates the same group")
  equal(#Paint.list(sprite), 1, "recolor keeps a single material group")
  equal(metal.image.bytes, exposed.bytes, "recolor keeps the authored metal map")
  equal(layers.heightMap:cel(1).image.bytes, heightBytes, "recolor keeps the authored height map")
  app.undo()
  app.undo()
  Paint.refresh(sprite, group)
  equal(paint.image.bytes, savedPaint, "Undo of map edit restores the coat")
  equal(cel.image.bytes, image.bytes, "painting never modifies the selected source artwork")
  sprite:close()
  print("PASS painted metal group keeps authored maps, selection and source, with native Undo")
end

checkPaintedMetal()

local function checkPaintedRain()
  local Paint = require("lib.paint_native")
  local px = app.pixelColor
  local sprite = Sprite(25, 36, ColorMode.RGB)
  local source = sprite.layers[1]
  local image = Image(25, 36, ColorMode.RGB)
  image:clear(px.rgba(102, 116, 133, 255))
  sprite:newCel(source, 1, image, Point(0, 0))
  app.layer = source
  local context = assert(Paint.context(app.site))
  local group = assert(Paint.apply(context, { chips = 0, corrosion = 100, trails = 100, seamless = true }))
  local function reopen()
    return assert(Paint.context{ sprite = sprite, layer = group, frame = 1 })
  end
  local layers = assert(Paint.layers(group))
  local metal = layers.metalMap:cel(1)
  local map = Image(metal.image)
  map:putPixel(12, 8, px.rgba(255, 255, 255, 255))
  app.transaction("Expose one rusty chip", function() metal.image = map end)
  Paint.refresh(sprite, group)
  local legacy = layers.outputs.trails:cel(1).image.bytes
  equal(reopen().settings.rainStrength, nil, "legacy recipe has no explicit rain")
  equal(Paint.apply(reopen(), { opacity = 100 }), group, "legacy settings can be updated in place")
  equal(layers.outputs.trails:cel(1).image.bytes, legacy, "old settings preserve the legacy appearance")
  local function sediment()
    local volume, furthest = 0, 0
    for it in layers.outputs.trails:cel(1).image:pixels() do
      local alpha = px.rgbaA(it())
      if alpha > 0 then
        assert(it.y > 8, "top-down rain never deposits above the chip or over the Y seam")
        volume, furthest = volume + alpha, math.max(furthest, it.y)
      end
    end
    return volume, furthest
  end
  assert(Paint.apply(reopen(), { rainStrength = 0, rainDuration = 80 }))
  equal(sediment(), 0, "no water means no runoff")
  assert(Paint.apply(reopen(), { rainStrength = 80, rainDuration = 16 }))
  local shortVolume, shortEnd = sediment()
  assert(shortVolume > 0, "rain below the chip produces a trail")
  assert(Paint.apply(reopen(), { rainStrength = 80, rainDuration = 95 }))
  local longVolume, longEnd = sediment()
  assert(longVolume > shortVolume and longEnd > shortEnd, "longer rain visibly extends the downstream trail")
  equal(reopen().settings.rainDuration, 95, "rain duration stays on the same painted material")
  equal(metal.image.bytes, map.bytes, "rain settings keep authored metal map bytes")
  sprite:close()
  print("PASS native top-down paint runoff, wet and dry settings, editable maps and legacy compatibility")
end

checkPaintedRain()

local function checkAgedPaint()
  local Paint = require("lib.paint_native")
  local px = app.pixelColor
  local sprite = Sprite(45, 33, ColorMode.RGB)
  local source = sprite.layers[1]
  local image = Image(45, 33, ColorMode.RGB)
  image:clear(px.rgba(113, 132, 148, 255))
  sprite:newCel(source, 1, image, Point(0, 0))
  app.layer = source
  local group = assert(Paint.apply(assert(Paint.context(app.site)), { chips = 0, corrosion = 100 }))
  local function reopen()
    return assert(Paint.context{ sprite = sprite, layer = group, frame = 1 })
  end
  local layers = assert(Paint.layers(group))
  assert(not layers.outputs.scuff and not layers.outputs.fading, "wear creates stages only when enabled")
  local cel = layers.metalMap:cel(1)
  local metal = Image(cel.image)
  local white = px.rgba(255, 255, 255, 255)
  metal:putPixel(22, 15, white)
  app.transaction("Draw a chip", function() cel.image = metal end)
  local settings = { edgeWear = 100, edgeWidth = 3, scuffs = 100, fading = 100 }
  equal(Paint.apply(reopen(), settings), group, "wear upgrades the original painted group")
  layers = assert(Paint.layers(group))
  local scuffs, fading = layers.outputs.scuff:cel(1), layers.outputs.fading:cel(1)
  assert(layers.scuffMask and layers.fadingMask)
  assert(not scuffs.image:isEmpty() and not fading.image:isEmpty())
  assert(layers.outputs.paint.stackIndex < layers.outputs.scuff.stackIndex
    and layers.outputs.scuff.stackIndex < layers.outputs.rust.stackIndex, "wear composites between coat and deposits")
  equal(cel.image:getPixel(22, 15), white, "edge regeneration keeps a hand-drawn chip")
  local editedMap, oldScuffs = cel.image.bytes, scuffs.image.bytes
  assert(Paint.apply(reopen(), { palette = { scuff = { r = 241, g = 108, b = 96, a = 180 } } }))
  assert(scuffs.image.bytes ~= oldScuffs, "tint changes the abrasion")
  equal(cel.image.bytes, editedMap, "color settings preserve the metal map")
  local maskCel = layers.scuffMask:cel(1)
  local blank = Image(maskCel.image)
  blank:clear(px.rgba(0, 0, 0, 255))
  app.transaction("Mask scuffing", function() maskCel.image = blank end)
  assert(Paint.refresh(sprite, group) and scuffs.image:isEmpty())
  assert(not fading.image:isEmpty())
  app.undo()
  assert(Paint.refresh(sprite, group) and not scuffs.image:isEmpty())
  sprite:close()
  print("PASS aged paint upgrades in place with editable masks, metal and pigments")
end

checkAgedPaint()

local function checkBevelWear()
  local Paint = require("lib.paint_native")
  local px = app.pixelColor
  local width, height = 57, 36
  local sprite = Sprite(width, height, ColorMode.RGB)
  local source = sprite.layers[1]
  local art, relief = Image(sprite.spec), Image(sprite.spec)
  local function gray(value) return px.rgba(value, value, value, 255) end
  local profile = { [12] = 140, [13] = 175, [14] = 247, [25] = 247, [26] = 175, [27] = 140 }
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      if x ~= 9 or y ~= 9 then
        art:putPixel(x, y, px.rgba(76 + 4 * y, 78 + 4 * y, 79 + 4 * y, 255))
        local level = profile[x] or (x >= 15 and x <= 24 and 247)
          or (x >= 34 and x <= 39 and 39) or 122
        relief:putPixel(x, y, gray(level))
      end
    end
  end
  sprite:newCel(source, 1, art, Point(0, 0))
  local heightLayer = sprite:newLayer()
  heightLayer.name, heightLayer.isVisible = "Height Map - Bevel Test", false
  sprite:newCel(heightLayer, 1, relief, Point(0, 0))
  app.layer = source
  local context = assert(Paint.context(app.site))
  local settings = {heightMode = "Height Map Layer", heightLayer = heightLayer,
    color = {r = 103, g = 51, b = 25}, chips = 0, edgeWear = 0, bevelWear = 100, bevelWidth = 2,
    corrosion = 100, seed = 52}
  local coverage = assert(Paint.preview(context, settings, nil, "Bevel Coverage"))
  local result = assert(Paint.preview(context, settings))
  local exposed = 0
  for y = 0, height - 1 do
    for _, x in ipairs({14, 25}) do
      if px.rgbaR(coverage:getPixel(x, y)) == 255 then
        equal(result:getPixel(x, y), art:getPixel(x, y), "fully worn shoulder shows the original steel")
        exposed = exposed + 1
      end
    end
    equal(coverage:getPixel(36, y), gray(0), "groove bottom keeps paint")
  end
  assert(exposed > 0, "raised bevel has some fully exposed pixels")
  equal(result:getPixel(9, 9), 0, "bevel wear respects transparent holes")
  local group = assert(Paint.apply(context, settings))
  local function reopen() return assert(Paint.context{sprite = sprite, layer = group, frame = 1}) end
  equal(reopen().settings.bevelWear, 100, "strength survives reopening")
  equal(reopen().settings.bevelWidth, 2, "width survives reopening")
  local layers = assert(Paint.layers(group))
  local coat, heightCel = layers.outputs.paint:cel(1), layers.heightMap:cel(1)
  local initialCoat = coat.image.bytes
  assert(layers.outputs.rust:cel(1).image:isEmpty(), "fresh bevel exposure stays clean")
  local metalCel = layers.metalMap:cel(1)
  local authored = Image(metalCel.image)
  authored:putPixel(47, 12, gray(255))
  app.transaction("Draw an independent chip", function() metalCel.image = authored end)
  assert(Paint.refresh(sprite, group) and not layers.outputs.rust:cel(1).image:isEmpty())
  local chippedCoat = coat.image.bytes
  assert(chippedCoat ~= initialCoat)
  local flat = Image(heightCel.image)
  flat:clear(gray(122))
  app.transaction("Flatten the bevel relief", function() heightCel.image = flat end)
  assert(Paint.refresh(sprite, group) and coat.image.bytes ~= chippedCoat)
  equal(metalCel.image.bytes, authored.bytes, "height edits preserve authored metal pixels")
  app.undo()
  assert(Paint.refresh(sprite, group) and coat.image.bytes == chippedCoat, "Undo restores the previous bevel")
  local mask = layers.bevelMask:cel(1)
  local protected = Image(mask.image)
  protected:clear(gray(0))
  app.transaction("Protect the bevel", function() mask.image = protected end)
  assert(Paint.refresh(sprite, group) and coat.image.bytes ~= chippedCoat)
  app.undo()
  assert(Paint.refresh(sprite, group) and coat.image.bytes == chippedCoat)
  assert(Paint.apply(reopen(), {bevelWear = 0}))
  equal(metalCel.image.bytes, authored.bytes, "disabling bevel wear keeps the manually exposed chip")
  assert(coat.image.bytes ~= chippedCoat and not layers.outputs.rust:cel(1).image:isEmpty())
  sprite:close()
  print("PASS optional bevels reveal clean steel, recalculate from height, and respect masks and Undo")
end

checkBevelWear()
print("19/19 Aseprite integration checks passed")
