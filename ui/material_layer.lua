local Composer = require("lib.composer")
local Aseprite = require("lib.aseprite")
local Effects = require("lib.effect_registry")
local Lighting = require("lib.lighting")
local Material = require("lib.material")
local Masks = require("lib.mask_registry")

local LayerInspector = {}
local sliders = {
  { id = "effectAmount", key = "amount", label = "Opacity", min = 0, max = 100 },
  { id = "effectDensity", key = "density", label = "Density", min = 0, max = 100 },
  { id = "effectIntensity", key = "intensity", label = "Intensity", min = 0, max = 100 },
  { id = "effectScale", key = "scale", label = "Scale", min = 1, max = 64, advanced = true },
  { id = "effectClustering", key = "clustering", label = "Clustering", min = 0, max = 100, advanced = true },
}

local styleFields = { "kind", "style", "colors", "density", "intensity", "scale", "clustering",
  "softness", "runoff", "trails" }
local mainControls = { "effectActive", "effectKind", "effectStyle", "effectMask", "effectAdvanced" }
local contextualControls = { "effectMaskHint", "effectDirection", "effectForm", "effectLighting",
  "effectSoftness", "effectRunoff", "effectTrails", "effectTone", "effectColor", "resetEffectColors" }

local function styles(kind)
  return kind == "Deposits" and Effects.styles or Material.styles
end

function LayerInspector.add(dlg, getContext, onChange)
  local initial = Composer.newLayer("Finish")
  local styleOptions = styles(initial.kind)
  local syncing, active = false, true
  local refresh, toneIndex, toneOptions = nil, 1, {}

  local function showControls(show)
    for _, id in ipairs(mainControls) do dlg:modify{ id = id, visible = show } end
    if not show then
      for _, id in ipairs(contextualControls) do dlg:modify{ id = id, visible = false } end
      for _, slider in ipairs(sliders) do dlg:modify{ id = slider.id, visible = false } end
    end
  end

  local function maskHint(mask, hasHeight)
    local definition = Masks.get(mask)
    dlg:modify{ id = "effectMaskHint", visible = not hasHeight and definition and definition.requiresHeight == true }
  end

  local function bind(id, key, changesDisplayName)
    return function()
      if syncing then return end
      local layer, hasHeight = getContext()
      local value = dlg.data[id]
      if not layer or value == nil or layer[key] == value then return end
      layer[key] = value
      if key == "mask" then maskHint(value, hasHeight) end
      onChange(changesDisplayName == true)
    end
  end

  local function changeStyle(kind, style)
    if syncing then return end
    local layer = getContext()
    if not layer or layer.kind == kind and layer.style == style then return end
    local defaults = Composer.newLayer(kind, style)
    for _, field in ipairs(styleFields) do layer[field] = defaults[field] end
    toneIndex = 1
    if layer.lighting == nil then layer.lighting = defaults.lighting end
    refresh()
    onChange(true)
  end

  dlg:newrow()
  dlg:combobox{ id = "effectKind", label = "Type", options = Composer.kinds, option = initial.kind,
    onchange = function()
      if syncing then return end
      local kind = dlg.data.effectKind
      changeStyle(kind, styles(kind)[1])
    end }
  dlg:samerow()
  dlg:check{ id = "effectActive", text = "Enabled", selected = true,
    onclick = bind("effectActive", "enabled", true) }
  dlg:combobox{ id = "effectStyle", label = "Effect", options = styleOptions, option = initial.style,
    onchange = function()
      if syncing then return end
      local data = dlg.data
      changeStyle(data.effectKind, data.effectStyle)
    end }
  dlg:combobox{ id = "effectMask", label = "Surface Area", options = Composer.masks, option = initial.mask,
    onchange = bind("effectMask", "mask") }
  dlg:label{ id = "effectMaskHint", text = "This mask needs a height source.", visible = false }

  for _, slider in ipairs(sliders) do
    if not slider.advanced then
      dlg:slider{ id = slider.id, label = slider.label, min = slider.min, max = slider.max,
        value = initial[slider.key], onchange = bind(slider.id, slider.key) }
    end
  end
  dlg:check{ id = "effectAdvanced", text = "Advanced Settings", onclick = function() refresh() end }
  for _, slider in ipairs(sliders) do
    if slider.advanced then
      dlg:slider{ id = slider.id, label = slider.label, min = slider.min, max = slider.max,
        value = initial[slider.key], visible = false, onchange = bind(slider.id, slider.key) }
    end
  end
  dlg:combobox{ id = "effectDirection", label = "Grain", options = Material.directions,
    option = Material.defaults.direction, visible = false, onchange = bind("effectDirection", "direction") }
  dlg:combobox{ id = "effectForm", label = "Form", options = Material.forms,
    option = Material.defaults.form, visible = false, onchange = bind("effectForm", "form") }
  dlg:slider{ id = "effectLighting", label = "Lighting Match", min = 0, max = 100,
    value = Lighting.defaultMatch, visible = false, onchange = bind("effectLighting", "lighting") }
  dlg:slider{ id = "effectSoftness", label = "Softness", min = 0, max = 100,
    value = 0, visible = false, onchange = bind("effectSoftness", "softness") }
  dlg:slider{ id = "effectRunoff", label = "Runoff", min = 0, max = 100,
    value = 0, visible = false, onchange = bind("effectRunoff", "runoff") }
  dlg:slider{ id = "effectTrails", label = "Rust Trails", min = 0, max = 100,
    value = 0, visible = false, onchange = bind("effectTrails", "trails") }
  dlg:combobox{ id = "effectTone", label = "Palette Tone", option = "Tone 1", options = { "Tone 1" },
    visible = false, onchange = function()
      if syncing then return end
      for i, name in ipairs(toneOptions) do
        if name == dlg.data.effectTone then toneIndex = i; break end
      end
      refresh()
    end }
  dlg:color{ id = "effectColor", label = "Color", color = Color{ r = 98, g = 86, b = 71 },
    visible = false, onchange = function()
      local layer = getContext()
      if syncing or not active or not layer or layer.kind ~= "Deposits" or not dlg.data.effectAdvanced then return end
      layer.colors = layer.colors or Effects.defaultColors(layer.style)
      layer.colors[toneIndex] = Aseprite.rgba(dlg.data.effectColor)
      onChange(false)
    end }
  dlg:button{ id = "resetEffectColors", text = "Reset Colors", visible = false, onclick = function()
    local layer = getContext()
    if not layer then return end
    layer.colors = Effects.defaultColors(layer.style)
    refresh()
    onChange(false)
  end }

  refresh = function(visible)
    if visible ~= nil then active = visible end
    local layer, hasHeight = getContext()
    showControls(active and layer ~= nil)
    if not active or not layer then return end
    syncing = true

    local advanced = dlg.data.effectAdvanced == true
    local finish = layer.kind == "Finish"
    local deposits = not finish and Effects.controls(layer.style)
    local defaults = Composer.newLayer(layer.kind, layer.style)
    local options = styles(layer.kind)
    dlg:modify{ id = "effectActive", selected = layer.enabled ~= false }
    dlg:modify{ id = "effectKind", option = layer.kind }
    dlg:modify{ id = "effectStyle", option = layer.style, options = styleOptions ~= options and options or nil }
    styleOptions = options
    dlg:modify{ id = "effectMask", option = layer.mask or defaults.mask }
    maskHint(layer.mask or defaults.mask, hasHeight)
    for _, slider in ipairs(sliders) do
      dlg:modify{ id = slider.id, value = layer[slider.key] or defaults[slider.key],
        visible = not slider.advanced or advanced }
    end
    dlg:modify{ id = "effectDirection", visible = advanced and finish,
      option = layer.direction or Material.defaults.direction }
    dlg:modify{ id = "effectForm", visible = advanced and finish,
      option = layer.form or Material.defaults.form }
    dlg:modify{ id = "effectLighting", visible = advanced and not finish,
      value = layer.lighting or Lighting.defaultMatch }
    dlg:modify{ id = "effectSoftness", visible = advanced and not not deposits,
      value = layer.softness or defaults.softness or 0 }
    dlg:modify{ id = "effectRunoff", visible = advanced and not not deposits,
      enabled = hasHeight or (deposits and not deposits.requiresHeight) or false,
      label = deposits and deposits.label or "Runoff", value = layer.runoff or defaults.runoff or 0 }
    dlg:modify{ id = "effectTrails", visible = advanced and deposits and deposits.trails ~= nil or false,
      value = layer.trails or defaults.trails or 0 }
    local colors = not finish and (layer.colors or defaults.colors)
    local hasColors = advanced and colors and #colors > 0 or false
    dlg:modify{ id = "effectColor", visible = hasColors }
    dlg:modify{ id = "resetEffectColors", visible = hasColors }
    if hasColors then
      if #toneOptions ~= #colors then
        toneOptions = {}
        for i = 1, #colors do toneOptions[i] = "Tone " .. i end
        dlg:modify{ id = "effectTone", options = toneOptions }
      end
      toneIndex = math.min(toneIndex, #colors)
      dlg:modify{ id = "effectColor", color = Aseprite.color(colors[toneIndex]) }
    end
    dlg:modify{ id = "effectTone", visible = hasColors and #colors > 1,
      option = toneOptions[toneIndex] }
    syncing = false
  end
  return refresh
end

return LayerInspector
