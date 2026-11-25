local Common = require("ui.common")

local RainPreview = {}
RainPreview.colors = {
  water = {r = 91, g = 211, b = 246},
  pool = {r = 184, g = 244, b = 255},
  rust = {r = 255, g = 180, b = 96},
}

local function randomFor(seed)
  seed = tonumber(seed)
  local state = seed and seed >= -2147483648 and seed <= 4294967295 and math.floor(seed) & 0xffffffff or 1
  return function()
    state = (1664525 * state + 1013904223) & 0xffffffff
    return state / 4294967296
  end
end

local function append(track, x, y, nextX, nextY, duration, rusty, pooling)
  track.steps[#track.steps + 1] = {
    x = x, y = y, nextX = nextX, nextY = nextY,
    start = track.duration, finish = track.duration + duration,
    rusty = rusty, pooling = pooling,
  }
  track.duration = track.duration + duration
end

local function buildTrack(trace, rect, start, random, pigmentRandom)
  local track = {steps = {}, duration = 0}
  local x, y, rusty = start.x, start.y, false
  local right, bottom = rect.x + rect.width, rect.y + rect.height
  while y < bottom do
    local flow, retained = trace.waterAt(x, y)
    if flow <= 0 then break end
    local left, down, forwardRight, pool = trace.routeAt(x, y)
    local localX, localY = x - rect.x, y - rect.y
    if trace.rustAt and not rusty then
      rusty = pigmentRandom() < math.min(1, trace.rustAt(x, y) * 1.85)
    end

    local total = left + down + forwardRight
    if pool > 0.075 and retained > 0 then
      local pause = 1.2 + 5.1 * pool + 2.4 * (retained / flow)
      if total == 0 then pause = pause + 4 end
      append(track, localX, localY, localX, localY, pause, rusty, true)
    end
    if total == 0 then break end

    local roll = random() * total
    local step = 0
    if roll < left then step = -1 elseif roll >= left + down then step = 1 end
    local nextX, nextY = x + step, y + 1
    local duration = 0.80 + 0.38 * (1 - math.min(1, flow))
    if nextX < rect.x or nextX >= right or nextY >= bottom then
      append(track, localX, localY, localX, localY, duration * 0.55, rusty, false)
      break
    end
    append(track, localX, localY, nextX - rect.x, nextY - rect.y, duration, rusty, false)
    x, y = nextX, nextY
  end
  if #track.steps == 0 then return nil end
  track.period = track.duration + 4 + random() * 12
  track.phase = random() * track.period
  return track
end

-- A normal-size preview needs only a few trajectories. Sample the visible
-- entry points and rain-facing ledges, then follow the actual solver weights.
function RainPreview.build(trace, rect, seed)
  local tracks = {}
  if not trace or rect.width < 1 or rect.height < 1 then return tracks end
  local starts, seenColumn, flowing = {}, {}, 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local flow, _, exposure = trace.waterAt(x, y)
      if flow > 0 and (not seenColumn[x] or exposure > 0.46) then
        seenColumn[x] = true
        starts[#starts + 1] = {x = x, y = y}
        flowing = flowing + flow
      end
    end
  end
  if #starts == 0 then return tracks end

  local random = randomFor(seed or trace.seed)
  local density = 0.42 + 0.9 * flowing / #starts
  local count = math.max(3, math.min(48, #starts * 2, math.floor(rect.width * rect.height * density / 230)))
  for index = 1, count do
    local position = (index - 1 + random()) * #starts / count
    local paths = randomFor(random() * 4294967296)
    local pigments = randomFor(random() * 4294967296)
    local track = buildTrack(trace, rect, starts[math.floor(position) + 1], paths, pigments)
    if track then tracks[#tracks + 1] = track end
  end
  return tracks
end

function RainPreview.each(tracks, elapsed, visit)
  for _, track in ipairs(tracks or {}) do
    local time = (elapsed + track.phase) % track.period
    if time < track.duration then
      for _, step in ipairs(track.steps) do
        if time < step.finish then
          local place = (time - step.start) / (step.finish - step.start)
          visit(step.x + place * (step.nextX - step.x), step.y + place * (step.nextY - step.y), step.rusty, step.pooling)
          break
        end
      end
    end
  end
end

function RainPreview.draw(canvas, image, tracks, elapsed)
  Common.drawPixelPreview(canvas, image)
  if not image or not tracks or #tracks == 0 then return end
  local scale = math.max(1, math.min(5, canvas.width // image.width, canvas.height // image.height))
  local left = (canvas.width - image.width * scale) // 2
  local top = (canvas.height - image.height * scale) // 2
  local side = math.max(2, scale)
  local colors = RainPreview.colors
  local water, rust, pool = Color(colors.water), Color(colors.rust), Color(colors.pool)
  local outline = Color{r = 21, g = 41, b = 49}
  RainPreview.each(tracks, elapsed, function(x, y, rusty, pooling)
    local screenX = left + math.floor((x + 0.5) * scale - side / 2 + 0.5)
    local screenY = top + math.floor((y + 0.5) * scale - side / 2 + 0.5)
    canvas.color = outline
    canvas:fillRect(Rectangle(screenX - 1, screenY, side + 2, side))
    canvas.color = rusty and rust or (pooling and pool or water)
    canvas:fillRect(Rectangle(screenX, screenY, side, side))
  end)
end

return RainPreview
