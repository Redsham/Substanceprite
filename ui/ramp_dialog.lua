local Ramp = require("lib.color")
local Aseprite = require("lib.aseprite")
local Common = require("ui.common")
local RampDialog = {}

local sliders = {
  { id = "hueShift", label = "Hue Shift", min = -60, max = 60 },
  { id = "saturation", label = "Saturation", min = -100, max = 100 },
  { id = "lightness", label = "Lightness", min = 0, max = 60 },
  { id = "contrast", label = "Contrast", min = 0, max = 100 },
}

local labels = { "Deep", "Shadow", "Base", "Light", "Highlight" }

local function drawRamp(gc, ramp)
  gc.color = Color{ r = 40, g = 39, b = 44 }
  gc:fillRect(Rectangle(0, 0, gc.width, gc.height))
  for i, rgba in ipairs(ramp) do
    local x, right = (i - 1) * gc.width // 5, i * gc.width // 5
    local width = right - x
    Common.checker(gc, x + 1, 15, width - 2, 23, 4)
    gc.color = Aseprite.color(rgba)
    gc:fillRect(Rectangle(x + 1, 15, width - 2, 23))
    gc.color = Color{ r = 228, g = 224, b = 228 }
    Common.centerText(gc, labels[i], x, 3, width)
    Common.centerText(gc, ("%02X%02X%02X"):format(rgba.r, rgba.g, rgba.b), x, 41, width)
  end
end

function RampDialog.open(plugin, sprite, frame)
  if not sprite then return end
  local dlg = Dialog{ title = "Color Ramp Generator", resizeable = false }
  local named = "Neutral"
  local options = { table.unpack(Ramp.presets) }
  options[#options + 1] = "Custom"
  local initial = Ramp.preset(named)
  local base = app.fgColor
  local ramp = Ramp.generate(Aseprite.rgba(base), initial)

  local function read()
    local data, settings = dlg.data, {}
    for _, slider in ipairs(sliders) do settings[slider.id] = data[slider.id] end
    return settings
  end

  local function update()
    ramp = Ramp.generate(Aseprite.rgba(dlg.data.base), read())
    dlg:repaint()
  end

  local function use(settings, label)
    named = label
    for _, slider in ipairs(sliders) do
      dlg:modify{ id = slider.id, value = settings[slider.id] }
    end
    dlg:modify{ id = "preset", option = named }
    update()
  end

  dlg:color{ id = "base", label = "Base Color", color = base, onchange = update }
  dlg:combobox{ id = "preset", label = "Preset", option = named, options = options,
    onchange = function()
      local preset = dlg.data.preset
      if preset ~= "Custom" then use(Ramp.preset(preset), preset) end
    end }
  Common.addSliders(dlg, sliders, initial, function()
    if named ~= "Custom" then
      named = "Custom"
      dlg:modify{ id = "preset", option = named }
    end
    update()
  end)
  dlg:canvas{ id = "preview", width = 285, height = 54,
    onpaint = function(ev) drawRamp(ev.context, ramp) end }
  dlg:label{ id = "status", text = " " }
  dlg:button{ text = "User Presets…", onclick = function()
    Common.presets(dlg, plugin, "colorRampPresets", read, function(preset)
      use(preset, "Custom")
    end)
  end }
  dlg:button{ text = "Add to Palette", onclick = function()
    local added, message = Aseprite.addRamp(sprite, ramp, frame)
    if added then
      if added == 0 then
        message = "These colors are already in the palette."
      else
        message = ("%d color(s) added to the palette."):format(added)
      end
    end
    dlg:modify{ id = "status", text = message }
  end }
  dlg:button{ text = "Close" }
  dlg:show()
end

return RampDialog
