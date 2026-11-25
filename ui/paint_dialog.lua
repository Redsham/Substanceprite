local Aseprite = require("lib.aseprite")
local Common = require("ui.common")
local Linked = require("lib.linked_native")
local Live = require("lib.linked_live")
local Native = require("lib.paint_native")
local Paint = require("lib.paint_stack")
local Colors = require("lib.paint_colors")
local PaletteUI = require("ui.paint_palette")

local DialogUI = {}
local weatherSliders = {
  { id = "corrosion", label = "Rust in Chips", min = 0, max = 100 },
  { id = "trails", label = "Rust Trails", min = 0, max = 100 },
  { id = "dirt", label = "Dirt", min = 0, max = 100 },
  { id = "moss", label = "Moss", min = 0, max = 100 },
  { id = "soot", label = "Soot", min = 0, max = 100 },
}
local rainSliders = {
  { id = "rainStrength", label = "Rain Strength", min = 0, max = 100 },
  { id = "rainDuration", label = "Rain Duration", min = 0, max = 100 },
}
local wearSliders = {
  { id = "chips", label = "Chips", min = 0, max = 100 },
  { id = "edgeWear", label = "Edge Wear", min = 0, max = 100 },
  { id = "scuffs", label = "Scuffs", min = 0, max = 100 },
  { id = "fading", label = "Fading", min = 0, max = 100 },
}
local maskOptions = { "Rust", "Rust Trails", "Dirt", "Moss", "Soot", "Scuffs", "Fading", "Primer" }
local maskKeys = { Rust = "rust", ["Rust Trails"] = "trails", Dirt = "dirt", Moss = "moss",
  Soot = "soot", Scuffs = "scuff", Fading = "fading", Primer = "primer" }

function DialogUI.open(site, providedContext)
  local context, errorMessage = providedContext, nil
  if not context then context, errorMessage = Native.context(site) end
  if not context then
    app.alert(errorMessage or "Select artwork or a finished material group to paint.")
    return
  end

  local defaults = Paint.defaults
  local sprite = context.sprite
  local existing = context.group ~= nil
  local initial = context.settings or defaults
  local palette = Colors.normalize(initial.palette)
  local function value(key)
    return (not existing and Paint.newWear[key]) or initial[key] or defaults[key]
  end
  local appliedLayers = existing and Native.layers(context.group)
  local mapsGroup = appliedLayers and appliedLayers.mapsGroup
  local mapVisible = mapsGroup and mapsGroup.isVisible
  local groups = Linked.list(sprite)
  for _, group in ipairs(Native.list(sprite)) do groups[#groups + 1] = group end
  local heightOptions, heightLayers, preferredHeight = Common.surfaceSources(
    { sprite = sprite, layer = context.source, frame = context.frame }, groups)
  local preview, timer, status
  local rainEdited = false
  local dlg = Dialog{
    title = "Substanceprite - Paint & Wear",
    autofit = Align.BOTTOM | Align.LEFT,
    onclose = function() if timer then timer:stop() end end,
  }

  local function read()
    local data = dlg.data
    local settings = {
      color = Aseprite.rgba(data.paintColor), opacity = data.opacity,
      seed = data.seed, seamless = data.seamless, palette = palette,
      edgeWidth = data.edgeWidth, scuffDirection = data.scuffDirection,
    }
    for _, slider in ipairs(wearSliders) do settings[slider.id] = data[slider.id] end
    for _, slider in ipairs(weatherSliders) do settings[slider.id] = data[slider.id] end
    if not existing or rainEdited or initial.rainStrength ~= nil or initial.rainDuration ~= nil then
      for _, slider in ipairs(rainSliders) do settings[slider.id] = data[slider.id] end
    end
    if not existing then
      local name = data.heightSource
      settings.heightLayer = heightLayers[name]
      settings.heightMode = settings.heightLayer and "Height Map Layer"
                            or (name == "Flat" and "Flat" or "Luminance")
    end
    return settings
  end

  local function showStatus(message)
    if message ~= status then
      dlg:modify{ id = "status", text = message }
      status = message
    end
  end

  local function update()
    local message
    if context then
      local rect = Common.previewArea(context.target)
      preview, message = Native.preview(context, read(), rect, dlg.data.previewMode)
      local target = context.target
      local size = ("%d × %d px"):format(target.width, target.height)
      if rect.width < target.width or rect.height < target.height then size = size .. " · Detail" end
      showStatus(message or size)
    else
      preview = nil
      showStatus(errorMessage)
    end
    dlg:modify{ id = "apply", enabled = preview ~= nil }
    dlg:repaint()
  end

  local function schedule()
    timer:stop()
    timer:start()
  end

  local function changeTarget()
    context, errorMessage = Native.context(site, dlg.data.useSelection)
    schedule()
  end

  local function apply(edit)
    timer:stop()
    if not context then return end
    local settings = read()
    settings.editMask = edit
    local group, message = Native.apply(context, settings)
    if not group then
      showStatus(message or "Unable to apply the painted material.")
      return
    end
    local saved = Native.context{ sprite = sprite, layer = group, frame = context.frame }
    if not saved then
      showStatus("The material was applied. Choose its group to edit.")
      return
    end
    Live.track(sprite)
    dlg:close()
    if type(edit) == "string" then Native.editMap(saved, edit) else Native.showResult(saved) end
  end

  dlg:label{ label = "Source", text = context.source.name }
  dlg:combobox{ id = "previewMode", label = "Preview", option = "Result",
    options = { "Result", "Original", "Metal Map", "Height Map" }, onchange = schedule }
  dlg:canvas{ id = "preview", width = 330, height = 138,
    onpaint = function(ev) Common.drawPixelPreview(ev.context, preview) end }
  dlg:label{ id = "status", text = " " }

  dlg:tab{ id = "paintTab", text = "Paint" }
  dlg:color{ id = "paintColor", label = "Paint Color", color = Aseprite.color(initial.color or defaults.color),
    enabled = palette.paint == nil,
    onchange = schedule }
  dlg:slider{ id = "opacity", label = "Paint Coverage", min = 0, max = 100,
    value = initial.opacity or defaults.opacity, onchange = schedule }
  if not existing and not sprite.selection.isEmpty then
    dlg:check{ id = "useSelection", text = "Use selection", selected = false, onclick = changeTarget }
  end

  dlg:tab{ id = "wearTab", text = "Wear" }
  local values = {}
  for _, slider in ipairs(wearSliders) do values[slider.id] = value(slider.id) end
  Common.addSliders(dlg, wearSliders, values, schedule)
  dlg:check{ id = "wearAdvanced", text = "Pattern Options", onclick = function()
    for _, id in ipairs({"edgeWidth", "scuffDirection", "seed", "seamless"}) do
      dlg:modify{ id = id, visible = dlg.data.wearAdvanced }
    end
  end }
  dlg:slider{ id = "edgeWidth", label = "Edge Width (px)", min = 1, max = 6,
    value = initial.edgeWidth or defaults.edgeWidth, visible = false, onchange = schedule }
  dlg:combobox{ id = "scuffDirection", label = "Scuff Direction", options = { "Auto", "Horizontal", "Vertical" },
    option = initial.scuffDirection or defaults.scuffDirection, visible = false, onchange = schedule }
  dlg:number{ id = "seed", label = "Seed", text = tostring(initial.seed or defaults.seed),
    decimals = 0, visible = false, onchange = schedule }
  dlg:check{ id = "seamless", text = "Seamless", selected = initial.seamless == true,
    visible = false, onclick = schedule }

  dlg:tab{ id = "weatheringTab", text = "Weathering" }
  for _, slider in ipairs(weatherSliders) do values[slider.id] = value(slider.id) end
  Common.addSliders(dlg, weatherSliders, values, schedule)
  dlg:check{ id = "rainOptions", text = "Rain Settings", onclick = function()
    for _, slider in ipairs(rainSliders) do dlg:modify{ id = slider.id, visible = dlg.data.rainOptions } end
  end }
  for _, slider in ipairs(rainSliders) do
    dlg:slider{ id = slider.id, label = slider.label, min = slider.min, max = slider.max,
      value = initial[slider.id] or defaults[slider.id], visible = false, onchange = function()
        rainEdited = true
        schedule()
      end }
  end

  dlg:tab{ id = "colorsTab", text = "Colors" }
  local refreshPalette = PaletteUI.add(dlg, palette, schedule, function()
    return Aseprite.rgba(dlg.data.paintColor)
  end)

  dlg:tab{ id = "mapsTab", text = "Maps & Masks" }
  if not existing then
    dlg:combobox{ id = "heightSource", label = "Initial Height", options = heightOptions,
      option = preferredHeight or "Art Luminance", onchange = schedule }
  end
  dlg:button{ id = "editMetal", text = "Edit Metal Map", onclick = function() apply("metal") end }
  dlg:button{ id = "editHeight", text = "Edit Height Map", onclick = function() apply("height") end }
  dlg:label{ text = "White exposes metal on the Metal Map." }
  dlg:label{ text = "White marks raised areas on the Height Map." }
  dlg:combobox{ id = "maskEffect", label = "Effect Mask", options = maskOptions, option = "Rust" }
  dlg:samerow()
  dlg:button{ id = "editEffectMask", text = "Edit Mask", hexpand = false,
    onclick = function() apply(maskKeys[dlg.data.maskEffect]) end }
  local startTab = mapsGroup and site.layer and site.layer.parent == mapsGroup
                   and "mapsTab" or "paintTab"
  dlg:endtabs{ id = "paintEditorTab", align = Align.LEFT, selected = startTab }

  dlg:button{ id = "apply", text = mapVisible and "Show Result" or (existing and "Update Material" or "Apply Paint"),
    focus = true, enabled = false, onclick = function() apply() end }
  dlg:button{ text = "Cancel" }
  timer = Timer{ interval = 0.10, ontick = function()
    timer:stop()
    update()
  end }
  refreshPalette()
  schedule()
  dlg:show{ autoscrollbars = true }
end

return DialogUI
