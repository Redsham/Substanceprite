local Common = require("ui.common")
local Lighting = require("lib.material_lighting")
local Panel = require("ui.lighting_panel")
local Native = require("lib.scene_lighting_native")
local Live = require("lib.linked_live")

local LightingDialog = {}
local compare = "Compare"
local channels = {compare, "Result", "Original", Lighting.aoChannel, Lighting.shadowChannel, "Height Map", "Mask"}

local function drawComparison(gc, original, result)
  local middle = gc.width // 2
  local captions = 16
  local height = gc.height - captions
  gc.color = Color{r = 29, g = 30, b = 32}
  gc:fillRect(Rectangle(0, 0, gc.width, gc.height))
  Common.drawPixelPreview(gc, original, false, Rectangle(0, captions, middle - 1, height))
  Common.drawPixelPreview(gc, result, false, Rectangle(middle + 1, captions, gc.width - middle - 1, height))
  gc.color = Color{r = 228, g = 229, b = 226}
  Common.centerText(gc, "Original", 0, 2, middle)
  Common.centerText(gc, "Result", middle, 2, gc.width - middle)
end

local function disk(gc, x, y, radius)
  gc:beginPath()
  gc:oval(Rectangle(x - radius, y - radius, radius * 2 + 1, radius * 2 + 1))
  gc:fill()
end

local function drawDirection(gc, angle)
  local x, y = gc.width // 2, gc.height // 2
  local radius = math.min(x, y) - 6
  gc.color = Color{r = 31, g = 34, b = 34}
  gc:fillRect(Rectangle(0, 0, gc.width, gc.height))
  gc.color = Color{r = 101, g = 106, b = 103}
  disk(gc, x, y, radius)
  gc.color = Color{r = 40, g = 45, b = 44}
  disk(gc, x, y, radius - 1)
  gc.color = Color{r = 110, g = 115, b = 110}
  gc:fillRect(Rectangle(x - radius, y, radius * 2 + 1, 1))
  gc:fillRect(Rectangle(x, y - radius, 1, radius * 2 + 1))
  local radians = math.rad(angle)
  local dx, dy = math.cos(radians), -math.sin(radians)
  gc.color = Color{r = 228, g = 191, b = 119}
  for i = 0, radius - 1 do
    gc:fillRect(Rectangle(x + math.floor(dx * i + 0.5), y + math.floor(dy * i + 0.5), 1, 1))
  end
  disk(gc, x + math.floor(dx * radius + 0.5), y + math.floor(dy * radius + 0.5), 3)
end

function LightingDialog.open(plugin, site)
  local context, contextError = Native.context(site)
  if not context and site.sprite and not site.sprite.selection.isEmpty then
    context, contextError = Native.context(site, false)
  end
  if not context then
    app.alert(contextError or "Open an RGB sprite with visible artwork.")
    return
  end

  local sprite, existing = context.sprite, context.group ~= nil
  local initial = context.settings or {}
  local options, heightLayers, firstHeight = Common.surfaceSources(
    {sprite = sprite, frame = context.frame}, Native.list(sprite))
  local heightSource = initial.heightMode == "Flat" and "Flat" or "Art Luminance"
  if not existing and initial.heightMode ~= "Flat" then heightSource = firstHeight or heightSource end
  for name, layer in pairs(heightLayers) do
    if layer == initial.heightLayer then heightSource = name; break end
  end

  local original, preview, timer, padWidth, padHeight, lastStatus
  local dlg = Dialog{
    title = "Substanceprite - Lighting", resizeable = true,
    autofit = Align.BOTTOM | Align.LEFT,
    onclose = function() if timer then timer:stop() end end,
  }

  local function status(text)
    if text == lastStatus then return end
    lastStatus = text
    dlg:modify{id = "status", text = text}
  end

  local function settings()
    local data = dlg.data
    local heightLayer = heightLayers[data.heightSource]
    local useSelection = data.useSelection
    if useSelection == nil then useSelection = initial.useSelection == true end
    return Panel.read(data, {
      heightLayer = heightLayer,
      heightMode = heightLayer and "Height Map Layer" or (data.heightSource == "Flat" and "Flat" or "Luminance"),
      useSelection = useSelection,
    })
  end

  local function update()
    local target = context and context.target
    if target then
      local rect = Common.previewArea(target)
      local current, channel = settings(), dlg.data.previewMode
      local reason
      if channel == compare then
        original = original or Native.preview(context, current, rect, "Original")
        preview, reason = Native.preview(context, current, rect, "Result")
      else
        preview, reason = Native.preview(context, current, rect, channel)
      end
      local size = ("%d × %d px"):format(target.width, target.height)
      if rect.width < target.width or rect.height < target.height then size = size .. " · detail preview" end
      status(reason or size)
    else
      preview, original = nil, nil
      status(contextError or "Choose a scene with visible pixels.")
    end
    dlg:modify{id = "apply", enabled = preview ~= nil}
    dlg:repaint()
  end

  local function schedule()
    if not timer then return end
    timer:stop()
    timer:start()
  end

  local function lightControls()
    local data = dlg.data
    local active = data.lightingTabs == nil or data.lightingTabs == "lightTab"
    local directional = active and (data.directLight or data.shadows or data.previewMode == Lighting.shadowChannel)
    Panel.visibility(dlg, active, data.previewMode)
    for _, id in ipairs({"directionPad", "lightAngle", "lightElevation"}) do
      dlg:modify{id = id, visible = directional == true}
    end
    schedule()
  end

  local function aim(ev)
    if ev.button ~= MouseButton.LEFT or not padWidth then return end
    local x, y = ev.x - padWidth // 2, padHeight // 2 - ev.y
    if x == 0 and y == 0 then return end
    local angle = math.floor(math.deg(math.atan(y, x)) + 0.5) % 360
    dlg:modify{id = "lightAngle", value = angle}
    dlg:repaint()
    schedule()
  end

  local function changeTarget(useSelection)
    context, contextError = Native.context(site, useSelection)
    original = nil
    schedule()
  end

  local function apply(action)
    if not context or not context.target then return end
    local group, message = Native.apply(context, settings())
    if not group then
      status(message or "Unable to apply scene lighting.")
      return
    end
    Live.track(sprite)
    if action then
      local changed, reason = action(group)
      if not changed and reason then
        status(reason)
        return
      end
    end
    dlg:close()
  end

  dlg:combobox{id = "previewMode", label = "Preview", options = channels, option = compare,
    onchange = lightControls}
  dlg:canvas{id = "preview", width = 380, height = 136,
    onpaint = function(ev)
      if dlg.data.previewMode == compare then drawComparison(ev.context, original, preview)
      else Common.drawPixelPreview(ev.context, preview) end
    end}
  dlg:label{id = "status", text = " "}

  dlg:tab{id = "lightTab", text = "Light"}
  dlg:canvas{id = "directionPad", label = "Aim", width = 58, height = 40, hexpand = false,
    onpaint = function(ev)
      padWidth, padHeight = ev.context.width, ev.context.height
      drawDirection(ev.context, dlg.data.lightAngle or Lighting.defaults.angle)
    end,
    onmousedown = aim}
  dlg:samerow()
  Panel.add(dlg, initial, lightControls, schedule)

  dlg:tab{id = "targetTab", text = "Target"}
  dlg:combobox{id = "heightSource", label = "Height Source", options = options, option = heightSource,
    onchange = schedule}
  local activeSelection = not sprite.selection.isEmpty
  if activeSelection or initial.useSelection then
    dlg:check{id = "useSelection", text = "Use selection", selected = initial.useSelection == true,
      onclick = function() changeTarget(dlg.data.useSelection) end}
    if existing and activeSelection then
      dlg:button{id = "retarget", text = "Use Current Selection", hexpand = false, onclick = function()
        dlg:modify{id = "useSelection", selected = true}
        changeTarget(true)
      end}
    end
  end
  if Native.editMask then
    dlg:button{id = "editMask", text = "Edit Mask", hexpand = false,
      onclick = function() apply(Native.editMask) end}
  end
  if existing and Native.showResult then
    dlg:button{id = "showResult", text = "Show Result", hexpand = false,
      onclick = function() apply(Native.showResult) end}
  end
  dlg:endtabs{id = "lightingTabs", align = Align.LEFT, selected = "lightTab", onchange = lightControls}
  dlg:button{id = "apply", text = existing and "Update Lighting" or "Apply Lighting", enabled = false,
    focus = true, onclick = function() apply() end}
  dlg:button{text = "Cancel"}

  timer = Timer{interval = 0.09, ontick = function() timer:stop(); update() end}
  lightControls()
  dlg:show{autoscrollbars = true}
  return dlg
end

return LightingDialog
