local Aseprite = require("lib.aseprite")
local Common = require("ui.common")
local HeightDialog = {}

function HeightDialog.open(site)
  local dlg = Dialog{ title = "Height Map from Art", resizeable = false }
  local target, targetError, area, heights, preview

  local function update()
    preview = nil
    if target and target.read then
      local data = dlg.data
      heights = Aseprite.heightSamples(target, nil, {
        channel = data.channel, invert = data.invert,
      }, true)
      preview, targetError = Aseprite.heightMapPreview(target, heights, area)
    end
    local message = targetError or "This frame has no raster pixels."
    if preview then
      message = ("%d x %d px  |  White is high"):format(target.width, target.height)
      if site.sprite.colorMode == ColorMode.INDEXED then
        message = message .. "  |  Indexed"
      end
    end
    dlg:modify{ id = "status", text = message }
    dlg:modify{ id = "create", enabled = preview ~= nil }
    dlg:repaint()
  end

  local function changeTarget()
    local scope = dlg.data.useSelection and "Auto" or "Layer Pixels"
    target, targetError = Aseprite.textureTarget(site, scope)
    area = target and Common.previewArea(target)
    update()
  end

  local hasSelection = not site.sprite.selection.isEmpty
  dlg:combobox{ id = "channel", label = "Channel", option = "Luminance",
    options = { "Luminance", "Alpha" }, onchange = update }
  dlg:check{ id = "invert", text = "Invert", onclick = update }
  dlg:check{ id = "useSelection", text = "Use selection",
    enabled = hasSelection, selected = hasSelection, onclick = changeTarget }
  dlg:canvas{ width = 270, height = 104,
    onpaint = function(ev) Common.drawPixelPreview(ev.context, preview) end }
  dlg:label{ id = "status", text = " " }
  dlg:button{ id = "create", text = "Create Height Map Layer", onclick = function()
    if not preview then return end
    local image, message = Aseprite.heightMapImage(target, heights)
    if not image then
      dlg:modify{ id = "status", text = message }
      return
    end
    Aseprite.addHeightMapLayer(target, image)
    dlg:close()
  end }
  dlg:button{ text = "Close" }
  changeTarget()
  dlg:show()
end

return HeightDialog
