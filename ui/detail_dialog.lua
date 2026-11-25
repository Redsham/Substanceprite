local Aseprite = require("lib.aseprite")
local Alphas = require("lib.detail_alphas")
local AlphaLibrary = require("ui.alpha_library")
local Common = require("ui.common")
local Details = require("lib.prop_details")
local Native = require("lib.detail_native")
local Live = require("lib.linked_live")

local DetailDialog = {}
local visibleRows, rowHeight = 4, 16
local alphaKind = "Alpha Stamp"
local reliefModes = {"Auto", "Raised", "Recessed", "Color Only"}
local neutral = {r = 140, g = 146, b = 148, a = 255}
local placement = {
  {id = "detailX", key = "x", label = "X (%)", min = 0, max = 100},
  {id = "detailY", key = "y", label = "Y (%)", min = 0, max = 100},
  {id = "detailWidth", key = "width", label = "Width (%)", min = 1, max = 100},
  {id = "detailHeight", key = "height", label = "Height (%)", min = 1, max = 100},
  {id = "detailRotation", key = "rotation", label = "Rotation (°)", min = -180, max = 180},
}
local styleFields = {"detailKind", "detailName", "detailEnabled", "detailStrength", "detailColor"}

local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = clone(item) end
  return result
end

local function shortName(value, length)
  local cutoff = utf8.offset(value, length + 1)
  return cutoff and value:sub(1, cutoff - 1) .. "…" or value
end

local function drawStack(gc, entries, selected, offset)
  gc.color = Color{r = 30, g = 32, b = 33}
  gc:fillRect(Rectangle(0, 0, gc.width, gc.height))
  if #entries == 0 then
    gc.color = Color{r = 182, g = 184, b = 182}
    gc:fillText("Add a detail or load a template.", 7, 6)
    return
  end
  for row = 0, visibleRows - 1 do
    local index = #entries - offset - row
    local entry = entries[index]
    if not entry then break end
    local y = row * rowHeight
    if index == selected then
      gc.color = Color{r = 67, g = 73, b = 74}
      gc:fillRect(Rectangle(0, y, gc.width, rowHeight))
    end
    local enabled = entry.enabled ~= false
    gc.color = enabled and Color{r = 234, g = 235, b = 232} or Color{r = 166, g = 169, b = 167}
    gc:fillText(shortName(Details.nameOf(entry), 31), 7, y + 3)
    local state = enabled and ("%d%%"):format(math.floor((tonumber(entry.strength) or 100) + 0.5)) or "Off"
    gc:fillText(state, gc.width - gc:measureText(state).width - 7, y + 3)
  end
  if #entries > visibleRows then
    local range = ("%d–%d of %d"):format(offset + 1, offset + visibleRows, #entries)
    gc.color = Color{r = 182, g = 184, b = 182}
    gc:fillText(range, gc.width - gc:measureText(range).width - 7, visibleRows * rowHeight)
  end
end

local function previewRect(target, entry)
  local width, height = math.min(target.width, 256), math.min(target.height, 120)
  local x = entry and (target.width - 1) * (entry.x or 50) / 100 or target.focusX
  local y = entry and (target.height - 1) * (entry.y or 50) / 100 or target.focusY
  local left = math.floor((x or target.width / 2) - width / 2 + 0.5)
  local top = math.floor((y or target.height / 2) - height / 2 + 0.5)
  return {x = math.max(0, math.min(target.width - width, left)),
    y = math.max(0, math.min(target.height - height, top)), width = width, height = height}
end

function DetailDialog.open(plugin, site)
  local context, contextError = Native.context(site)
  if not context and site.sprite and not site.sprite.selection.isEmpty then
    context, contextError = Native.context(site, false)
  end
  if not context then
    app.alert(contextError or "Select a raster layer or an existing Prop Details group.")
    return
  end
  local initial = context.settings or {}
  local sprite, existing = context.sprite, context.group ~= nil
  local frame = context.frame or (context.site and context.site.frame) or site.frame
  local groups = Native.list and Native.list(sprite) or (existing and { context.group } or {})
  local sources, sourceLayers, firstHeight = Common.surfaceSources({
    sprite = sprite, layer = context.source, frame = frame,
  }, groups)
  local heightSource = initial.heightMode == "Flat" and "Flat" or "Art Luminance"
  if not existing then heightSource = firstHeight or heightSource end
  for name, layer in pairs(sourceLayers) do
    if layer == initial.heightLayer then heightSource = name; break end
  end
  local preset = initial.preset or Details.names[1]
  local entries = clone(initial.entries or Details.preset(preset) or {})
  local selected, offset = #entries, 0
  local used, serial = {}, 0
  local function assignId(entry)
    if entry.id and not used[tostring(entry.id)] then entry.id = tostring(entry.id)
    else
      repeat serial = serial + 1; entry.id = "detail-" .. serial until not used[entry.id]
    end
    used[entry.id] = true
  end
  for _, entry in ipairs(entries) do assignId(entry) end

  local initialEntry = entries[selected] or Details.new(Details.kinds[1])
  local preview, region, previewWidth, previewHeight, timer, syncing, refresh
  local displayedStatus
  local dlg = Dialog{
    title = "Substanceprite - Prop Details", resizeable = true,
    autofit = Align.BOTTOM | Align.LEFT,
    onclose = function() if timer then timer:stop() end end,
  }
  local function status(text)
    if displayedStatus == text then return end
    displayedStatus = text
    dlg:modify{id = "status", text = text}
  end

  local function read()
    local data = dlg.data
    local heightLayer = sourceLayers[data.heightSource]
    local useSelection = data.useSelection
    if useSelection == nil then useSelection = initial.useSelection end
    return {
      entries = entries, preset = preset, seed = data.seed,
      heightMode = heightLayer and "Height Map Layer" or (data.heightSource == "Flat" and "Flat" or "Luminance"),
      heightLayer = heightLayer, useSelection = useSelection, reliefShadows = data.reliefShadows,
    }
  end

  local function update()
    local message
    local target = context and context.target
    if target then
      region = previewRect(target, entries[selected])
      preview, message = Native.preview(context, read(), region, dlg.data.previewMode)
      local crop = (region.width < target.width or region.height < target.height) and " · detail preview" or ""
      status(message or ("%d × %d px%s"):format(target.width, target.height, crop))
    else
      preview = nil
      status(contextError or "Choose artwork with visible pixels.")
    end
    dlg:modify{id = "apply", enabled = preview ~= nil and (#entries > 0 or existing)}
    if Native.editMask then
      dlg:modify{id = "editMask", enabled = preview ~= nil and (#entries > 0 or existing)}
    end
    dlg:repaint()
  end

  local function schedule()
    if not timer then return end
    timer:stop()
    timer:start()
  end

  local function choose(index)
    selected = math.max(0, math.min(#entries, index))
    local activeRow = #entries - selected
    offset = math.max(0, math.min(offset, #entries - visibleRows, activeRow))
    offset = math.max(offset, activeRow - visibleRows + 1)
    refresh()
    schedule()
  end

  local function replace(newEntries, name)
    entries = clone(newEntries)
    preset = name
    used, serial = {}, 0
    for _, entry in ipairs(entries) do assignId(entry) end
    offset = 0
    choose(#entries)
  end

  local function bind(id, key, transform)
    return function()
      local entry = entries[selected]
      if syncing or not entry then return end
      local value = dlg.data[id]
      if transform then value = transform(value) end
      entry[key] = value
      if key == "name" then dlg:modify{id = "placementName", text = Details.nameOf(entry)} end
      dlg:repaint()
      schedule()
    end
  end

  local function move(step)
    local nextIndex = selected + step
    if not entries[selected] or not entries[nextIndex] then return end
    entries[selected], entries[nextIndex] = entries[nextIndex], entries[selected]
    choose(nextIndex)
  end

  local function add(kind, alphaId)
    local entry = Details.new(kind)
    if alphaId then entry.alphaId = alphaId end
    assignId(entry)
    entries[#entries + 1] = entry
    choose(#entries)
  end

  local function addAlpha()
    AlphaLibrary.open(dlg, nil, function(id) add(alphaKind, id) end)
  end

  local function browseAlpha()
    local entry = entries[selected]
    if not entry or entry.kind ~= alphaKind then return end
    AlphaLibrary.open(dlg, entry.alphaId, function(id)
      entry.alphaId = id
      refresh()
      schedule()
    end)
  end

  local function place(ev)
    local entry = entries[selected]
    if dlg.data.detailTabs ~= "placementTab" or ev.button ~= MouseButton.LEFT
        or not entry or not preview or not previewWidth or not context or not context.target then return end
    local scale = math.max(1, math.min(5, previewWidth // preview.width, previewHeight // preview.height))
    local left, top = (previewWidth - preview.width * scale) // 2, (previewHeight - preview.height * scale) // 2
    local x, y = (ev.x - left) // scale, (ev.y - top) // scale
    if x < 0 or x >= preview.width or y < 0 or y >= preview.height then return end
    local target = context.target
    entry.x = math.floor((region.x + x + 0.5) * 100 / target.width + 0.5)
    entry.y = math.floor((region.y + y + 0.5) * 100 / target.height + 0.5)
    refresh()
    schedule()
  end

  local function apply(action)
    if not context or not context.target then return end
    local group, message = Native.apply(context, read())
    if not group then
      status(message or "Unable to apply prop details.")
      return
    end
    Live.track(sprite)
    if action then
      local ok, failure = action(group)
      if not ok and failure then
        status(failure)
        return
      end
    end
    dlg:close()
  end

  dlg:combobox{id = "previewMode", label = "Preview", option = "Result",
    options = {"Result", "Original", "Height Map", "Mask"}, onchange = schedule}
  dlg:canvas{id = "preview", width = 342, height = 126,
    onpaint = function(ev)
      previewWidth, previewHeight = ev.context.width, ev.context.height
      Common.drawPixelPreview(ev.context, preview)
    end,
    onmousedown = place}
  dlg:label{id = "status", text = " "}

  dlg:tab{id = "detailsTab", text = "Details"}
  dlg:combobox{id = "template", label = "Template", options = Details.names, option = preset or Details.names[1]}
  dlg:samerow()
  dlg:button{id = "loadTemplate", text = "Load", hexpand = false, onclick = function()
    local name = dlg.data.template
    local template = Details.preset(name)
    if template then replace(template, name) end
  end}
  dlg:button{id = "addAlpha", text = "Add Alpha…", hexpand = false, onclick = addAlpha}
  dlg:canvas{id = "detailStack", width = 342, height = visibleRows * rowHeight + 20,
    onpaint = function(ev) drawStack(ev.context, entries, selected, offset) end,
    onmousedown = function(ev)
      if ev.button == MouseButton.LEFT and ev.y >= 0 and ev.y < visibleRows * rowHeight then
        local index = #entries - offset - ev.y // rowHeight
        if entries[index] then choose(index) end
      end
    end,
    onkeydown = function(ev)
      if ev.code == "ArrowUp" or ev.code == "ArrowDown" then
        local index = selected + (ev.code == "ArrowUp" and 1 or -1)
        if entries[index] then choose(index) end
        ev:stopPropagation()
      end
    end,
    onwheel = function(ev)
      local delta = ev.deltaY > 0 and 1 or (ev.deltaY < 0 and -1 or 0)
      offset = math.max(0, math.min(#entries - visibleRows, offset + delta))
      dlg:repaint()
    end}
  dlg:combobox{id = "addKind", label = "New Detail", options = Details.kinds, option = Details.kinds[1]}
  dlg:samerow()
  dlg:button{id = "add", text = "Add", hexpand = false, onclick = function()
    local kind = dlg.data.addKind
    if kind == alphaKind then addAlpha() else add(kind) end
  end}
  dlg:button{id = "remove", text = "Remove", onclick = function()
    table.remove(entries, selected)
    choose(math.min(selected, #entries))
  end}
  dlg:button{id = "up", text = "Move Up", onclick = function() move(1) end}
  dlg:button{id = "down", text = "Move Down", onclick = function() move(-1) end}
  if plugin then
    dlg:button{id = "presets", text = "Presets…", onclick = function()
      Common.presets(dlg, plugin, "propDetailPresets", function()
        return {entries = clone(entries), preset = preset, seed = dlg.data.seed,
          reliefShadows = dlg.data.reliefShadows}
      end, function(saved)
        dlg:modify{id = "seed", text = tostring(saved.seed or 1)}
        dlg:modify{id = "reliefShadows", selected = saved.reliefShadows ~= false}
        if saved.preset then dlg:modify{id = "template", option = saved.preset} end
        replace(saved.entries or {}, saved.preset)
      end)
    end}
  end

  dlg:tab{id = "placementTab", text = "Placement"}
  dlg:label{id = "placementName", label = "Detail", text = Details.nameOf(initialEntry)}
  dlg:label{id = "placementHint", text = "Click the preview or use the sliders to place it."}
  for _, slider in ipairs(placement) do
    dlg:slider{id = slider.id, label = slider.label, min = slider.min, max = slider.max,
      value = initialEntry[slider.key] or 0, onchange = bind(slider.id, slider.key)}
  end

  dlg:tab{id = "styleTab", text = "Style"}
  dlg:combobox{id = "detailKind", label = "Type", options = Details.kinds, option = initialEntry.kind,
    onchange = function()
      local entry, kind = entries[selected], dlg.data.detailKind
      if syncing or not entry or kind == entry.kind then return end
      local fresh = Details.new(kind)
      for _, slider in ipairs(placement) do fresh[slider.key] = entry[slider.key] end
      fresh.id, fresh.enabled, fresh.name, fresh.strength = entry.id, entry.enabled, entry.name, entry.strength
      entries[selected] = fresh
      choose(selected)
    end}
  dlg:samerow()
  dlg:check{id = "detailEnabled", text = "Enabled", selected = initialEntry.enabled ~= false,
    onclick = bind("detailEnabled", "enabled")}
  dlg:entry{id = "detailName", label = "Name", text = initialEntry.name or "",
    onchange = bind("detailName", "name", function(name) return name ~= "" and name or nil end)}
  dlg:slider{id = "detailStrength", label = "Strength", min = 0, max = 100,
    value = initialEntry.strength or 100, onchange = bind("detailStrength", "strength")}
  dlg:color{id = "detailColor", label = "Color", color = Aseprite.color(initialEntry.color or neutral),
    onchange = bind("detailColor", "color", Aseprite.rgba)}
  dlg:entry{id = "detailText", label = "Text", text = initialEntry.text or "",
    onchange = bind("detailText", "text")}
  dlg:slider{id = "detailCount", label = "Count", min = 1, max = 16,
    value = initialEntry.count or 1, onchange = bind("detailCount", "count")}
  dlg:label{id = "detailAlpha", label = "Alpha", text = "", visible = false}
  dlg:samerow()
  dlg:button{id = "browseAlpha", text = "Browse…", hexpand = false, visible = false, onclick = browseAlpha}
  dlg:combobox{id = "detailRelief", label = "Relief", options = reliefModes, option = "Auto", visible = false,
    onchange = bind("detailRelief", "reliefMode")}

  dlg:tab{id = "targetTab", text = "Target"}
  dlg:label{label = "Source", text = shortName(context.source.name, 35)}
  if not existing and not sprite.selection.isEmpty then
    dlg:check{id = "useSelection", text = "Use selection", selected = initial.useSelection == true,
      onclick = function()
        context, contextError = Native.context(site, dlg.data.useSelection)
        schedule()
      end}
  end
  dlg:combobox{id = "heightSource", label = "Height Source", options = sources, option = heightSource,
    onchange = schedule}
  dlg:check{id = "reliefShadows", text = "Relief Shadows", selected = initial.reliefShadows ~= false,
    onclick = schedule}
  dlg:number{id = "seed", label = "Seed", text = tostring(initial.seed or 1), decimals = 0, onchange = schedule}
  if Native.editMask then
    dlg:button{id = "editMask", text = "Edit Mask", enabled = false, onclick = function() apply(Native.editMask) end}
  end
  if existing and Native.showResult then
    dlg:button{id = "showResult", text = "Show Result", onclick = function() apply(Native.showResult) end}
  end
  dlg:endtabs{id = "detailTabs", align = Align.LEFT, selected = "detailsTab"}
  dlg:button{id = "apply", text = existing and "Update Details" or "Apply Details", focus = true,
    enabled = false, onclick = function() apply() end}
  dlg:button{text = "Cancel"}

  refresh = function()
    local entry = entries[selected]
    local show = entry ~= nil
    syncing = true
    dlg:modify{id = "remove", enabled = show}
    dlg:modify{id = "up", enabled = show and selected < #entries}
    dlg:modify{id = "down", enabled = show and selected > 1}
    dlg:modify{id = "placementName", text = entry and Details.nameOf(entry) or "Select a detail in Details."}
    dlg:modify{id = "placementHint", visible = show}
    for _, slider in ipairs(placement) do
      dlg:modify{id = slider.id, visible = show, value = entry and (entry[slider.key] or 0)}
    end
    for _, id in ipairs(styleFields) do dlg:modify{id = id, visible = show} end
    local defaults = entry and Details.new(entry.kind)
    dlg:modify{id = "detailText", visible = defaults and defaults.text ~= nil or false}
    dlg:modify{id = "detailCount", visible = defaults and defaults.count ~= nil or false}
    local isAlpha = entry ~= nil and entry.kind == alphaKind
    if isAlpha then
      local alpha = Alphas.get(entry.alphaId or Alphas.default) or Alphas.get(Alphas.default)
      dlg:modify{id = "detailAlpha", text = alpha.name}
      dlg:modify{id = "detailRelief", option = entry.reliefMode or "Auto"}
    end
    dlg:modify{id = "detailAlpha", visible = isAlpha}
    dlg:modify{id = "browseAlpha", visible = isAlpha}
    dlg:modify{id = "detailRelief", visible = isAlpha}
    if entry then
      dlg:modify{id = "detailKind", option = entry.kind}
      dlg:modify{id = "detailName", text = entry.name or ""}
      dlg:modify{id = "detailEnabled", selected = entry.enabled ~= false}
      dlg:modify{id = "detailStrength", value = entry.strength or 100}
      dlg:modify{id = "detailColor", color = Aseprite.color(entry.color or defaults.color or neutral)}
      dlg:modify{id = "detailText", text = entry.text or defaults.text or ""}
      dlg:modify{id = "detailCount", value = entry.count or defaults.count or 1}
    end
    syncing = false
    dlg:repaint()
  end

  timer = Timer{interval = 0.09, ontick = function() timer:stop(); update() end}
  refresh()
  schedule()
  dlg:show{autoscrollbars = true}
  return dlg
end

return DetailDialog
