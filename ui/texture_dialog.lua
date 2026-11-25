local Texture = require("lib.texture")
local Material = require("lib.material")
local Surface = require("lib.surface")
local Aseprite = require("lib.aseprite")
local Common = require("ui.common")
local Deposits = require("lib.deposits")
local Lighting = require("lib.lighting")
local Native = require("lib.linked_native")
local Live = require("lib.linked_live")
local ShadowControls = require("ui.shadow_controls")
local TextureDialog = {}
local finishMode, depositsMode = "Material Finish", "Deposits"

local patternSliders = {
  { id = "density", label = "Density", min = 0, max = 100 },
  { id = "scale", label = "Scale", min = 1, max = 64 },
  { id = "intensity", label = "Intensity", min = 0, max = 100 },
  { id = "clustering", label = "Clustering", min = 0, max = 100 },
}

local surfaceSliders = {
  { id = "edge", label = "Edge Bias", min = 0, max = 100 },
  { id = "bottom", label = "Bottom Bias", min = 0, max = 100 },
}

local sliders = { table.unpack(patternSliders) }
for _, slider in ipairs(surfaceSliders) do sliders[#sliders + 1] = slider end

local colorIds = { "low", "mid", "high" }
local colorLabels = { low = "Dark Tone", mid = "Midtone", high = "Light Tone" }
local linkedStages = { "chips", "rust", "trails", "shadows" }

local function depositControls(settings)
  if settings.mode == depositsMode then return Deposits.controls(settings.style) end
end

local function styleColors(style)
  local values = {}
  for i, rgba in ipairs(Deposits.defaultColors(style)) do
    values[colorIds[i]] = Aseprite.color(rgba)
  end
  return values
end

local function parseSeed(text)
  local digits = text:match("^%s*([+-]?%d+)%s*$")
  local seed = digits and math.tointeger(tonumber(digits))
  if seed and seed >= -2147483648 and seed <= 4294967295 then return seed end
end

local function renderBase(target, rect)
  local image = Image(rect.width, rect.height, ColorMode.RGB)
  if target.read then
    local rgba = app.pixelColor.rgba
    for y = 0, rect.height - 1 do
      for x = 0, rect.width - 1 do
        local r, g, b, a = target.read(target.x + rect.x + x, target.y + rect.y + y)
        if a > 0 then image:drawPixel(x, y, rgba(r, g, b, a)) end
      end
    end
  end
  return image
end

local function generator(settings)
  if settings.mode == finishMode then return Material.generate end
  return Deposits.generator(settings.style)
end

local function texturePaint(target, settings)
  if settings.mode == finishMode then return Aseprite.materialPaint(target, settings) end
  return Aseprite.depositPaint(target, settings)
end

local function renderTexture(target, settings, paint, image, rect, preview)
  local levels = generator(settings)(target.width, target.height, settings, target.mask, rect)
  local rgba = app.pixelColor.rgba
  local count = 0
  for y = 0, rect.height - 1 do
    for x = 0, rect.width - 1 do
      local level = levels[y * rect.width + x + 1]
      if level > 0 then
        local u, v = rect.x + x, rect.y + y
        local pixel, r, g, b, a = paint(level, u, v, target.alphaAt(u, v))
        if pixel ~= nil then
          image:drawPixel(x, y, preview and rgba(r, g, b, a) or pixel)
          count = count + 1
        end
      end
    end
  end
  return count
end

local function linkedPreview(stages, width, base, rect)
  local image = Image(base)
  for _, name in ipairs(linkedStages) do
    local pixels = stages[name]
    if pixels then
      local overlay = Image(rect.width, rect.height, ColorMode.RGB)
      for y = 0, rect.height - 1 do
        for x = 0, rect.width - 1 do
          local pixel = pixels[(rect.y + y) * width + rect.x + x + 1]
          if pixel and pixel ~= 0 then overlay:putPixel(x, y, pixel) end
        end
      end
      image:drawImage(overlay, Point(0, 0))
    end
  end
  return image
end

function TextureDialog.open(plugin, site, initialStyle)
  if not site.sprite then return end
  local initial = Material.preset(Material.styles[1])
  initial.edge, initial.bottom = Texture.defaults.edge, Texture.defaults.bottom
  local sourceOptions, sourceLayers, firstHeightMap = Common.surfaceSources(site, Native.list(site.sprite))
  local surfaceHeights, surfaceError
  local surfaceChosen
  local target, targetError, rect, base, preview, repeatPreview
  local timer
  local dlg = Dialog{
    title = "Texture Generator", resizeable = false, autofit = Align.TOP | Align.LEFT,
    onclose = function()
      if timer then timer:stop() end
    end,
  }

  local function createsLinked(settings)
    return site.sprite.colorMode == ColorMode.RGB and settings.mode == depositsMode
           and settings.style == "Paint Chips" and target and target.read
  end

  local function read()
    local data = dlg.data
    local seed = parseSeed(data.seed)
    if not seed then return nil, "Enter a seed from -2147483648 to 4294967295." end
    local settings = {
      mode = data.mode, style = data.style, seed = seed, seamless = data.seamless,
      surfaceConfig = {
        source = data.surfaceSource, placement = data.placement,
        strength = data.amount, invert = data.invert,
      },
    }
    for _, slider in ipairs(sliders) do settings[slider.id] = data[slider.id] end
    if data.mode == finishMode then
      settings.direction, settings.form = data.direction, data.form
    else
      settings.colors = {}
      settings.lighting = data.lighting
      for i, id in ipairs(colorIds) do settings.colors[i] = Aseprite.rgba(data[id]) end
      local controls = depositControls(settings)
      if controls then
        settings.softness, settings.runoff = data.softness, data.runoff
        if controls.trails then settings.trails = data.trails end
      end
      if settings.style == "Paint Chips" then ShadowControls.read(data, settings) end
    end
    return settings
  end

  local function engineSettings()
    local settings, message = read()
    if not settings then return nil, message end
    local config = settings.surfaceConfig
    if createsLinked(settings) then
      settings.heightLayer = sourceLayers[config.source]
      settings.heightMode = config.source == "Flat" and "Flat"
                            or (config.source == "Art Luminance" and "Luminance" or "Height Map Layer")
      settings.heightInvert, settings.placement, settings.surfaceStrength =
        config.invert, config.placement, config.strength
      return settings
    end
    if config.source ~= "Flat" and (config.strength > 0 or (settings.runoff or 0) > 0
        or (settings.trails or 0) > 0) then
      if not surfaceHeights then return nil, surfaceError end
      settings.surface = {
        heights = surfaceHeights, placement = config.placement, strength = config.strength,
      }
    end
    return settings
  end

  local lastStatus, applyEnabled, applyLabel
  local function status(message, enabled)
    if message ~= lastStatus then
      dlg:modify{ id = "status", text = message }
      lastStatus = message
    end
    if enabled ~= applyEnabled then
      dlg:modify{ id = "apply", enabled = enabled }
      applyEnabled = enabled
    end
  end

  local function update()
    preview, repeatPreview = nil, false
    if not target then
      status(targetError, false)
    else
      local settings, message = engineSettings()
      local paint, stages
      local linked = settings and createsLinked(settings)
      if linked then
        stages, message = Native.preview(target, settings)
      elseif settings then
        paint, message = texturePaint(target, settings)
      end
      local label = linked and "Apply Linked Layers" or "Apply to New Layer"
      if applyLabel ~= label then
        dlg:modify{ id = "apply", text = label }
        applyLabel = label
      end
      preview = base
      if stages or paint then
        if stages then
          preview = linkedPreview(stages, target.width, base, rect)
        else
          local overlay = Image(rect.width, rect.height, ColorMode.RGB)
          renderTexture(target, settings, paint, overlay, rect, true)
          preview = Image(base)
          preview:drawImage(overlay, Point(0, 0))
        end
        local dimensions = ("%d x %d px"):format(target.width, target.height)
        if rect.width < target.width or rect.height < target.height then
          dimensions = dimensions .. "  |  Detail preview"
        elseif settings.seamless and rect.width <= 152 and rect.height <= 64 then
          repeatPreview = true
          dimensions = dimensions .. "  |  2 x 2 repeat"
        end
        if site.sprite.colorMode == ColorMode.INDEXED then
          dimensions = dimensions .. "  |  Indexed palette"
        end
        if linked and settings.shadows and not surfaceHeights then
          status("Cast shadows need a height source.", true)
        else
          status(dimensions, true)
        end
      else
        status(message, false)
      end
    end
    dlg:repaint()
  end

  local function schedule()
    timer:stop()
    timer:start()
  end

  local function refreshDepositControls()
    local data = dlg.data
    local controls = depositControls(data)
    dlg:modify{ id = "softness", visible = controls ~= nil }
    dlg:modify{ id = "runoff", visible = controls ~= nil,
      label = controls and controls.label, enabled = surfaceHeights ~= nil or (controls and not controls.requiresHeight) }
    dlg:modify{ id = "trails", visible = controls ~= nil and controls.trails ~= nil }
    ShadowControls.visibility(dlg, not not createsLinked(data), surfaceHeights ~= nil)
  end

  local function changeSurface()
    local data = dlg.data
    local source = data.surfaceSource
    local useSurface = source ~= "Flat"
    for _, id in ipairs({ "placement", "amount", "invert" }) do
      dlg:modify{ id = id, visible = useSurface }
    end

    surfaceHeights, surfaceError = nil, nil
    if target and useSurface then
      local layer = sourceLayers[source]
      if source ~= "Art Luminance" and not layer then
        surfaceError = "Choose an available height map for this preset."
      else
        local values, count = Aseprite.heightSamples(target, layer, { invert = data.invert })
        if count > 0 then
          surfaceHeights = values
        else
          surfaceError = "The height source has no pixels in this area."
        end
      end
    end
    refreshDepositControls()
    schedule()
  end

  local function changeTarget()
    target, targetError = Aseprite.textureTarget(site, dlg.data.scope)
    dlg:modify{ id = "showOriginal", enabled = target ~= nil }
    if target then
      rect = Common.previewArea(target)
      base = renderBase(target, rect)
    end
    changeSurface()
  end

  local function setColors(values)
    for _, id in ipairs(colorIds) do dlg:modify{ id = id, color = values[id] } end
  end

  local function setStyleControls(mode, style)
    local finish = mode == finishMode
    local styles = finish and Material.styles or Deposits.styles
    dlg:modify{ id = "style", options = styles, option = style or (finish and styles[1] or Texture.defaults.style) }
    dlg:modify{ id = "direction", visible = finish }
    dlg:modify{ id = "form", visible = finish }
    dlg:modify{ id = "lighting", visible = not finish }
    for _, id in ipairs(colorIds) do dlg:modify{ id = id, visible = not finish } end
  end

  local function setProfile(settings)
    for _, slider in ipairs(sliders) do
      local value = settings[slider.id]
      if value ~= nil then dlg:modify{ id = slider.id, value = value } end
    end
  end

  local function changeStyle()
    local data = dlg.data
    if data.mode == finishMode then
      setProfile(Material.preset(data.style))
    else
      setColors(styleColors(data.style))
      local controls = depositControls(data)
      if controls then
        dlg:modify{ id = "softness", value = controls.softness }
        dlg:modify{ id = "runoff", value = controls.runoff }
        if controls.trails then dlg:modify{ id = "trails", value = controls.trails } end
        local profile = Deposits.profile(data.style)
        if profile ~= Texture.defaults then setProfile(profile) end
        if firstHeightMap and not surfaceChosen and data.surfaceSource == "Flat" then
          dlg:modify{ id = "surfaceSource", option = firstHeightMap }
        end
      end
    end
    refreshDepositControls()
    schedule()
  end

  local function load(settings)
    surfaceChosen = true
    local mode = settings.mode or depositsMode
    dlg:modify{ id = "mode", option = mode }
    setStyleControls(mode, settings.style)
    setProfile(settings)
    dlg:modify{ id = "seed", text = tostring(settings.seed) }
    dlg:modify{ id = "seamless", selected = settings.seamless }
    dlg:modify{ id = "lighting", value = settings.lighting or Lighting.defaultMatch }
    local controls = depositControls{ mode = mode, style = settings.style }
    if controls then
      dlg:modify{ id = "softness", value = settings.softness or controls.softness }
      dlg:modify{ id = "runoff", value = settings.runoff or controls.runoff }
      if controls.trails then dlg:modify{ id = "trails", value = settings.trails or controls.trails } end
    end
    if mode == finishMode then
      dlg:modify{ id = "direction", option = settings.direction }
      dlg:modify{ id = "form", option = settings.form }
    else
      local values = {}
      for i, id in ipairs(colorIds) do values[id] = Aseprite.color(settings.colors[i]) end
      setColors(values)
    end
    local config = settings.surfaceConfig or {
      source = "Flat", placement = "Material", strength = Texture.defaultSurfaceStrength, invert = false,
    }
    if config.source ~= "Flat" and config.source ~= "Art Luminance" and not sourceLayers[config.source] then
      if not dlg.data.surfaceSource or dlg.data.surfaceSource ~= config.source then
        local options = { table.unpack(sourceOptions) }
        options[#options + 1] = config.source
        dlg:modify{ id = "surfaceSource", options = options }
      end
    end
    dlg:modify{ id = "surfaceSource", option = config.source }
    dlg:modify{ id = "placement", option = config.placement }
    dlg:modify{ id = "amount", value = config.strength }
    dlg:modify{ id = "invert", selected = config.invert }
    ShadowControls.load(dlg, settings)
    changeSurface()
  end

  local function apply()
    timer:stop()
    if not target then return end
    local settings, message = engineSettings()
    if settings and createsLinked(settings) then
      local linked
      linked, message = Native.create(target, settings)
      if not linked then
        status(message, true)
        return
      end
      Live.track(site.sprite)
      dlg:close()
      app.layer = linked
      return
    end
    local paint
    if settings then paint, message = texturePaint(target, settings) end
    if not paint then
      status(message, false)
      return
    end
    local image = Aseprite.newTextureImage(target)
    local bounds = { x = 0, y = 0, width = target.width, height = target.height }
    if renderTexture(target, settings, paint, image, bounds, false) == 0 then
      status("No visible change. Try stronger settings or another seed.", true)
      return
    end
    Aseprite.addTextureLayer(target, image, settings.style)
    dlg:close()
  end

  dlg:combobox{ id = "mode", label = "Type", option = finishMode, options = { finishMode, depositsMode },
    onchange = function()
      local mode = dlg.data.mode
      setStyleControls(mode)
      if mode == depositsMode then setProfile(Texture.defaults) end
      changeStyle()
    end }
  dlg:combobox{ id = "style", label = "Texture", option = Material.styles[1], options = Material.styles,
    onchange = changeStyle }
  dlg:combobox{ id = "scope", label = "Target", option = "Auto",
    options = { "Auto", "Selection", "Layer Pixels" }, onchange = changeTarget }
  dlg:canvas{ id = "preview", width = 304, height = 128,
    onpaint = function(ev)
      local image = target and (dlg.data.showOriginal and base or preview)
      Common.drawPixelPreview(ev.context, image, repeatPreview)
    end }
  dlg:label{ id = "status", text = " " }
  dlg:check{ id = "showOriginal", text = "Show Original", enabled = false,
    onclick = function() dlg:repaint() end }
  dlg:newrow()

  dlg:tab{ id = "pattern", text = "Pattern" }
  Common.addSliders(dlg, patternSliders, initial, schedule)
  dlg:slider{ id = "softness", label = "Softness", min = 0, max = 100,
    value = Texture.defaultRustSoftness, visible = false, onchange = schedule }
  dlg:check{ id = "seamless", label = "Tiling", text = "Seamless",
    selected = Texture.defaults.seamless, onclick = schedule }
  dlg:entry{ id = "seed", label = "Seed", text = tostring(Texture.defaults.seed), onchange = schedule }
  dlg:button{ text = "New Seed", onclick = function()
    local seed = parseSeed(dlg.data.seed) or Texture.defaults.seed
    dlg:modify{ id = "seed", text = tostring((seed * 1664525 + 1013904223) & 0xffffffff) }
    schedule()
  end }

  dlg:tab{ id = "surface", text = "Surface" }
  dlg:combobox{ id = "surfaceSource", label = "Height Source", option = "Flat",
    options = sourceOptions, onchange = function()
      surfaceChosen = true
      changeSurface()
    end }
  dlg:combobox{ id = "placement", label = "Placement", option = "Material",
    options = Surface.placements, visible = false, onchange = schedule }
  dlg:slider{ id = "amount", label = "Height Influence", min = 0, max = 100,
    value = Texture.defaultSurfaceStrength, visible = false, onchange = schedule }
  dlg:check{ id = "invert", text = "Invert Height", visible = false, onclick = changeSurface }
  Common.addSliders(dlg, surfaceSliders, initial, schedule)
  dlg:slider{ id = "runoff", label = "Runoff", min = 0, max = 100,
    value = Texture.defaultRustRunoff, visible = false, onchange = schedule }
  dlg:slider{ id = "trails", label = "Rust Trails", min = 0, max = 100,
    value = Deposits.controls("Paint Chips").trails, visible = false, onchange = schedule }
  ShadowControls.add(dlg, {}, function()
    refreshDepositControls()
    schedule()
  end, schedule)

  dlg:tab{ id = "appearance", text = "Appearance" }
  dlg:combobox{ id = "direction", label = "Grain Direction", option = "Auto",
    options = Material.directions, onchange = schedule }
  dlg:combobox{ id = "form", label = "Form", option = "Keep Lighting",
    options = Material.forms, onchange = schedule }
  dlg:slider{ id = "lighting", label = "Lighting Match", min = 0, max = 100,
    value = Lighting.defaultMatch, visible = false, onchange = schedule }
  local colors = styleColors(Texture.defaults.style)
  for _, id in ipairs(colorIds) do
    dlg:color{ id = id, label = colorLabels[id], color = colors[id], visible = false, onchange = schedule }
  end
  dlg:endtabs{ id = "settingsTabs", selected = "pattern", align = Align.LEFT }
  dlg:button{ id = "apply", text = "Apply to New Layer", enabled = false, onclick = apply }
  dlg:button{ text = "User Presets…", onclick = function()
    Common.presets(dlg, plugin, "texturePresets", read, load)
  end }
  dlg:button{ text = "Close" }

  timer = Timer{ interval = 0.08, ontick = function()
    timer:stop()
    update()
  end }
  if initialStyle then
    dlg:modify{ id = "mode", option = depositsMode }
    setStyleControls(depositsMode, initialStyle)
    setProfile(Texture.defaults)
    changeStyle()
  end
  changeTarget()
  dlg:show{ autoscrollbars = true }
end

return TextureDialog
