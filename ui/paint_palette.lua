local Aseprite = require("lib.aseprite")
local Colors = require("lib.paint_colors")

local PaletteUI = {}
local tones = {
  { id = "pigmentShadow", label = "Shadow" },
  { id = "pigmentMidtone", label = "Midtone" },
  { id = "pigmentHighlight", label = "Highlight" },
}

local function sameColor(a, b)
  return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a
end

function PaletteUI.add(dlg, palette, changed, paintColor)
  local options, definitions = {}, {}
  local initial
  for _, definition in ipairs(Colors.definitions) do
    options[#options + 1] = definition.label
    definitions[definition.label] = definition
    if definition.id == "rust" then initial = definition.label end
  end
  local syncing

  local function current()
    return definitions[dlg.data.pigmentEffect] or definitions[initial]
  end

  local function refresh()
    local definition = current()
    local isMetal = definition.id == "metal"
    local isPaint = definition.id == "paint"
    local colors = Colors.get(palette, definition.id)
    syncing = true
    dlg:modify{ id = "tintMetal", visible = isMetal, selected = isMetal and palette.metal ~= nil }
    dlg:modify{ id = "customPaintRamp", visible = isPaint, selected = isPaint and palette.paint ~= nil }
    if definition.count == 1 then
      dlg:modify{ id = "pigmentTint", visible = not isMetal or palette.metal ~= nil,
        color = Aseprite.color(colors) }
      for _, tone in ipairs(tones) do dlg:modify{ id = tone.id, visible = false } end
    else
      dlg:modify{ id = "pigmentTint", visible = false }
      for i, tone in ipairs(tones) do
        dlg:modify{ id = tone.id, visible = not isPaint or palette.paint ~= nil, color = Aseprite.color(colors[i]) }
      end
    end
    dlg:modify{ id = "paintColor", enabled = palette.paint == nil }
    dlg:modify{ id = "resetPigment", enabled = palette[definition.id] ~= nil }
    syncing = false
  end

  dlg:combobox{ id = "pigmentEffect", label = "Effect", option = initial, options = options, onchange = refresh }
  dlg:check{ id = "tintMetal", text = "Tint Exposed Metal", visible = false, onclick = function()
    if syncing or current().id ~= "metal" then return end
    palette.metal = dlg.data.tintMetal and Colors.get(palette, "metal") or nil
    refresh()
    changed()
  end }
  dlg:check{ id = "customPaintRamp", text = "Use Custom Paint Ramp", visible = false, onclick = function()
    if syncing or current().id ~= "paint" then return end
    palette.paint = dlg.data.customPaintRamp and (palette.paint or Colors.paintRamp(paintColor())) or nil
    refresh()
    changed()
  end }
  dlg:color{ id = "pigmentTint", label = "Tint", color = Color{ r = 190, g = 185, b = 172 },
    visible = false, onchange = function()
      if syncing then return end
      local definition = current()
      if definition.count ~= 1 or (definition.id == "metal" and not palette.metal) then return end
      local color = Aseprite.rgba(dlg.data.pigmentTint)
      if sameColor(Colors.get(palette, definition.id), color) then return end
      palette[definition.id] = color
      dlg:modify{ id = "resetPigment", enabled = true }
      changed()
    end }
  for i, tone in ipairs(tones) do
    local rust = Colors.get(palette, "rust")
    dlg:color{ id = tone.id, label = tone.label, color = Aseprite.color(rust[i]), onchange = function()
      if syncing then return end
      local definition = current()
      if definition.count == 1 or (definition.id == "paint" and not palette.paint) then return end
      local colors = Colors.get(palette, definition.id)
      local color = Aseprite.rgba(dlg.data[tone.id])
      if sameColor(colors[i], color) then return end
      colors[i] = color
      palette[definition.id] = colors
      dlg:modify{ id = "resetPigment", enabled = true }
      changed()
    end }
  end
  dlg:button{ id = "resetPigment", text = "Reset Effect Colors", onclick = function()
    palette[current().id] = nil
    refresh()
    changed()
  end }
  return refresh
end

return PaletteUI
