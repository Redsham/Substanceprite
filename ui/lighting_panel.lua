local AO = require("lib.ambient_occlusion")
local Aseprite = require("lib.aseprite")
local CastShadow = require("lib.cast_shadow")
local Lighting = require("lib.material_lighting")

local Panel = {}
local white = { r = 255, g = 255, b = 255, a = 255 }

local switches = {
  { id = "directLight", text = "Direct Light" },
  { id = "shadows", text = "Cast Shadows" },
  { id = "ao", text = "Ambient Occlusion" },
}
local sliders = {
  { id = "lightAngle", label = "Direction (°)", min = 0, max = 359, default = Lighting.defaults.angle },
  { id = "lightElevation", label = "Elevation (°)", min = 5, max = 85, default = Lighting.defaults.elevation },
  { id = "lightStrength", label = "Light Strength", min = 0, max = 100,
    default = Lighting.defaults.strength, section = "directLight" },
  { id = "shadowStrength", label = "Shadow Strength", min = 0, max = 100,
    default = CastShadow.defaults.strength, section = "shadows" },
  { id = "shadowReach", label = "Relief Depth (px)", min = 0, max = 64,
    default = CastShadow.defaults.reach, section = "shadows", map = Lighting.shadowChannel },
  { id = "shadowSoftness", label = "Shadow Softness", min = 0, max = 100,
    default = CastShadow.defaults.softness, section = "shadows", map = Lighting.shadowChannel },
  { id = "aoStrength", label = "AO Strength", min = 0, max = 100, default = AO.defaults.strength, section = "ao" },
  { id = "aoRadius", label = "AO Radius (px)", min = 0, max = AO.maxRadius,
    default = AO.defaults.radius, section = "ao", map = Lighting.aoChannel },
}

function Panel.add(dlg, settings, toggle, change)
  for index, switch in ipairs(switches) do
    if index > 1 then dlg:samerow() end
    dlg:check{ id = switch.id, text = switch.text, selected = settings[switch.id] == true,
      visible = false, onclick = toggle }
  end
  for _, slider in ipairs(sliders) do
    dlg:slider{ id = slider.id, label = slider.label, min = slider.min, max = slider.max,
      value = settings[slider.id] or slider.default, visible = false, onchange = change }
  end
  dlg:color{ id = "lightColor", label = "Light Tint", color = Aseprite.color(settings.lightColor or white),
    visible = false, onchange = change }
end

function Panel.visibility(dlg, active, channel)
  local data = dlg.data
  for _, switch in ipairs(switches) do dlg:modify{ id = switch.id, visible = active } end
  for _, slider in ipairs(sliders) do
    local shown = not slider.section or data[slider.section] == true or slider.map and channel == slider.map
      or slider.section == "directLight" and channel == "Lit"
    dlg:modify{ id = slider.id, visible = active and shown == true }
  end
  dlg:modify{ id = "lightColor", visible = active and (data.directLight == true or channel == "Lit") }
end

function Panel.read(data, settings)
  for _, switch in ipairs(switches) do settings[switch.id] = data[switch.id] == true end
  for _, slider in ipairs(sliders) do settings[slider.id] = data[slider.id] end
  settings.lightColor = Aseprite.rgba(data.lightColor)
  return settings
end

function Panel.load(dlg, settings)
  for _, switch in ipairs(switches) do dlg:modify{ id = switch.id, selected = settings[switch.id] == true } end
  for _, slider in ipairs(sliders) do
    dlg:modify{ id = slider.id, value = settings[slider.id] or slider.default }
  end
  dlg:modify{ id = "lightColor", color = Aseprite.color(settings.lightColor or white) }
end

return Panel
