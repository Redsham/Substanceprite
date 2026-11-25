local Common = {}

function Common.addSliders(dialog, sliders, values, onChange)
  for _, slider in ipairs(sliders) do
    dialog:slider{
      id = slider.id, label = slider.label,
      min = slider.min, max = slider.max,
      value = values[slider.id], onchange = onChange,
    }
  end
end

function Common.checker(gc, x, y, width, height, size)
  gc.color = Color{ r = 63, g = 62, b = 68 }
  gc:fillRect(Rectangle(x, y, width, height))
  gc.color = Color{ r = 82, g = 80, b = 88 }
  for row = 0, (height - 1) // size do
    for col = row % 2, (width - 1) // size, 2 do
      gc:fillRect(Rectangle(x + col * size, y + row * size,
                            math.min(size, width - col * size),
                            math.min(size, height - row * size)))
    end
  end
end

function Common.centerText(gc, text, x, y, width)
  gc:fillText(text, x + (width - gc:measureText(text).width) // 2, y)
end

function Common.previewArea(target)
  local width, height = math.min(target.width, 144), math.min(target.height, 88)
  local x = math.max(0, math.min(target.width - width, target.focusX - width // 2))
  local y = math.max(0, math.min(target.height - height, target.focusY - height // 2))
  return { x = x, y = y, width = width, height = height }
end

function Common.drawPixelPreview(gc, image, repeatTile, area)
  local left, top, paneWidth, paneHeight = 0, 0, gc.width, gc.height
  if area then left, top, paneWidth, paneHeight = area.x, area.y, area.width, area.height end
  gc.color = Color{ r = 40, g = 39, b = 44 }
  gc:fillRect(Rectangle(left, top, paneWidth, paneHeight))
  if not image then return end

  local repeatCount = repeatTile and 2 or 1
  local scale = math.max(1, math.min(5, paneWidth // (repeatCount * image.width),
                                      paneHeight // (repeatCount * image.height)))
  local tileW, tileH = image.width * scale, image.height * scale
  local width, height = tileW * repeatCount, tileH * repeatCount
  local x, y = left + (paneWidth - width) // 2, top + (paneHeight - height) // 2
  Common.checker(gc, x, y, width, height, 6)
  for row = 0, repeatCount - 1 do
    for col = 0, repeatCount - 1 do
      gc:drawImage(image, 0, 0, image.width, image.height,
                  x + tileW * col, y + tileH * row, tileW, tileH)
    end
  end
end

function Common.surfaceSources(site, excludedGroups)
  local options, layers = { "Flat", "Art Luminance" }, {}
  local firstHeightMap
  local function visit(siblings, prefix)
    for i = 1, #siblings do
      local layer = siblings[i]
      local path = prefix .. layer.name
      if layer.isGroup then
        local excluded = false
        for _, group in ipairs(excludedGroups or {}) do
          if group == layer then
            excluded = true
            break
          end
        end
        if not excluded then visit(layer.layers, path .. " / ") end
      elseif not layer.isTilemap and layer ~= site.layer and layer:cel(site.frame) then
        local cutoff = utf8.offset(path, 33)
        local label = "Map: " .. (cutoff and path:sub(1, cutoff - 1) .. "…" or path)
        local option, number = label, 1
        while layers[option] do
          number = number + 1
          option = label .. (" (%d)"):format(number)
        end
        options[#options + 1], layers[option] = option, layer
        if not firstHeightMap and layer.name:match("^Height Map") then firstHeightMap = option end
      end
    end
  end
  visit(site.sprite.layers, "")
  return options, layers, firstHeightMap
end

function Common.presets(parent, plugin, key, current, load)
  local saved = plugin.preferences[key] or {}
  local empty = "No saved presets"
  local dlg = Dialog{ title = "User Presets", parent = parent }

  local function options()
    local names = {}
    for name in pairs(saved) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then names[1] = empty end
    return names
  end

  local function refresh(selected)
    local names = options()
    local enabled = next(saved) ~= nil
    dlg:modify{ id = "chosen", options = names, option = selected or names[1] }
    dlg:modify{ id = "load", enabled = enabled }
    dlg:modify{ id = "delete", enabled = enabled }
  end

  local function status(message)
    dlg:modify{ id = "message", text = message }
  end

  local names = options()
  dlg:combobox{ id = "chosen", label = "Saved", options = names, option = names[1],
    onchange = function()
      local chosen = dlg.data.chosen
      if saved[chosen] then dlg:modify{ id = "name", text = chosen } end
    end }
  dlg:entry{ id = "name", label = "Name", text = "" }
  dlg:label{ id = "message", text = "Name the current settings to save a preset." }
  dlg:button{ id = "save", text = "Save", onclick = function()
    local name = dlg.data.name:match("^%s*(.-)%s*$")
    if name == "" or name:find("%c") or name == empty then
      status("Enter a valid preset name.")
      return
    end
    local values, message = current()
    if not values then
      status(message)
      return
    end
    if saved[name] and app.alert{
      title = "Replace Preset", text = "Replace " .. name .. "?",
      buttons = { "Replace", "Cancel" },
    } ~= 1 then return end
    saved[name] = values
    plugin.preferences[key] = saved
    refresh(name)
    status("Preset saved.")
  end }
  dlg:button{ id = "load", text = "Load", enabled = next(saved) ~= nil, onclick = function()
    local preset = saved[dlg.data.chosen]
    if preset then
      dlg:close()
      load(preset)
    end
  end }
  dlg:button{ id = "delete", text = "Delete", enabled = next(saved) ~= nil, onclick = function()
    local name = dlg.data.chosen
    if saved[name] then
      saved[name] = nil
      plugin.preferences[key] = saved
      refresh()
      dlg:modify{ id = "name", text = "" }
      status("Preset deleted.")
    end
  end }
  dlg:button{ text = "Close" }
  dlg:show()
end

return Common
