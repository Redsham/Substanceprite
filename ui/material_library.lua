local Common = require("ui.common")
local Catalog = require("lib.material_catalog")
local Workspace = require("lib.workspace")

local Library = {}
local columns, cellWidth, cellHeight = 4, 98, 83
local thumbnailSize = 55
local thumbnails = {}

local function stage(gc, x, y, w, h)
  gc.color = Color{ r = 27, g = 32, b = 33 }
  gc:fillRect(Rectangle(x, y, w, h))
end

local function sphere(gc, image, x, y, width)
  local s = image.width
  local left = x + (width - s) // 2
  gc.color = Color{ r = 17, g = 21, b = 22 }
  gc:beginPath()
  gc:oval(Rectangle(left + s // 8, y + s - 5, s * 3 // 4, 8))
  gc:fill()
  gc:drawImage(image, left, y)
end

function Library.drawPreview(gc, image, area)
  local x, y, width, height = 0, 0, gc.width, gc.height
  if area then x, y, width, height = area.x, area.y, area.width, area.height end
  stage(gc, x, y, width, height)
  if image then sphere(gc, image, x, y + (height - image.height) // 2 - 2, width) end
end

function Library.open(parent, currentName, onChoose)
  local selected = 1
  for i, name in ipairs(Catalog.names) do
    if name == currentName then selected = i end
    if not thumbnails[name] then
      thumbnails[name] = Workspace.materialSphere(Catalog.recipe(name), nil, thumbnailSize)
    end
  end

  local dlg = Dialog{ title = "Material Library", parent = parent, resizeable = false }
  local function choose()
    dlg:close()
    onChoose(Catalog.names[selected])
  end
  local rows = (#Catalog.names + columns - 1) // columns
  dlg:canvas{ id = "materials", width = columns * cellWidth, height = rows * cellHeight,
    onpaint = function(ev)
      local gc = ev.context
      gc.color = Color{ r = 21, g = 25, b = 26 }
      gc:fillRect(Rectangle(0, 0, gc.width, gc.height))
      for i, name in ipairs(Catalog.names) do
        local x, y = (i - 1) % columns * cellWidth, (i - 1) // columns * cellHeight
        stage(gc, x + 3, y + 3, cellWidth - 6, cellHeight - 6)
        if i == selected then
          gc.color = Color{ r = 171, g = 148, b = 100 }
          gc:strokeRect(Rectangle(x + 3, y + 3, cellWidth - 6, cellHeight - 6))
        end
        sphere(gc, thumbnails[name], x, y + 7, cellWidth)
        gc.color = Color{ r = 226, g = 230, b = 225 }
        Common.centerText(gc, name, x, y + 65, cellWidth)
      end
    end,
    onmousedown = function(ev)
      if ev.button ~= MouseButton.LEFT or ev.x < 0 or ev.y < 0
          or ev.x >= columns * cellWidth or ev.y >= rows * cellHeight then return end
      local index = ev.y // cellHeight * columns + ev.x // cellWidth + 1
      if Catalog.names[index] then
        selected = index
        dlg:repaint()
      end
    end,
  }
  dlg:button{ id = "use", text = "Use Material", focus = true, onclick = choose }
  dlg:button{ text = "Close" }
  dlg:show()
end

return Library
