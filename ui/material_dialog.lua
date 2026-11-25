local Aseprite = require("lib.aseprite")
local Common = require("ui.common")
local Composer = require("lib.composer")
local Effects = require("lib.effect_registry")
local LayerInspector = require("ui.material_layer")
local Library = require("ui.material_library")
local Lighting = require("lib.material_lighting")
local LightingPanel = require("ui.lighting_panel")
local Live = require("lib.linked_live")
local Native = require("lib.linked_native")
local Normal = require("lib.normal")
local PaintDialog = require("ui.paint_dialog")
local PaintNative = require("lib.paint_native")
local Catalog = require("lib.material_catalog")
local Project = require("lib.material_project")
local Workspace = require("lib.workspace")

local MaterialDialog = {}
local compareChannel, sphereChannel = "Compare", "Sphere"
local layerLimit, visibleLayers, rowHeight = 8, 4, 16
local panelFields = {
  materialTab = { "recipe", "library", "patternAmount", "patternScale", "palette", "baseColors",
    "seed", "presets", "paintExisting", "editSource" },
  layersTab = { "layerStack", "add", "remove", "up", "down" },
  lightingTab = { "heightSource" },
  outputTab = { "useSelection", "seamless", "mapChannel", "openMap", "flatten" },
}
local fit = Align.BOTTOM | Align.LEFT

local function clone(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = clone(item) end
  return out
end

local function shortName(name)
  local stop = utf8.offset(name, 27)
  return stop and name:sub(1, stop - 1) .. "…" or name
end

local function drawComparison(gc, sphere, artwork)
  local width = gc.width // 2
  local height = gc.height - 17
  local left = Rectangle(0, 17, width - 1, height)
  local right = Rectangle(width + 1, 17, gc.width - width - 1, height)
  gc.color = Color{ r = 29, g = 30, b = 32 }
  gc:fillRect(Rectangle(0, 0, gc.width, gc.height))
  Library.drawPreview(gc, sphere, left)
  Common.drawPixelPreview(gc, artwork, false, right)
  gc.color = Color{ r = 224, g = 225, b = 224 }
  Common.centerText(gc, "Sphere", 0, 3, width)
  Common.centerText(gc, "On Sprite", width, 3, gc.width - width)
end

local function drawLayers(gc, layers, selected, offset)
  gc.color = Color{ r = 30, g = 32, b = 33 }
  gc:fillRect(Rectangle(0, 0, gc.width, gc.height))
  for row = 0, visibleLayers - 1 do
    local index = #layers - offset - row
    local layer = layers[index]
    if not layer then break end
    local y = row * rowHeight
    if index == selected then
      gc.color = Color{ r = 67, g = 73, b = 74 }
      gc:fillRect(Rectangle(0, y, gc.width, rowHeight))
    elseif row > 0 then
      gc.color = Color{ r = 47, g = 49, b = 50 }
      gc:fillRect(Rectangle(0, y, gc.width, 1))
    end
    gc.color = layer.enabled == false and Color{ r = 166, g = 169, b = 167 }
      or Color{ r = 234, g = 235, b = 232 }
    gc:fillText(layer.name or layer.style, 7, y + 3)
    local amount = layer.enabled == false and "Off" or tostring(layer.amount or 100) .. "%"
    gc:fillText(amount, gc.width - gc:measureText(amount).width - 8, y + 3)
  end
  if #layers > visibleLayers then
    local range = ("%d–%d of %d"):format(offset + 1, offset + visibleLayers, #layers)
    gc.color = Color{ r = 181, g = 184, b = 182 }
    gc:fillText(range, gc.width - gc:measureText(range).width - 8, visibleLayers * rowHeight + 2)
  end
end

function MaterialDialog.open(plugin, site, project)
  site = project and project.site or site
  local sprite = site.sprite
  if not sprite then return end
  local excluded = Native.list(sprite)
  for _, group in ipairs(Project.list(sprite)) do excluded[#excluded + 1] = group end
  for _, group in ipairs(PaintNative.list(sprite)) do excluded[#excluded + 1] = group end
  local sourceOptions, sourceLayers, firstMap = Common.surfaceSources(site, excluded)
  local saved = project and project.settings or {}
  local recipe = Catalog.recipe(saved.recipeId or "Metal") or Catalog.recipe("Metal")
  if saved.palette and #saved.palette > 0 then recipe.palette = clone(saved.palette) end
  local layers = saved.layers or recipe.layers
  local selected, listOffset, nextLayerId = math.max(1, #layers), 0, saved.nextLayerId or 0
  local function assignIds(force)
    for _, layer in ipairs(layers) do
      if force or not layer.id then
        nextLayerId = nextLayerId + 1
        layer.id = "layer-" .. nextLayerId
      end
    end
  end
  assignIds()
  local initialHeight = firstMap or "Art Luminance"
  if project then
    initialHeight = saved.heightMode == "Flat" and "Flat" or "Art Luminance"
    for label, layer in pairs(sourceLayers) do
      if layer == saved.heightLayer then initialHeight = label; break end
    end
  end
  local target, rect, heights, targetError, preview, sphere, sphereSample, comparisonArt
  local timer, refreshInspector
  local activeTab
  local targetName = site.layer and shortName(site.layer.name) or "Active layer"
  local dlg = Dialog{
    title = "Substanceprite - Materials", resizeable = true,
    autofit = fit,
    onclose = function() if timer then timer:stop() end end,
  }

  local function settings()
    local data = dlg.data
    local heightLayer = sourceLayers[data.heightSource]
    return LightingPanel.read(data, {
      layers = layers, heights = heights, palette = recipe.palette, paletteName = "Palette - " .. recipe.name,
      paletteAmount = data.palette, seamless = data.seamless, seed = data.seed,
      recipeId = recipe.id, recipe = recipe, nextLayerId = nextLayerId, masks = saved.masks,
      patternAmount = data.patternAmount, patternScale = data.patternScale,
      heightMode = heightLayer and "Height Map Layer" or (data.heightSource == "Flat" and "Flat" or "Luminance"),
      heightLayer = heightLayer, useSelection = data.useSelection,
      normalStrength = data.strength, smoothing = data.smoothing, invertGreen = data.invertGreen,
      rotation = data.rotation,
    })
  end

  local lastStatus
  local function status(value)
    if value == lastStatus then return end
    dlg:modify{ id = "status", text = value }
    lastStatus = value
  end

  local function layerButtons()
    dlg:modify{ id = "add", enabled = #layers < layerLimit }
    dlg:modify{ id = "remove", enabled = #layers > 0 }
    dlg:modify{ id = "up", enabled = selected < #layers }
    dlg:modify{ id = "down", enabled = selected > 1 }
    local layer = layers[selected]
    local isChips = layer and layer.kind == "Deposits" and layer.style == "Paint Chips"
    local canLink = isChips and sprite.colorMode == ColorMode.RGB and target ~= nil and target.read ~= nil
      and layer.enabled ~= false and (layer.mask == "Whole Surface" or heights ~= nil)
    dlg:modify{ id = "link", visible = activeTab == "layersTab" and isChips, enabled = canLink }
    local useMask = layer ~= nil and sprite.colorMode == ColorMode.RGB
    dlg:modify{ id = "editMask", visible = activeTab == "layersTab" and useMask == true, enabled = target ~= nil }
  end

  local function scheduleView()
    if not timer then return end
    timer:stop()
    timer:start()
  end

  local function schedule()
    sphereSample, comparisonArt = nil, nil
    scheduleView()
  end

  local function scheduleLighting()
    comparisonArt = nil
    scheduleView()
  end

  local function selectLayer(index)
    if not layers[index] then return end
    selected = index
    local row = #layers - index
    listOffset = math.max(0, math.min(listOffset, #layers - visibleLayers, row))
    listOffset = math.max(listOffset, row - visibleLayers + 1)
    refreshInspector()
    layerButtons()
    scheduleView()
  end

  local function update()
    local data = dlg.data
    local channel, current = data.channel, settings()
    local hasArtwork = target and target.read ~= nil
    local canApply = hasArtwork and Aseprite.rgbPainter(target.site) ~= nil
    local canPreviewArtwork = hasArtwork
      and (canApply or channel == "Normal Map" or channel == Workspace.heightChannel or Lighting.isMap(channel))
    local canShowSphere = channel == sphereChannel or channel == compareChannel
    local message
    preview, sphere = nil, nil
    if canShowSphere then
      sphereSample = sphereSample or Workspace.materialSample(recipe, current)
      sphere = Workspace.renderSphere(sphereSample, current, 100)
    end
    if canApply and channel == compareChannel then
      if not comparisonArt then comparisonArt, message = Workspace.preview(target, current, rect, "Color") end
      preview = comparisonArt
    elseif canPreviewArtwork and channel ~= sphereChannel then
      preview, message = Workspace.preview(target, current, rect, channel)
    end
    if canPreviewArtwork then
      local scope = data.useSelection and "selection" or "layer pixels"
      local crop = (rect.width < target.width or rect.height < target.height) and " · detail preview" or ""
      if channel == sphereChannel then crop = "" end
      status(message or ("%s · %s · %d × %d px%s"):format(targetName, scope, target.width, target.height, crop))
    else
      status(targetError or "Choose a raster layer with visible artwork to apply.")
    end
    dlg:modify{ id = "bake", enabled = canApply == true }
    dlg:modify{ id = "flatten", enabled = canApply == true }
    dlg:modify{ id = "openMap", enabled = hasArtwork == true }
    dlg:repaint()
  end

  local function changeHeight()
    heights = nil
    local source = dlg.data.heightSource
    if target and target.read and source ~= "Flat" then
      local values, count = Aseprite.heightSamples(target, sourceLayers[source])
      if count > 0 then heights = values end
    end
    dlg:modify{ id = "heightHint", visible = activeTab == "lightingTab" and source ~= "Flat" and heights == nil }
    refreshInspector()
    layerButtons()
    schedule()
  end

  local function changeTarget()
    if project then
      target, targetError = project.target, project.message
    else
      target, targetError = Aseprite.textureTarget(site, dlg.data.useSelection and "Auto" or "Layer Pixels")
    end
    rect = target and Common.previewArea(target)
    changeHeight()
  end

  local function lightingVisibility()
    local channel = dlg.data.channel
    LightingPanel.visibility(dlg, activeTab == "lightingTab", channel)
    dlg:modify{ id = "rotation", visible = activeTab == "lightingTab" and channel == sphereChannel }
  end

  local function changeChannel()
    lightingVisibility()
    refreshInspector()
    scheduleView()
  end

  local function outputVisibility()
    local visible = activeTab == "outputTab" and dlg.data.mapChannel == "Normal Map"
    for _, id in ipairs({ "strength", "smoothing", "invertGreen" }) do dlg:modify{ id = id, visible = visible } end
  end

  local function changePage(ev)
    if not timer or activeTab == ev.tab then return end
    local previous = activeTab
    activeTab = ev.tab
    dlg.autofit = 0
    for page, fields in pairs(panelFields) do
      -- Aseprite reserves space for every tab, including inactive tabs.
      if not previous or page == previous or page == activeTab then
        for _, id in ipairs(fields) do dlg:modify{ id = id, visible = page == activeTab } end
      end
    end
    refreshInspector(activeTab == "layersTab")
    layerButtons()
    lightingVisibility()
    outputVisibility()
    dlg:modify{ id = "heightHint", visible = activeTab == "lightingTab"
      and dlg.data.heightSource ~= "Flat" and heights == nil }
    dlg.autofit = fit
    dlg:modify{ id = "status", visible = true }
    scheduleView()
  end

  local function selectRecipe(name)
    recipe = Catalog.recipe(name) or Catalog.recipe("Metal")
    layers = recipe.layers
    assignIds(true)
    dlg:modify{ id = "recipe", option = recipe.name }
    dlg:modify{ id = "palette", value = recipe.paletteAmount }
    listOffset = 0
    selected = math.max(1, #layers)
    selectLayer(#layers)
    schedule()
  end

  local function move(direction)
    local destination = selected + direction
    if not layers[destination] then return end
    layers[destination], layers[selected] = layers[selected], layers[destination]
    selectLayer(destination)
    schedule()
  end

  local function savePreset()
    local data = dlg.data
    return LightingPanel.read(data, {
      recipe = recipe.id, paletteAmount = data.palette, layers = clone(layers),
      palette = clone(recipe.palette),
      patternAmount = data.patternAmount, patternScale = data.patternScale,
      seamless = data.seamless, seed = data.seed, normalStrength = data.strength,
      smoothing = data.smoothing, invertGreen = data.invertGreen, rotation = data.rotation,
    })
  end

  local function loadPreset(saved)
    selectRecipe(saved.recipe)
    layers = clone(saved.layers)
    if saved.palette and #saved.palette > 0 then recipe.palette = clone(saved.palette) end
    assignIds(true)
    dlg:modify{ id = "palette", value = saved.paletteAmount }
    dlg:modify{ id = "patternAmount", value = saved.patternAmount or 100 }
    dlg:modify{ id = "patternScale", value = saved.patternScale or 100 }
    dlg:modify{ id = "seed", text = tostring(saved.seed) }
    dlg:modify{ id = "seamless", selected = saved.seamless }
    dlg:modify{ id = "strength", value = saved.normalStrength }
    dlg:modify{ id = "smoothing", value = saved.smoothing }
    dlg:modify{ id = "invertGreen", selected = saved.invertGreen }
    dlg:modify{ id = "rotation", value = saved.rotation or 0 }
    LightingPanel.load(dlg, saved)
    lightingVisibility()
    selected = math.max(1, #layers)
    selectLayer(#layers)
    refreshInspector()
    layerButtons()
    schedule()
  end

  local function linkChips()
    local effect = clone(layers[selected])
    local data = dlg.data
    effect.seed, effect.seamless = effect.seed or data.seed, data.seamless
    effect.heightLayer = sourceLayers[data.heightSource]
    effect.heightMode = effect.heightLayer and "Height Map Layer"
                        or (data.heightSource == "Art Luminance" and "Luminance" or "Flat")
    effect.placement = effect.mask == "Whole Surface" and "Material" or effect.mask
    effect.surfaceStrength = effect.surfaceStrength or Effects.controls("Paint Chips").surfaceStrength
    effect.shadows = data.shadows and heights ~= nil
    if effect.shadows then
      effect.shadowAngle, effect.shadowElevation = (-data.lightAngle) % 360, data.lightElevation
      effect.shadowReach, effect.shadowSoftness, effect.shadowStrength =
        data.shadowReach, data.shadowSoftness, data.shadowStrength
    end
    local group, message = Native.create(target, effect)
    if not group then
      status(message)
      return
    end
    Live.track(sprite)
    dlg:close()
    app.layer = group
  end

  local function bakeLayers()
    local images, message = Workspace.layerImages(target, settings())
    if not images or #images == 0 then
      status(message or "This material makes no visible change.")
      return
    end
    local applied = Aseprite.addMaterialGroup(target, images, "Material - " .. recipe.name, project and project.group)
    if sprite.colorMode == ColorMode.RGB then app.layer = applied end
    dlg:close()
  end

  local function apply(maskId)
    if sprite.colorMode ~= ColorMode.RGB then bakeLayers(); return end
    local current = settings()
    current.createMask = maskId
    local applied, message = Project.apply(target, current, project)
    if not applied then status(message); return end
    Live.track(sprite)
    dlg:close()
    if maskId then Project.editMask(applied, maskId, site.frame)
    else Project.showResult(applied, site.frame) end
  end

  dlg:combobox{ id = "channel", label = "Preview", option = compareChannel,
    options = { compareChannel, "Color", sphereChannel, "Lit", Workspace.heightChannel, "Normal Map",
      Lighting.aoChannel, Lighting.shadowChannel },
    onchange = changeChannel }
  dlg:canvas{ id = "preview", width = 336, height = 134,
    onpaint = function(ev)
      local channel = dlg.data.channel
      if channel == compareChannel then
        drawComparison(ev.context, sphere, preview)
      elseif channel == sphereChannel then
        Library.drawPreview(ev.context, sphere)
      else
        Common.drawPixelPreview(ev.context, preview)
      end
    end }

  dlg:tab{ id = "materialTab", text = "Material" }
  dlg:combobox{ id = "recipe", label = "Material", options = Catalog.names, option = recipe.name,
    onchange = function()
      local name = dlg.data.recipe
      if name ~= recipe.name then selectRecipe(name) end
    end }
  dlg:samerow()
  dlg:button{ id = "library", text = "Browse…", hexpand = false, onclick = function()
    Library.open(dlg, recipe.name, function(name)
      if name ~= recipe.name then selectRecipe(name) end
    end)
  end }
  dlg:slider{ id = "palette", label = "Palette Match", min = 0, max = 100,
    value = saved.paletteAmount or recipe.paletteAmount, onchange = schedule }
  dlg:button{ id = "baseColors", text = "Base Colors…", hexpand = false, onclick = function()
    local editor = Dialog{ title = "Base Colors", parent = dlg }
    local defaults = Catalog.recipe(recipe.id).palette
    for i, shade in ipairs(recipe.palette) do
      editor:color{ id = "shade" .. i, label = ("Tone %d"):format(i), color = Aseprite.color(shade) }
    end
    editor:button{ text = "Use Colors", focus = true, onclick = function()
      for i in ipairs(recipe.palette) do recipe.palette[i] = Aseprite.rgba(editor.data["shade" .. i]) end
      editor:close()
      schedule()
    end }
    editor:button{ text = "Reset", onclick = function()
      for i, shade in ipairs(defaults) do editor:modify{ id = "shade" .. i, color = Aseprite.color(shade) } end
    end }
    editor:button{ text = "Cancel" }
    editor:show()
  end }
  dlg:slider{ id = "patternAmount", label = "Pattern Strength", min = 0, max = 100,
    value = saved.patternAmount or 100, onchange = schedule }
  dlg:slider{ id = "patternScale", label = "Pattern Scale", min = 25, max = 250,
    value = saved.patternScale or 100, onchange = schedule }
  dlg:number{ id = "seed", label = "Seed", text = tostring(saved.seed or 1), decimals = 0, onchange = schedule }
  dlg:button{ id = "presets", text = "User Presets…", hexpand = false, onclick = function()
    Common.presets(dlg, plugin, "materialPresets", savePreset, loadPreset)
  end }
  dlg:samerow()
  dlg:button{ id = "paintExisting", text = "Paint Existing Metal…",
    enabled = sprite.colorMode == ColorMode.RGB, onclick = function()
      local paintSite = project and {sprite = sprite, layer = project.group, frame = site.frame} or site
      local context, message = PaintNative.context(paintSite)
      if not context then
        status(message or "Select the metal layer or group to paint.")
        return
      end
      dlg:close()
      PaintDialog.open(paintSite, context)
    end }
  dlg:button{ id = "editSource", text = "Edit Source", enabled = project ~= nil,
    onclick = function()
      dlg:close()
      Project.editSource(project.group, site.frame)
    end }

  dlg:tab{ id = "layersTab", text = "Layers" }
  dlg:canvas{ id = "layerStack", width = 315, height = visibleLayers * rowHeight + 13,
    onpaint = function(ev) drawLayers(ev.context, layers, selected, listOffset) end,
    onmousedown = function(ev)
      if ev.button == MouseButton.LEFT and ev.y >= 0 and ev.y < visibleLayers * rowHeight then
        selectLayer(#layers - listOffset - ev.y // rowHeight)
      end
    end,
    onkeydown = function(ev)
      if ev.code == "ArrowUp" or ev.code == "ArrowDown" then
        selectLayer(selected + (ev.code == "ArrowUp" and 1 or -1))
        ev:stopPropagation()
      end
    end,
    onwheel = function(ev)
      local bottom = math.max(0, #layers - visibleLayers)
      local shift = ev.deltaY > 0 and 1 or (ev.deltaY < 0 and -1 or 0)
      listOffset = math.max(0, math.min(bottom, listOffset + shift))
      dlg:repaint()
    end }
  dlg:button{ id = "add", text = "Add Effect", onclick = function()
    if #layers >= layerLimit then return end
    layers[#layers + 1] = Composer.newLayer("Deposits", "Dirt")
    assignIds()
    selectLayer(#layers)
    schedule()
  end }
  dlg:button{ id = "remove", text = "Remove", onclick = function()
    if #layers == 0 then return end
    table.remove(layers, selected)
    selected = math.max(1, math.min(selected, #layers))
    selectLayer(selected)
    refreshInspector()
    layerButtons()
    schedule()
  end }
  dlg:button{ id = "up", text = "Move Up", onclick = function() move(1) end }
  dlg:button{ id = "down", text = "Move Down", onclick = function() move(-1) end }
  refreshInspector = LayerInspector.add(dlg, function()
    return layers[selected], target ~= nil or dlg.data.channel == sphereChannel
  end, function()
    layerButtons()
    schedule()
  end)
  dlg:button{ id = "link", text = "Link Paint Chips", visible = false, onclick = linkChips }
  dlg:button{ id = "editMask", text = "Edit Painted Mask", visible = false,
    onclick = function() if layers[selected] then apply(layers[selected].id) end end }

  dlg:tab{ id = "lightingTab", text = "Lighting" }
  dlg:combobox{ id = "heightSource", label = "Height Source", options = sourceOptions,
    option = initialHeight, onchange = changeHeight }
  dlg:label{ id = "heightHint", text = "The height source has no pixels in this area.", visible = false }
  LightingPanel.add(dlg, saved, function()
    lightingVisibility()
    scheduleLighting()
  end, scheduleLighting)
  dlg:slider{ id = "rotation", label = "Sphere Rotation", min = 0, max = 359,
    value = saved.rotation or 0, visible = false, onchange = scheduleView }

  dlg:tab{ id = "outputTab", text = "Output" }
  local hasSelection = not sprite.selection.isEmpty
  dlg:check{ id = "useSelection", text = "Use selection", enabled = not project and hasSelection,
    selected = project and saved.useSelection == true or (not project and hasSelection), onclick = changeTarget }
  dlg:check{ id = "seamless", text = "Seamless", selected = saved.seamless == true, onclick = schedule }
  dlg:combobox{ id = "mapChannel", label = "Map", option = "Normal Map",
    options = { "Normal Map", Workspace.heightChannel, Lighting.aoChannel, Lighting.shadowChannel }, onchange = function()
      dlg:modify{ id = "channel", option = dlg.data.mapChannel }
      outputVisibility()
      changeChannel()
    end }
  dlg:slider{ id = "strength", label = "Normal Strength", min = 0, max = 200,
    value = saved.normalStrength or Normal.defaults.strength, visible = false, onchange = scheduleLighting }
  dlg:slider{ id = "smoothing", label = "Smoothing", min = 0, max = 3, visible = false,
    value = saved.smoothing or 1, onchange = scheduleLighting }
  dlg:check{ id = "invertGreen", text = "Invert green (Y)", selected = saved.invertGreen == true,
    visible = false, onclick = scheduleView }
  dlg:button{ id = "openMap", text = "Open Map Sprite", enabled = false, hexpand = false, onclick = function()
    local channel, current = dlg.data.mapChannel, settings()
    local normal = channel == "Normal Map"
    local image = normal and Workspace.normalImage(target, current, true)
      or Workspace.lightMapImage(target, current, channel)
    dlg:close()
    Workspace.openMapSprite(image, normal and "Tangent-space Normal" or channel)
  end }
  dlg:button{ id = "flatten", text = "Bake Effect Layers", enabled = false, onclick = bakeLayers }
  dlg:endtabs{ id = "editorTab", align = Align.LEFT, selected = "materialTab", onchange = changePage }

  dlg:label{ id = "status", text = " " }
  dlg:button{ id = "bake", text = project and "Update Material" or "Apply Material",
    enabled = false, focus = true, onclick = function() apply() end }
  dlg:button{ text = "Close" }

  timer = Timer{ interval = 0.08, ontick = function()
    timer:stop()
    update()
  end }
  changePage{ tab = "materialTab" }
  changeTarget()
  changeChannel()
  dlg:show{ autoscrollbars = true }
end

return MaterialDialog
