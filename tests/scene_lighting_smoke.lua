local directory = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or ""
package.path = directory .. "../?.lua;" .. package.path
local Native = require("lib.scene_lighting_native")
local px = app.pixelColor

local function scene(sprite, frame)
  local image = Image(sprite.spec)
  image:drawSprite(sprite, frame or 1)
  return image
end

local sprite = Sprite(52, 29, ColorMode.RGB)
local source = sprite.layers[1]
source.name = "Painted shell"
local art = Image(42, 23, ColorMode.RGB)
for y = 0, art.height - 1 do
  for x = 0, art.width - 1 do
    if x ~= 29 or y ~= 12 then
      art:putPixel(x, y, px.rgba(141, 104 + (x % 6), 73, x == 35 and y == 13 and 128 or 255))
    end
  end
end
local sourceCel = sprite:newCel(source, 1, art, Point(5, 3))
local originalBytes = sourceCel.image.bytes
local guide = sprite:newLayer()
guide.name, guide.isVisible = "Height Map - Test", false
local elevation = Image(52, 29, ColorMode.RGB)
for y = 3, 25 do
  for x = 5, 46 do
    local height = (x >= 16 and x <= 19 or x >= 39 and x <= 41) and 226 or 74
    if x >= 29 and x <= 32 and y > 8 and y < 18 then height = 26 end
    elevation:putPixel(x, y, px.rgba(height, height, height, 255))
  end
end
sprite:newCel(guide, 1, elevation, Point(0, 0))
local trim = sprite:newGroup()
trim.name = "Prop details"
local numbers = sprite:newLayer()
numbers.parent = trim
local stamp = Image(4, 5, ColorMode.RGB)
stamp:clear(px.rgba(220, 197, 144, 220))
sprite:newCel(numbers, 1, stamp, Point(29, 9))
local original = scene(sprite)

sprite.selection = Selection(Rectangle(21, 7, 24, 17))
local site = { sprite = sprite, layer = numbers, frame = sprite.frames[1] }
local context = assert(Native.context(site, true))
local recipe = {
  heightMode = "Height Map Layer", heightLayer = guide, lightAngle = 180, lightElevation = 30,
  directLight = true, lightStrength = 64, normalStrength = 60, smoothing = 0,
  ao = true, aoRadius = 3, aoStrength = 42, shadows = true, shadowReach = 9, shadowStrength = 68,
}
local cast = assert(Native.preview(context, recipe, nil, "Cast Shadows"))
assert(px.rgbaR(cast:getPixel(22 - context.target.x, 12 - context.target.y)) < 255,
  "a ridge outside the selection should cast into it")
local preview = assert(Native.preview(context, recipe, nil, "Result"))
local crop = assert(Native.preview(context, recipe, Rectangle(15, 6, 12, 12), "Result"))
for y = 0, crop.height - 1 do
  for x = 0, crop.width - 1 do assert(crop:getPixel(x, y) == preview:getPixel(x + 15, y + 6)) end
end
local group = assert(Native.apply(context, recipe))
local layers = assert(Native.layers(group))
assert(group.stackIndex == #sprite.layers and not layers.inputs.isVisible)
for _, key in ipairs({ "light", "ao", "shadows" }) do
  assert(not layers[key]:cel(1).image:isEmpty(), key .. " did not render")
end
local lit = scene(sprite)
local maximum, changed = 0, 0
for y = 0, sprite.height - 1 do
  for x = 0, sprite.width - 1 do
    local a, b = original:getPixel(x, y), lit:getPixel(x, y)
    assert(px.rgbaA(a) == px.rgbaA(b), "lighting changed the silhouette")
    if not sprite.selection:contains(x, y) or px.rgbaA(a) < 255 then
      assert(a == b, "lighting leaked outside the selection or into partial alpha")
    end
    if a ~= b then
      changed = changed + 1
      local c = preview:getPixel(x - context.target.x, y - context.target.y)
      maximum = math.max(maximum, math.abs(px.rgbaR(c) - px.rgbaR(b)),
        math.abs(px.rgbaG(c) - px.rgbaG(b)), math.abs(px.rgbaB(c) - px.rgbaB(b)))
    end
  end
end
assert(changed > 50 and maximum <= 2, "applied group diverged from the preview")
assert(sourceCel.image.bytes == originalBytes)
print("PASS standalone lighting preserves source, supports cropped preview and casts beyond a saved selection")

sprite.selection:deselect()
local saved = assert(Native.context(site))
assert(saved.group == group and saved.settings.useSelection and saved.settings.heightLayer == guide)
local firstShadow = layers.shadows:cel(1).image.bytes
assert(Native.apply(saved, { lightAngle = 0 }) == group and #Native.list(sprite) == 1)
assert(layers.shadows:cel(1).image.bytes ~= firstShadow)
local turn = scene(sprite).bytes
assert(turn ~= lit.bytes)

Native.editMask(group)
local matte = layers.mask:cel(1)
local dark = Image(matte.image)
dark:clear(px.rgba(0, 0, 0, 255))
app.transaction("Mask lighting", function() matte.image = dark end)
assert(Native.showResult(group) == group and not layers.inputs.isVisible)
assert(scene(sprite).bytes == original.bytes)
app.undo()
assert(Native.refresh(sprite, group) and scene(sprite).bytes == turn)

local heightCel = guide:cel(1)
local flat = Image(heightCel.image)
flat:clear(px.rgba(128, 128, 128, 255))
app.transaction("Flatten height", function() heightCel.image = flat end)
assert(Native.refresh(sprite, group) and layers.shadows:cel(1).image:isEmpty())
app.undo()
assert(Native.refresh(sprite, group) and scene(sprite).bytes == turn)

local location = app.params["scene-lighting-file"]
if location then
  sprite:saveAs(location)
  sprite:close()
  sprite = assert(app.open(location))
  group = assert(Native.list(sprite)[1])
  saved = assert(Native.context{ sprite = sprite, layer = group, frame = sprite.frames[1] })
  assert(saved.settings.lightAngle == 0 and saved.settings.useSelection and saved.settings.heightLayer.isImage)
  assert(scene(sprite).bytes == turn)
  Native.refresh(sprite, group)
  assert(scene(sprite).bytes == turn)
end
local copied = sprite:newFrame(sprite.frames[1])
assert(#sprite.frames == 2)
local firstFrame = copied.frameNumber == 1 and 2 or 1
local second = assert(Native.context{ sprite = sprite, layer = group, frame = copied })
assert(second.group == group and second.frame == copied and #Native.list(sprite) == 1)
assert(scene(sprite, copied.frameNumber).bytes == scene(sprite, firstFrame).bytes)
assert(Native.apply(second, { lightAngle = 180 }) == group)
local sharedLight = scene(sprite, firstFrame).bytes
assert(sharedLight == scene(sprite, copied.frameNumber).bytes and sharedLight ~= turn)
local copyGuide = second.settings.heightLayer:cel(copied)
copyGuide.image = flat
assert(Native.refresh(sprite, group))
assert(scene(sprite, firstFrame).bytes == sharedLight and scene(sprite, copied.frameNumber).bytes ~= sharedLight)
print("PASS duplicated animation frames share lighting controls and keep independent height results")
sprite:close()
print("PASS standalone lighting reopens, changes light direction, refreshes from mask/height and retains Undo")
