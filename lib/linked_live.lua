local Native = require("lib.linked_native")
local Paint = require("lib.paint_native")
local Project = require("lib.material_project")
local Details = require("lib.detail_native")
local SceneLighting = require("lib.scene_lighting_native")

local Live = {}
local session

local writeCommands = {
  SaveFile = true,
  SaveFileAs = true,
  SaveFileCopyAs = true,
  ExportSpriteSheet = true,
  RepeatLastExport = true,
}

local function openSprites()
  local open = {}
  for _, sprite in ipairs(app.sprites) do open[sprite.id] = sprite end
  return open
end

local function forgetClosed(state, open)
  for id in pairs(state.listeners) do
    if not open[id] then state.listeners[id] = nil end
  end
  for id in pairs(state.pending) do
    if not open[id] then state.pending[id] = nil end
  end
end

local function queue(state, id)
  if session ~= state or state.refreshing then return end
  state.pending[id] = true
  state.timer:stop()
  state.timer:start()
end

local function watch(state, sprite, id)
  if state.listeners[id] then return end
  -- The Events userdata belongs to the document. Aseprite deletes it on close.
  -- The callback retains only the ID and generation, even if Aseprite keeps its Lua reference.
  local generation = state.generation
  local function changed()
    local current = session
    if current and current.generation == generation then queue(current, id) end
  end
  local events = sprite.events
  state.listeners[id] = {
    events:on("change", changed),
    events:on("layervisibility", changed),
    events:on("layeropacity", changed),
  }
end

local function refreshPending(state)
  if session ~= state or state.refreshing then return end
  state.timer:stop()
  local pending = state.pending
  if not next(pending) then return end
  state.pending = {}
  state.refreshing = true

  local ok, failure = xpcall(function()
    local open = openSprites()
    forgetClosed(state, open)
    local changed = false
    for id in pairs(pending) do
      local sprite = open[id]
      if sprite then
        local groups = Native.list(sprite)
        local painted = Paint.list(sprite)
        local materials = Project.list(sprite)
        local details = Details.list(sprite)
        local lights = SceneLighting.list(sprite)
        if #groups > 0 or #painted > 0 or #materials > 0 or #details > 0 or #lights > 0 then
          watch(state, sprite, id)
        end
        for _, group in ipairs(groups) do
          if Native.refresh(sprite, group) then changed = true end
        end
        for _, group in ipairs(materials) do
          if Project.refresh(sprite, group) then changed = true end
        end
        for _, group in ipairs(painted) do
          if Paint.refresh(sprite, group) then changed = true end
        end
        for _, group in ipairs(details) do
          if Details.refresh(sprite, group) then changed = true end
        end
        for _, group in ipairs(lights) do
          if SceneLighting.refresh(sprite, group) then changed = true end
        end
      end
    end
    if changed then app.refresh() end
  end, debug.traceback)

  state.refreshing = false
  if not ok then error(failure, 0) end
end

local function currentSpriteId()
  local sprite = app.sprite
  if sprite then return sprite.id end
end

local function siteChanged(state)
  if session ~= state or state.refreshing then return end
  local open = openSprites()
  forgetClosed(state, open)
  local id = currentSpriteId()
  if id == state.activeId then return end
  state.activeId = id
  if open[id] then queue(state, id) end
end

function Live.start()
  if session or not app.isUIAvailable then return end
  local state = { listeners = {}, pending = {}, generation = {}, activeId = currentSpriteId() }
  session = state
  state.timer = Timer{interval = 0.10, ontick = function() refreshPending(state) end}
  local events = app.events
  state.siteListener = events:on("sitechange", function() siteChanged(state) end)
  state.writeListener = events:on("beforecommand", function(ev)
    -- Saving immediately after a stroke must include its recalculated colors.
    if writeCommands[ev.name] then refreshPending(state) end
  end)
  state.closeListener = events:on("aftercommand", function(ev)
    if ev.name == "CloseFile" or ev.name == "CloseAllFiles" then
      forgetClosed(state, openSprites())
    end
  end)
  for id in pairs(openSprites()) do state.pending[id] = true end
  if next(state.pending) then state.timer:start() end
end

function Live.track(sprite)
  if session and sprite and sprite.isValid then queue(session, sprite.id) end
end

function Live.stop()
  local state = session
  if not state then return end
  session = nil
  state.timer:stop()
  local events = app.events
  events:off(state.siteListener)
  events:off(state.writeListener)
  events:off(state.closeListener)
  for id, sprite in pairs(openSprites()) do
    local listeners = state.listeners[id]
    if listeners then
      local spriteEvents = sprite.events
      for _, listener in ipairs(listeners) do spriteEvents:off(listener) end
    end
  end
end

return Live
