local path = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or ""
package.path = path .. "../?.lua;" .. package.path
local Details = require("lib.prop_details")
local Native = require("lib.detail_native")
local px = app.pixelColor

local sprite = Sprite(65, 34, ColorMode.RGB)
local source = sprite.layers[1]
source.name = "Container panel"
local paint = Image(58, 29, ColorMode.RGB)
for y = 0, paint.height - 1 do
  for x = 0, paint.width - 1 do
    if x ~= 26 or y ~= 15 then
      local value = (x % 6 < 3) and 126 or 91
      paint:putPixel(x, y, px.rgba(value, 61, 44, x == 2 and y == 2 and 128 or 255))
    end
  end
end
local sourceCel = sprite:newCel(source, 1, paint, Point(3, 2))
local originalBytes = sourceCel.image.bytes
local function composite()
  local canvas = Image(sprite.spec)
  canvas:drawSprite(sprite, 1)
  return canvas
end
local original = composite()
local site = { sprite = sprite, layer = source, frame = sprite.frames[1], cel = sourceCel }
local selection = Selection(Rectangle(4, 3, 53, 27))
selection:subtract(Rectangle(24, 8, 3, 3))
sprite.selection = selection
local ctx = assert(Native.context(site, true))
local options = { entries = Details.preset("Cargo Container"), seed = 142, reliefShadows = true }
for _, entry in ipairs(options.entries) do
  if entry.kind == "Stencil" then entry.width, entry.height = 32, 25 end
end
local alpha = Details.new("Alpha Stamp")
alpha.id, alpha.alphaId, alpha.reliefMode = "perforation", "round-perforation", "Recessed"
alpha.x, alpha.y, alpha.width, alpha.height = 52, 33, 29, 40
options.entries[#options.entries + 1] = alpha
local full = assert(Native.preview(ctx, options, nil, "Result"))
local piece = assert(Native.preview(ctx, options, Rectangle(4, 2, 19, 10), "Result"))
for y = 0, piece.height - 1 do
  for x = 0, piece.width - 1 do assert(full:getPixel(x + 4, y + 2) == piece:getPixel(x, y)) end
end
local group = assert(Native.apply(ctx, options))
local parts = assert(Native.layers(group))
assert(parts.height and parts.mask and parts.relief and parts.scope and not parts.inputs.isVisible)
assert(next(parts.outputs) and not parts.height:cel(1).image:isEmpty())
assert(parts.outputs.perforation and not parts.outputs.perforation:cel(1).image:isEmpty())
local finished = composite()
local edits, maxDelta = 0, 0
for y = 0, sprite.height - 1 do
  for x = 0, sprite.width - 1 do
    local before, after = original:getPixel(x, y), finished:getPixel(x, y)
    assert(px.rgbaA(before) == px.rgbaA(after), "applying details changed the source silhouette")
    if not selection:contains(x, y) then
      assert(before == after, "detail leaked outside the selection")
    elseif after ~= before then
      edits = edits + 1
      local preview = full:getPixel(x - ctx.target.x, y - ctx.target.y)
      maxDelta = math.max(maxDelta, math.abs(px.rgbaR(preview) - px.rgbaR(after)),
        math.abs(px.rgbaG(preview) - px.rgbaG(after)), math.abs(px.rgbaB(preview) - px.rgbaB(after)))
    end
  end
end
assert(edits > 150 and maxDelta <= 2, "preview and applied artwork diverged")
assert(sourceCel.image.bytes == originalBytes)

local groupSite = { sprite = sprite, layer = group, frame = sprite.frames[1] }
local saved = assert(Native.context(groupSite))
assert(saved.settings.useSelection and saved.settings.seed == 142)
local stencil
for _, entry in ipairs(saved.settings.entries) do if entry.kind == "Stencil" then stencil = entry; break end end
assert(stencil and parts.outputs[stencil.id])
local label = parts.outputs[stencil.id]:cel(1).image.bytes
stencil.text = "B25"
assert(Native.apply(saved, { entries = saved.settings.entries }) == group)
assert(parts.outputs[stencil.id]:cel(1).image.bytes ~= label, "reapplying text did not update its existing layer")

local visible = Native.editMask(group)
assert(visible == parts.mask and parts.inputs.isVisible)
local matte = parts.mask:cel(1)
local black = Image(matte.image)
black:clear(px.rgba(0, 0, 0, 255))
app.transaction("Suppress Details", function() matte.image = black end)
assert(Native.showResult(group) == group and not parts.inputs.isVisible)
assert(composite().bytes == original.bytes, "black detail mask must restore the original appearance")
app.undo()
assert(Native.refresh(sprite, group))
assert(composite().bytes ~= original.bytes)
local refreshed = composite().bytes
local outputPath = app.params["prop-details-file"]
if outputPath then
  sprite.selection:deselect()
  sprite:saveAs(outputPath)
  sprite:close()
  sprite = assert(app.open(outputPath))
  group = assert(Native.list(sprite)[1])
  local reloaded = assert(Native.context{ sprite = sprite, layer = group, frame = sprite.frames[1] })
  assert(reloaded.settings.seed == 142 and reloaded.settings.useSelection)
  assert(Native.layers(group).outputs[stencil.id])
  local storedAlpha = reloaded.settings.entries[#reloaded.settings.entries]
  assert(storedAlpha.id == alpha.id and storedAlpha.alphaId == alpha.alphaId and storedAlpha.reliefMode == "Recessed")
  assert(Native.layers(group).outputs[alpha.id].name == require("lib.detail_alphas").get(alpha.alphaId).name)
  Native.refresh(sprite, group)
  assert(composite().bytes == refreshed)
end
sprite:close()
print("PASS native prop details selection, alpha, preview, editable stencil, masks, Undo and save/reopen")

local Paint = require("lib.paint_native")
local coatedSprite = Sprite(72, 32, ColorMode.RGB)
local metalLayer = coatedSprite.layers[1]
local metal = Image(72, 32, ColorMode.RGB)
metal:clear(px.rgba(110, 113, 117, 255))
local metalCel = coatedSprite:newCel(metalLayer, 1, metal, Point(0, 0))
local metalSite = { sprite = coatedSprite, layer = metalLayer, frame = coatedSprite.frames[1], cel = metalCel }
local coatedGroup = assert(Paint.apply(assert(Paint.context(metalSite)), {
  color = { r = 116, g = 64, b = 42, a = 255 }, chips = 25, corrosion = 70,
}))
local coated = assert(Native.context(metalSite, false))
assert(coated.source == coatedGroup and coated.target.width == 72 and coated.target.height == 32)
local paintedPixels = assert(Native.preview(coated, {}, nil, "Original"))
local actual = Image(coatedSprite.spec)
actual:drawSprite(coatedSprite, 1)
assert(actual.bytes == paintedPixels.bytes, "the detail editor must build on the existing painted surface")
local created = assert(Native.apply(coated, { entries = Details.preset("Industrial Panel") }))
assert(created.stackIndex == coatedGroup.stackIndex + 1)
coatedSprite:close()
print("PASS prop details apply above existing painted materials")
