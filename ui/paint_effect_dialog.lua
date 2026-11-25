local Common = require("ui.common")

local EffectDialog = {}

function EffectDialog.create(options)
  local specs = options.specs
  local changes = {}
  for key, value in pairs(options.saved or {}) do changes[key] = value end
  local accepted, syncing = false, false
  local dialog = Dialog{
    parent = options.parent,
    title = options.name .. " Settings",
    onclose = function()
      options.closed()
      if not accepted then options.changed(options.saved, options.amount) end
    end,
  }

  local function update()
    local saved = {}
    for key, value in pairs(changes) do saved[key] = value end
    options.changed(next(saved) and saved or nil, dialog.data.effectAmount)
  end

  dialog:canvas{ id = "effectPreview", width = 300, height = 112,
    onpaint = function(ev) Common.drawPixelPreview(ev.context, options.preview()) end }
  dialog:slider{ id = "effectAmount", label = "Amount", min = 0, max = 100,
    value = options.amount, onchange = update }
  for _, spec in ipairs(specs) do
    local id = spec.id
    local function changed()
      if syncing then return end
      local value = dialog.data[id]
      if value == options.fallback[id] then value = nil end
      changes[id] = value
      update()
    end
    if spec.options then
      dialog:combobox{ id = id, label = spec.label, options = spec.options,
        option = options.values[id], onchange = changed }
    else
      dialog:slider{ id = id, label = spec.label, min = spec.min, max = spec.max,
        value = options.values[id], onchange = changed }
    end
  end
  dialog:button{ id = "resetPattern", text = "Reset Pattern", onclick = function()
    syncing = true
    changes = {}
    for _, spec in ipairs(specs) do
      local id, default = spec.id, spec.default
      if default ~= options.fallback[id] then changes[id] = default end
      if spec.options then
        dialog:modify{ id = id, option = default }
      else
        dialog:modify{ id = id, value = default }
      end
    end
    syncing = false
    update()
  end }
  dialog:button{ id = "saveEffect", text = "OK", focus = true, onclick = function()
    accepted = true
    dialog:close()
  end }
  dialog:button{ id = "cancelEffect", text = "Cancel", onclick = function() dialog:close() end }
  return dialog
end

return EffectDialog
