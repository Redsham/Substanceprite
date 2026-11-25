local Alphas = require("lib.detail_alphas")
local Common = require("ui.common")

local Library = {}
local columns, rows = 5, 2
local cellWidth, cellHeight = 83, 61
local thumbnailWidth, thumbnailHeight = 48, 33
local pageSize = columns * rows
local categories, thumbnails = {"All"}, {}
for _, category in ipairs(Alphas.categories) do categories[#categories + 1] = category end

local function render(id, width, height, shaded)
  local sample = assert(Alphas.sampler(id, width, height, 1))
  local image = Image(width, height, ColorMode.RGB)
  local rgba = app.pixelColor.rgba
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local coverage, _, tone = sample(x, y)
      if coverage > 0 then
        local alpha = math.floor(math.min(1, coverage) * 255 + 0.5)
        local value = shaded and math.floor(math.max(145, math.min(255, 232 + 46 * (tone or 0))) + 0.5) or 255
        image:putPixel(x, y, rgba(value, value, value, alpha))
      end
    end
  end
  return image
end

local function thumbnail(id)
  if not thumbnails[id] then
    thumbnails[id] = render(id, thumbnailWidth, thumbnailHeight, true)
  end
  return thumbnails[id]
end

local function fitted(gc, name)
  if gc:measureText(name).width <= cellWidth - 10 then return name end
  local length = utf8.len(name)
  for stop = length, 2, -1 do
    local shortened = name:sub(1, utf8.offset(name, stop) - 1) .. "..."
    if gc:measureText(shortened).width <= cellWidth - 10 then return shortened end
  end
  return "..."
end

local function drawTile(gc, option, x, y, selected)
  local panel = Rectangle(x + 2, y + 2, cellWidth - 4, cellHeight - 4)
  gc.color = selected and Color{r = 48, g = 54, b = 54} or Color{r = 32, g = 36, b = 36}
  gc:fillRect(panel)
  if selected then
    gc.color = Color{r = 175, g = 149, b = 99}
    gc:strokeRect(panel)
  end
  local left, top = x + (cellWidth - thumbnailWidth) // 2, y + 7
  Common.checker(gc, left, top, thumbnailWidth, thumbnailHeight, 5)
  gc:drawImage(thumbnail(option.id), left, top)
  gc.color = Color{r = 232, g = 233, b = 229}
  Common.centerText(gc, fitted(gc, option.name), x, y + 45, cellWidth)
end

local function openSprite(option)
  local image = render(option.id, 64, 64, false)
  local sprite = Sprite(image.width, image.height, ColorMode.RGB)
  local cel = sprite.cels[1]
  cel.layer.name, cel.image = option.name, image
  app.refresh()
  return sprite
end

function Library.open(parent, currentId, onChoose)
  local current = Alphas.get(currentId or Alphas.default) or Alphas.get(Alphas.default)
  local category = parent and current.category or "All"
  local matches, selected, page = {}, 1, 1
  local redraw
  local dlg = Dialog{title = "Alpha Library", parent = parent, resizeable = false,
    onclose = function() if redraw then redraw:stop() end end}

  local function update()
    local option = matches[selected]
    dlg:modify{id = "selectedAlpha", text = option and option.name or "No alphas in this category."}
    dlg:modify{id = "previous", enabled = page > 1}
    dlg:modify{id = "next", enabled = page * pageSize < #matches}
    dlg:modify{id = "page", text = #matches == 0 and "" or
      ("%d–%d of %d"):format((page - 1) * pageSize + 1, math.min(page * pageSize, #matches), #matches)}
    dlg:modify{id = "useAlpha", enabled = option ~= nil}
    dlg:repaint()
  end

  local function choose(index)
    if not matches[index] then return end
    selected = index
    page = (index - 1) // pageSize + 1
    update()
  end

  local function filter(name, id)
    matches = Alphas.list(name ~= "All" and name or nil)
    selected, page = 1, 1
    for i, option in ipairs(matches) do
      if option.id == id then
        selected, page = i, (i - 1) // pageSize + 1
        break
      end
    end
    update()
  end

  local function finish()
    local option = matches[selected]
    if not option then return end
    dlg:close()
    if onChoose then onChoose(option.id) else openSprite(option) end
  end

  dlg:combobox{id = "category", label = "Category", options = categories, option = category,
    onchange = function() filter(dlg.data.category, matches[selected] and matches[selected].id) end}
  dlg:canvas{id = "alphas", width = columns * cellWidth, height = rows * cellHeight,
    onpaint = function(ev)
      local gc = ev.context
      gc.color = Color{r = 21, g = 25, b = 26}
      gc:fillRect(Rectangle(0, 0, gc.width, gc.height))
      local start = (page - 1) * pageSize
      for cell = 0, pageSize - 1 do
        local index = start + cell + 1
        local option = matches[index]
        if not option then break end
        drawTile(gc, option, cell % columns * cellWidth, cell // columns * cellHeight, index == selected)
      end
    end,
    onmousedown = function(ev)
      if ev.button ~= MouseButton.LEFT or ev.x < 0 or ev.x >= columns * cellWidth
          or ev.y < 0 or ev.y >= rows * cellHeight then return end
      choose((page - 1) * pageSize + (ev.y // cellHeight) * columns + ev.x // cellWidth + 1)
    end,
    onkeydown = function(ev)
      local steps = {ArrowLeft = -1, ArrowRight = 1, ArrowUp = -columns, ArrowDown = columns}
      local step = steps[ev.code]
      if step then
        choose(selected + step)
        ev:stopPropagation()
      end
    end}
  dlg:button{id = "previous", text = "Previous", hexpand = false,
    onclick = function() choose((page - 2) * pageSize + 1) end}
  dlg:samerow()
  dlg:label{id = "page", text = ""}
  dlg:samerow()
  dlg:button{id = "next", text = "Next", hexpand = false,
    onclick = function() choose(page * pageSize + 1) end}
  dlg:newrow()
  dlg:label{id = "selectedAlpha", label = "Selected", text = current.name}
  dlg:button{id = "useAlpha", text = onChoose and "Use Alpha" or "Open Alpha Sprite", focus = true, onclick = finish}
  dlg:button{text = "Close"}
  filter(category, current.id)
  redraw = Timer{interval = 0.05, ontick = function() redraw:stop(); dlg:repaint() end}
  redraw:start()
  dlg:show()
  return dlg
end

return Library
