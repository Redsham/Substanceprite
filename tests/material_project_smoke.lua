local source = debug.getinfo(1, "S").source
local testsDirectory = source:sub(2):match("^(.*[/\\])") or ""
package.path = testsDirectory .. "../?.lua;" .. package.path

local Aseprite = require("lib.aseprite")
local Project = require("lib.material_project")
local px = app.pixelColor

local function site(sprite, layer, frame)
  return { sprite = sprite, layer = layer, frame = frame, cel = layer:cel(frame) }
end

local function composite(sprite, frame)
  local image = Image(sprite.width, sprite.height, ColorMode.RGB)
  image:drawSprite(sprite, frame)
  return image
end

local function fixture()
  local sprite = Sprite(24, 18, ColorMode.RGB)
  local layer = sprite.layers[1]
  layer.name = "Original prop"
  local cel = layer:cel(1)
  local image = Image(24, 18, ColorMode.RGB)
  image:clear(px.rgba(68, 98, 116, 255))
  image:drawPixel(2, 2, px.rgba(110, 122, 187, 128))
  cel.image = image
  return sprite, layer
end

local function settings()
  return {
    recipeId = "painted-metal", patternAmount = 100, seed = 146,
    layers = {
      {
        id = "dirt", kind = "Deposits", style = "Dirt", mask = "Top",
        density = 100, intensity = 100, amount = 100, scale = 6, clustering = 60,
      },
    },
  }
end

local function still()
  local sprite, sourceLayer = fixture()
  local frame = sprite.frames[1]
  local original = sourceLayer:cel(frame).image.bytes
  local originalEdge = sourceLayer:cel(frame).image:getPixel(23, 17)
  local selection = Selection(Rectangle(1, 1, 17, 15))
  selection:subtract(Rectangle(10, 2, 4, 3))
  sprite.selection = selection
  local target = assert(Aseprite.textureTarget(site(sprite, sourceLayer, frame), "Auto"))
  local options = settings()
  options.useSelection = true
  options.createMask = "dirt"
  local group = assert(Project.apply(target, options))
  assert(#Project.list(sprite) == 1 and not sourceLayer.isVisible)
  assert(sourceLayer:cel(frame).image.bytes == original)
  local result = composite(sprite, 1)
  assert(px.rgbaA(result:getPixel(2, 2)) == 128)
  assert(result:getPixel(23, 17) == originalEdge and result:getPixel(11, 3) == originalEdge)
  assert(result:getPixel(4, 4) ~= originalEdge)

  local mask = assert(Project.editMask(group, "dirt", frame))
  local context = assert(Project.open(site(sprite, mask, frame)))
  assert(context.settings.recipeId == "painted-metal" and context.settings.masks.dirt(1, 1) == 1)
  assert(Project.sourceFor(site(sprite, mask, frame)) == sourceLayer)
  local maskImage = Image(sprite.width, sprite.height, ColorMode.RGB)
  maskImage:clear(px.rgba(0, 0, 0, 255))
  mask:cel(frame).image = maskImage
  assert(Project.refresh(sprite, group))
  assert(Project.showResult(group, frame))
  local muted = composite(sprite, 1)
  assert(muted.bytes ~= result.bytes)
  assert(muted:getPixel(23, 17) == originalEdge)
  context = assert(Project.open(site(sprite, group, frame)))
  options.seed = 147
  assert(Project.apply(context.target, options, context) == group)
  context = assert(Project.open(site(sprite, group, frame)))
  assert(context.settings.seed == 147 and context.settings.masks.dirt(1, 1) == 0)
  muted = composite(sprite, 1)

  assert(Project.editSource(group, frame) == sourceLayer and sourceLayer.isVisible)
  local edited = sourceLayer:cel(frame).image:clone()
  edited:drawPixel(4, 4, px.rgba(237, 213, 182, 255))
  sourceLayer:cel(frame).image = edited
  assert(Project.refresh(sprite, group))
  assert(Project.showResult(group, frame))
  assert(composite(sprite, 1).bytes ~= muted.bytes)

  local savePath = app.params["material-project-file"]
  if savePath then
    sprite.selection:deselect()
    sprite:saveAs(savePath)
    sprite:close()
    sprite = assert(app.open(savePath))
    group = assert(Project.list(sprite)[1])
    local persisted = assert(Project.open(site(sprite, group, sprite.frames[1])))
    assert(persisted.settings.useSelection and persisted.settings.recipeId == "painted-metal")
    assert(persisted.settings.masks.dirt(1, 1) == 0 and persisted.settings.layers[1].id == "dirt")
    assert(composite(sprite, 1):getPixel(11, 3) == originalEdge)
  end
  sprite:close()
end

local function animated()
  local sprite, sourceLayer = fixture()
  sprite:newFrame()
  local frame = sprite.frames[1]
  local target = assert(Aseprite.textureTarget(site(sprite, sourceLayer, frame), "Layer Pixels"))
  local untouched = composite(sprite, 2):getPixel(4, 4)
  assert(Project.apply(target, settings()))
  assert(sourceLayer.isVisible)
  assert(composite(sprite, 2):getPixel(4, 4) == untouched)
  assert(px.rgbaA(composite(sprite, 1):getPixel(2, 2)) == 128)
  assert(composite(sprite, 1):getPixel(4, 4) ~= untouched)
  app.undo()
  assert(#Project.list(sprite) == 0 and sourceLayer.isVisible)
  sprite:close()
end

local function undoStill()
  local sprite, sourceLayer = fixture()
  local frame = sprite.frames[1]
  local target = assert(Aseprite.textureTarget(site(sprite, sourceLayer, frame), "Layer Pixels"))
  local original = composite(sprite, 1).bytes
  assert(Project.apply(target, settings()))
  assert(not sourceLayer.isVisible)
  app.undo()
  assert(#Project.list(sprite) == 0 and sourceLayer.isVisible)
  assert(composite(sprite, 1).bytes == original)
  sprite:close()
end

local function editHeight()
  local sprite, sourceLayer = fixture()
  local frame = sprite.frames[1]
  local heightLayer = sprite:newLayer()
  heightLayer.name = "Panel height"
  heightLayer.isVisible = false
  local image = Image(sprite.width, sprite.height, ColorMode.RGB)
  image:clear(px.rgba(188, 188, 188, 255))
  local cel = sprite:newCel(heightLayer, frame, image)
  local options = settings()
  options.heightMode, options.heightLayer = "Height Map Layer", heightLayer
  options.layers[1].mask = "Recesses"
  local target = assert(Aseprite.textureTarget(site(sprite, sourceLayer, frame), "Layer Pixels"))
  local group = assert(Project.apply(target, options))
  local flat = composite(sprite, 1).bytes
  for y = 3, 15 do image:drawPixel(8, y, px.rgba(26, 26, 26, 255)) end
  cel.image = image
  assert(Project.refresh(sprite, group))
  assert(composite(sprite, 1).bytes ~= flat)
  local context = assert(Project.open(site(sprite, group, frame)))
  assert(context.settings.heightLayer == heightLayer)
  sprite:close()
end

still()
animated()
undoStill()
editHeight()
print("PASS native material project masks, live updates, height, selection, alpha, save/reopen and Undo")
