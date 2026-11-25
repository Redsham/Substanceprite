local source = debug.getinfo(1, "S").source
local testsDirectory = source:sub(2):match("^(.*[/\\])") or ""
package.path = testsDirectory .. "../?.lua;" .. package.path

local Aseprite = require("lib.aseprite")
local Catalog = require("lib.material_catalog")
local Project = require("lib.material_project")
local Workspace = require("lib.workspace")
local px = app.pixelColor

local width, height = 31, 19
local ridgeX, centerY = 15, 9
local albedo = px.rgba(93, 148, 177, 255)
local shade = px.rgba(34, 34, 34, 255)

local function site(sprite, layer)
  local frame = sprite.frames[1]
  return {sprite = sprite, layer = layer, frame = frame, cel = layer:cel(frame)}
end

local function preview(target, settings, channel, rect)
  rect = rect or {x = 0, y = 0, width = target.width, height = target.height}
  return assert(Workspace.preview(target, settings, rect, channel))
end

local function copy(base, overrides)
  local result = {}
  for key, value in pairs(base) do result[key] = value end
  for key, value in pairs(overrides) do result[key] = value end
  return result
end

local function fixture()
  local sprite = Sprite(width, height, ColorMode.RGB)
  local layer = sprite.layers[1]
  layer.name = "Painted panel"
  local image = Image(sprite.spec)
  image:clear(albedo)
  image:putPixel(2, 2, 0)
  image:putPixel(17, 9, px.rgba(130, 171, 185, 117))
  layer:cel(1).image = image

  local guide = sprite:newLayer()
  guide.name, guide.isVisible = "Raised seam", false
  local elevation = Image(sprite.spec)
  elevation:clear(shade)
  for y = 2, height - 3 do elevation:putPixel(ridgeX, y, px.rgba(238, 238, 238, 255)) end
  sprite:newCel(guide, 1, elevation, Point(0, 0))
  local target = assert(Aseprite.textureTarget(site(sprite, layer), "Layer Pixels"))
  assert(target.x == 0 and target.y == 0 and target.width == width and target.height == height)
  local settings = {
    recipe = Catalog.recipe("metal"), patternAmount = 0, paletteAmount = 0, layers = {},
    heightMode = "Height Map Layer", heightLayer = guide,
    heights = assert(Aseprite.heightSamples(target, guide, nil, true)),
    directLight = false, ao = false, shadows = false,
    lightAngle = 0, lightElevation = 28, lightStrength = 71,
    lightColor = {r = 255, g = 230, b = 200},
    aoStrength = 82, aoRadius = 5, shadowStrength = 75, shadowReach = 17, shadowSoftness = 22,
  }
  return sprite, layer, guide, target, settings
end

local function checkAlpha(sourceImage, colored)
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      assert(px.rgbaA(colored:getPixel(x, y)) == px.rgbaA(sourceImage:getPixel(x, y)),
        ("alpha differs at (%d, %d)"):format(x, y))
    end
  end
end

local function grayAt(image, x, y)
  local pixel = image:getPixel(x, y)
  local r, g, b = px.rgbaR(pixel), px.rgbaG(pixel), px.rgbaB(pixel)
  assert(r == g and r == b, "diagnostic display must be grayscale")
  return r
end

local function checkPreview(target, settings, original)
  local raw = preview(target, settings, "Color")
  assert(raw.bytes == original.bytes, "disabled lighting changes source RGB")

  local ambient = preview(target, settings, "Ambient Occlusion")
  assert(grayAt(ambient, 2, centerY) == 255, "unoccluded surface must be white")
  assert(grayAt(ambient, ridgeX - 1, centerY) < 255, "raised seam must occlude nearby pixels")
  local ambientOnly = copy(settings, {ao = true})
  local aoColor = preview(target, ambientOnly, "Color")
  assert(px.rgbaR(aoColor:getPixel(ridgeX - 1, centerY)) < px.rgbaR(albedo),
    "enabled ambient occlusion must darken the material")
  assert(preview(target, copy(ambientOnly, {aoStrength = 0}), "Color").bytes == raw.bytes,
    "zero occlusion strength changes color")

  local left, right = ridgeX - 4, ridgeX + 4
  local cast = preview(target, settings, "Cast Shadows")
  assert(grayAt(cast, left, centerY) < 255 and grayAt(cast, right, centerY) == 255,
    "light from the right must cast the seam shadow to the left")
  local opposite = preview(target, copy(settings, {lightAngle = 180}), "Cast Shadows")
  assert(grayAt(opposite, left, centerY) == 255 and grayAt(opposite, right, centerY) < 255,
    "rotating the light must flip the cast shadow")
  local shadowOnly = copy(settings, {shadows = true})
  local shadowColor = preview(target, shadowOnly, "Color")
  local shaded = shadowColor:getPixel(left, centerY)
  assert(px.rgbaR(shaded) < px.rgbaR(albedo) and px.rgbaR(shaded) < px.rgbaG(shaded)
    and px.rgbaG(shaded) < px.rgbaB(shaded), "cast shadow should darken existing RGB")
  assert(shadowColor:getPixel(right, centerY) == albedo)
  assert(preview(target, copy(shadowOnly, {shadowStrength = 0}), "Color").bytes == raw.bytes,
    "zero shadow strength changes color")

  local lit = preview(target, settings, "Lit")
  assert(lit.bytes ~= raw.bytes, "Lit must show the direct preview")
  assert(preview(target, copy(settings, {directLight = true}), "Color").bytes == lit.bytes,
    "enabled direct light must match Lit")
  assert(preview(target, copy(settings, {directLight = true, lightStrength = 0}), "Color").bytes == raw.bytes,
    "zero direct light strength changes color")
  local whiteLight = copy(settings, {lightColor = {r = 255, g = 255, b = 255}})
  assert(preview(target, whiteLight, "Lit").bytes ~= lit.bytes, "the light tint must affect RGB")

  local combined = copy(settings, {directLight = true, ao = true, shadows = true})
  local crop = {x = 8, y = 6, width = 6, height = 5}
  for _, channel in ipairs({"Color", "Lit", "Ambient Occlusion", "Cast Shadows"}) do
    local full = preview(target, combined, channel)
    local clipped = preview(target, combined, channel, crop)
    checkAlpha(original, full)
    for y = 0, crop.height - 1 do
      for x = 0, crop.width - 1 do
        assert(clipped:getPixel(x, y) == full:getPixel(crop.x + x, crop.y + y),
          "preview crop changes output in " .. channel)
      end
    end
  end
  local zero = copy(combined, {aoStrength = 0, shadowStrength = 0})
  assert(preview(target, zero, "Cast Shadows").bytes == cast.bytes)
  assert(preview(target, zero, "Ambient Occlusion").bytes == ambient.bytes)
  local stages = assert(Workspace.layerImages(target, combined))
  local lightStage = stages[#stages]
  assert(lightStage and lightStage.name == "Lighting")
  assert(lightStage.image:getPixel(left, centerY) == preview(target, combined, "Color"):getPixel(left, centerY),
    "baked lighting layer differs from Color preview")
  return combined
end

local function checkMapExports()
  local sprite, original, guide, _, settings = fixture()
  sprite.selection = Selection(Rectangle(7, 5, 17, 10))
  local target = assert(Aseprite.textureTarget(site(sprite, original), "Selection"))
  assert(target.x == 7 and target.y == 5)
  local localOptions = copy(settings, {heights = assert(Aseprite.heightSamples(target, guide, nil, true))})
  for _, channel in ipairs({"Ambient Occlusion", "Cast Shadows"}) do
    local map = Workspace.lightMapImage(target, localOptions, channel)
    local expected = preview(target, localOptions, channel)
    assert(map.width == sprite.width and map.height == sprite.height)
    assert(map:getPixel(0, 0) == 0 and map:getPixel(width - 1, height - 1) == 0)
    for y = 0, target.height - 1 do
      for x = 0, target.width - 1 do
        assert(map:getPixel(target.x + x, target.y + y) == expected:getPixel(x, y),
          "map export shifts pixels in " .. channel)
      end
    end
    local document = Workspace.openMapSprite(map, channel)
    assert(document.layers[1].name == channel and document.layers[1]:cel(1).image.bytes == map.bytes)
    document:close()
  end
  sprite:close()
end

local function output(sprite, group, frame)
  for _, layer in ipairs(group.layers) do
    if layer.isImage then return assert(layer:cel(frame)).image end
  end
  error("missing material output in " .. sprite.filename)
end

local function checkSettings(settings, expected)
  for _, key in ipairs({"directLight", "ao", "shadows", "lightAngle", "lightElevation", "lightStrength",
      "aoStrength", "aoRadius", "shadowStrength", "shadowReach", "shadowSoftness"}) do
    assert(settings[key] == expected[key], "project did not retain " .. key)
  end
  assert(settings.lightColor.r == expected.lightColor.r and settings.lightColor.g == expected.lightColor.g
    and settings.lightColor.b == expected.lightColor.b, "project did not retain RGB light color")
end

local function checkLegacy()
  local sprite, _, _, target, settings = fixture()
  local group = assert(Project.apply(target, settings))
  local before = output(sprite, group, 1).bytes
  local properties = group.properties("substanceprite/substanceprite")
  properties.materialSettings = {
    recipeId = "metal", patternAmount = 0, paletteAmount = 0, layers = {},
    heightMode = "Height Map Layer", shadows = true, lightAngle = 0,
  }
  local context = assert(Project.open(site(sprite, group)))
  assert(not context.settings.shadows and not Project.refresh(sprite, group),
    "an earlier preview-only shadow flag changed the baked material")
  assert(Project.apply(context.target, {patternScale = 120}, context) == group)
  context = assert(Project.open(site(sprite, group)))
  assert(not context.settings.shadows and output(sprite, group, 1).bytes == before)
  assert(Project.apply(context.target, {shadows = true}, context) == group)
  context = assert(Project.open(site(sprite, group)))
  assert(context.settings.shadows and output(sprite, group, 1).bytes ~= before,
    "an explicit post-upgrade toggle must bake shadows")
  sprite:close()
end

local sprite, original, guide, target, settings = fixture()
local originalImage = original:cel(1).image
local originalBytes = originalImage.bytes
local lighting = checkPreview(target, settings, originalImage)
local group = assert(Project.apply(target, lighting))
local context = assert(Project.open(site(sprite, group)))
checkSettings(context.settings, lighting)
local baked = output(sprite, group, 1)
assert(baked.bytes == preview(target, lighting, "Color").bytes, "project bake differs from Color preview")
assert(baked.bytes == preview(context.target, context.settings, "Color").bytes)
assert(original:cel(1).image.bytes == originalBytes, "light changed the source artwork")
checkAlpha(originalImage, baked)

local visible = Image(sprite.spec)
visible:drawSprite(sprite, 1)
assert(visible:getPixel(ridgeX - 4, centerY) == baked:getPixel(ridgeX - 4, centerY))
checkAlpha(originalImage, visible)

local before = baked.bytes
local revised = Image(sprite.spec)
revised:clear(shade)
guide:cel(1).image = revised
assert(Project.refresh(sprite, group), "editing the height must refresh the lighting")
context = assert(Project.open(site(sprite, group)))
local refreshed = output(sprite, group, 1)
assert(refreshed.bytes ~= before)
assert(refreshed.bytes == preview(context.target, context.settings, "Color").bytes)
checkSettings(context.settings, lighting)

local savePath = app.params["material-lighting-file"]
if savePath then
  local rendered = refreshed.bytes
  sprite:saveAs(savePath)
  sprite:close()
  sprite = assert(app.open(savePath))
  group = assert(Project.list(sprite)[1])
  context = assert(Project.open(site(sprite, group)))
  checkSettings(context.settings, lighting)
  assert(context.settings.heightLayer and context.settings.heightLayer.name == "Raised seam")
  assert(output(sprite, group, 1).bytes == rendered)
  assert(preview(context.target, context.settings, "Color").bytes == rendered)
  assert(not Project.refresh(sprite, group), "saved result should match the live recipe")
end
sprite:close()
checkLegacy()
checkMapExports()
print("PASS RGB material lighting, map exports, alpha, crop parity, refresh, and legacy settings")
