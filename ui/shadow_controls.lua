local CastShadow = require("lib.cast_shadow")

local Controls = {}
local sliders = {
  { id = "shadowAngle", key = "angle", label = "Light Direction (°)", min = 0, max = 359 },
  { id = "shadowElevation", key = "elevation", label = "Light Elevation (°)", min = 5, max = 85 },
  { id = "shadowReach", key = "reach", label = "Relief Depth (px)", min = 0, max = 64 },
  { id = "shadowSoftness", key = "softness", label = "Shadow Softness", min = 0, max = 100 },
  { id = "shadowStrength", key = "strength", label = "Shadow Strength", min = 0, max = 100 },
}

function Controls.add(dlg, settings, onToggle, onChange)
  dlg:check{ id = "shadows", text = "Cast Shadows", selected = settings.shadows == true,
    onclick = onToggle }
  for _, slider in ipairs(sliders) do
    dlg:slider{ id = slider.id, label = slider.label, min = slider.min, max = slider.max,
      visible = false, value = settings[slider.id] or CastShadow.defaults[slider.key],
      onchange = onChange }
  end
end

function Controls.visibility(dlg, available, hasHeight)
  dlg:modify{ id = "shadows", visible = available }
  local visible = available and dlg.data.shadows
  for _, slider in ipairs(sliders) do
    dlg:modify{ id = slider.id, visible = visible, enabled = hasHeight }
  end
end

function Controls.read(data, settings)
  settings.shadows = data.shadows == true
  for _, slider in ipairs(sliders) do settings[slider.id] = data[slider.id] end
end

function Controls.load(dlg, settings)
  dlg:modify{ id = "shadows", selected = settings.shadows == true }
  for _, slider in ipairs(sliders) do
    dlg:modify{ id = slider.id, value = settings[slider.id] or CastShadow.defaults[slider.key] }
  end
end

return Controls
