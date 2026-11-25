local Live = require("lib.linked_live")
local Native = require("lib.linked_native")
local TextureDialog = require("ui.texture_dialog")
local Chips = require("lib.chips")
local Lighting = require("lib.lighting")
local Common = require("ui.common")
local ShadowControls = require("ui.shadow_controls")

local LinkedDialog = {}
local stages = {
  { id = "chips", label = "Paint Chips" },
  { id = "rust", label = "Rust" },
  { id = "trails", label = "Rust Trails" },
}

local function selectedGroup(site)
  local groups = Native.list(site.sprite)
  local layer = site.layer
  while layer and layer ~= site.sprite do
    for _, group in ipairs(groups) do
      if layer == group then return group end
    end
    layer = layer.parent
  end
end

function LinkedDialog.open(plugin, site)
  local sprite = site.sprite
  local group = selectedGroup(site)
  if not group then
    if site.cel and not site.layer.isTilemap then
      TextureDialog.open(plugin, site, "Paint Chips")
    else
      app.alert("Select source artwork or a layer in a Linked Weathering group.")
    end
    return
  end

  local settings = Native.settings(group)
  local layers = Native.layers(group)
  if not settings or not layers or not layers.source or not layers.masksGroup then
    app.alert("The linked group is missing its source or masks.")
    return
  end

  local chipLayer = layers.outputs.chips
  local chipCels = chipLayer and chipLayer.cels
  local firstCel = chipCels and chipCels[1]
  local frame = chipLayer and site.frame and chipLayer:cel(site.frame) and site.frame
                or (firstCel and firstCel.frame) or site.frame
  local heightOptions, heightLayers = Common.surfaceSources(
    { sprite = sprite, layer = layers.source, frame = frame }, Native.list(sprite))
  local originalSource = settings.heightMode == "Luminance" and "Art Luminance" or "Flat"
  for _, option in ipairs(heightOptions) do
    if layers.height and heightLayers[option] == layers.height then originalSource = option end
  end

  local dlg = Dialog{ title = "Linked Weathering", autofit = Align.TOP | Align.LEFT }
  local function shadowControls()
    local data = dlg.data
    local hasHeight = data.heightSource ~= "Flat"
    ShadowControls.visibility(dlg, true, hasHeight)
    dlg:modify{ id = "heightInvert", visible = hasHeight }
    dlg:modify{ id = "heightHint", visible = data.shadows and not hasHeight }
  end

  local function save()
    local data = dlg.data
    local changes = { lighting = data.lighting, trails = data.trailStrength, opacity = {} }
    if data.shadows or settings.shadows then ShadowControls.read(data, changes) end
    if data.heightSource ~= originalSource then
      changes.heightLayer = heightLayers[data.heightSource] or false
      changes.heightMode = changes.heightLayer and "Height Map Layer"
                           or (data.heightSource == "Art Luminance" and "Luminance" or "Flat")
    end
    if data.heightSource ~= "Flat" and data.heightInvert ~= (settings.heightInvert == true) then
      changes.heightInvert = data.heightInvert
    end
    for _, stage in ipairs(stages) do
      local current = settings.opacity[stage.id] or 255
      if data[stage.id] ~= (current * 100 + 127) // 255 then
        changes.opacity[stage.id] = (data[stage.id] * 255 + 50) // 100
      end
    end
    local ok, message = Native.setSettings(sprite, group, changes)
    if not ok then
      dlg:modify{ id = "status", text = message or "Unable to update the linked group." }
      return false
    end
    Live.track(sprite)
    return true
  end

  local function exitTo(layer, maskId)
    if not layer or not save() then return end
    for _, stage in ipairs(stages) do
      local mask = layers.masks[stage.id]
      if mask then mask.isVisible = stage.id == maskId end
    end
    layers.masksGroup.isVisible = maskId ~= nil
    if maskId then
      group.isCollapsed = false
      layers.masksGroup.isCollapsed = false
    end
    dlg:close()
    if frame and app.frame ~= frame then app.frame = frame end
    app.layer = layer
  end

  dlg:label{ label = "Source", text = layers.source.name }
  if layers.masksGroup.isVisible then
    dlg:samerow()
    dlg:button{ id = "showResult", text = "Show Result", hexpand = false,
      onclick = function() exitTo(group) end }
  end

  dlg:tab{ id = "effects", text = "Effects" }
  dlg:separator{ text = "Opacity and masks" }
  for _, stage in ipairs(stages) do
    local id, mask = stage.id, layers.masks[stage.id]
    dlg:slider{ id = id, label = stage.label, min = 0, max = 100,
      value = ((settings.opacity[id] or 255) * 100 + 127) // 255 }
    dlg:samerow()
    dlg:button{ id = id .. "Mask", text = "Edit Mask", enabled = mask ~= nil, hexpand = false,
      onclick = function() exitTo(mask, id) end }
  end
  dlg:label{ text = "White reveals the effect. Black hides it." }
  dlg:separator{}
  dlg:slider{ id = "lighting", label = "Lighting Match", min = 0, max = 100,
    value = settings.lighting or Lighting.defaultMatch }
  dlg:slider{ id = "trailStrength", label = "Trail Strength", min = 0, max = 100,
    value = settings.trails or Chips.defaults.trails }

  dlg:tab{ id = "surface", text = "Surface & Shadows" }
  dlg:combobox{ id = "heightSource", label = "Height Source", options = heightOptions,
    option = originalSource, onchange = shadowControls }
  dlg:check{ id = "heightInvert", text = "Invert Height", selected = settings.heightInvert == true,
    visible = false }
  ShadowControls.add(dlg, settings, shadowControls)
  dlg:label{ id = "heightHint", text = "Choose a height map or Art Luminance to cast shadows.",
    visible = false }
  dlg:endtabs{ id = "weatheringTab", align = Align.LEFT,
    selected = site.layer == layers.outputs.shadows and "surface" or "effects" }

  dlg:label{ id = "status", text = " " }
  dlg:button{ id = "editSource", text = "Edit Source", onclick = function() exitTo(layers.source) end }
  dlg:button{ id = "apply", text = "Apply", focus = true,
    onclick = function() if save() then dlg:close() end end }
  dlg:button{ text = "Cancel" }
  shadowControls()
  dlg:show{ autoscrollbars = true }
end

return LinkedDialog
