local modules = {
  "lib.ambient_occlusion", "lib.aseprite", "lib.cast_shadow", "lib.chips", "lib.color",
  "lib.composer", "lib.deposits", "lib.detail_alphas", "lib.detail_native", "lib.lighting", "lib.prop_details",
  "lib.effect_registry", "lib.mask_registry", "lib.soot", "generators.user", "generators.example",
  "lib.material", "lib.material_catalog", "lib.material_lighting", "lib.material_project",
  "lib.material_sample", "lib.material_sphere", "lib.normal",
  "lib.paint_colors", "lib.paint_native", "lib.paint_stack", "lib.paint_wear",
  "lib.linked_live", "lib.linked_native", "lib.linked_weathering",
  "lib.scene_lighting", "lib.scene_lighting_native",
  "lib.rain", "lib.streaks", "lib.surface", "lib.texture", "lib.weather", "lib.workspace",
  "ui.alpha_library", "ui.common", "ui.detail_dialog", "ui.height_dialog", "ui.linked_dialog",
  "ui.material_layer", "ui.material_library", "ui.lighting_panel",
  "ui.paint_dialog", "ui.paint_effect_dialog", "ui.paint_palette", "ui.rain_preview", "ui.material_dialog", "ui.ramp_dialog",
  "ui.scene_lighting_dialog", "ui.shadow_controls", "ui.texture_dialog",
}

local live

function init(plugin)
  -- Aseprite keeps namespaced require caches when it updates an extension in place.
  for _, name in ipairs(modules) do package.loaded[plugin.name .. "/" .. name] = nil end
  require("generators.user")(require("lib.effect_registry"), require("lib.mask_registry"))
  local RampDialog = require("ui.ramp_dialog")
  local TextureDialog = require("ui.texture_dialog")
  local HeightDialog = require("ui.height_dialog")
  local AlphaLibrary = require("ui.alpha_library")
  local SceneLightingDialog = require("ui.scene_lighting_dialog")
  local DetailDialog = require("ui.detail_dialog")
  local MaterialDialog = require("ui.material_dialog")
  local LinkedDialog = require("ui.linked_dialog")
  local PaintDialog = require("ui.paint_dialog")
  local PaintNative = require("lib.paint_native")
  local Project = require("lib.material_project")
  live = require("lib.linked_live")

  local group = "substanceprite"
  plugin:newMenuGroup{
    id = group,
    title = "Substanceprite",
    group = "sprite_crop",
  }

  plugin:newCommand{
    id = "SubstancepriteMaterials",
    title = "Materials…",
    group = group,
    onenabled = function()
      local layer = app.layer
      return app.isUIAvailable and layer ~= nil and not layer.isTilemap
        and ((layer.isGroup and app.sprite.colorMode == ColorMode.RGB) or app.cel ~= nil)
    end,
    onclick = function()
      local site = app.site
      if site.sprite.colorMode == ColorMode.RGB then
        local project, failure = Project.open(site)
        if project then MaterialDialog.open(plugin, site, project); return end
        if failure then app.alert(failure); return end
        local context, message = PaintNative.context(site)
        if context and (site.layer.isGroup or context.group or context.source.isGroup) then
          PaintDialog.open(site, context)
          return
        elseif site.layer.isGroup then
          app.alert(message or "Select a visible material group or a raster layer.")
          return
        end
      end
      MaterialDialog.open(plugin, site)
    end,
  }

  plugin:newCommand{
    id = "SubstancepriteLighting",
    title = "Lighting…",
    group = group,
    onenabled = function()
      local sprite = app.sprite
      return app.isUIAvailable and sprite ~= nil and sprite.colorMode == ColorMode.RGB
    end,
    onclick = function() SceneLightingDialog.open(plugin, app.site) end,
  }

  plugin:newCommand{
    id = "SubstancepritePropDetails",
    title = "Prop Details…",
    group = group,
    onenabled = function()
      local layer = app.layer
      return app.isUIAvailable and layer ~= nil and app.sprite.colorMode == ColorMode.RGB
        and not layer.isTilemap and not layer.isReference and (layer.isGroup or app.cel ~= nil)
    end,
    onclick = function() DetailDialog.open(plugin, app.site) end,
  }

  plugin:newCommand{
    id = "SubstancepriteAlphaLibrary",
    title = "Alpha Library…",
    group = group,
    onenabled = function() return app.isUIAvailable end,
    onclick = function() AlphaLibrary.open() end,
  }

  plugin:newCommand{
    id = "SubstancepritePaintWear",
    title = "Paint & Wear…",
    group = group,
    onenabled = function()
      local layer = app.layer
      return app.isUIAvailable and layer ~= nil and app.sprite.colorMode == ColorMode.RGB
        and not layer.isTilemap and (layer.isGroup or app.cel ~= nil)
    end,
    onclick = function()
      local site = app.site
      local project = Project.open(site)
      if project then site = {sprite = site.sprite, layer = project.group, frame = site.frame} end
      PaintDialog.open(site)
    end,
  }

  plugin:newCommand{
    id = "SubstancepriteColorRamp",
    title = "Color Ramp Generator",
    group = group,
    onenabled = function() return app.isUIAvailable and app.sprite ~= nil end,
    onclick = function() RampDialog.open(plugin, app.sprite, app.frame) end,
  }

  plugin:newCommand{
    id = "SubstancepriteHeightMap",
    title = "Height Map from Art",
    group = group,
    onenabled = function()
      local layer = app.layer
      return app.isUIAvailable and layer ~= nil and not layer.isGroup
             and not layer.isTilemap and app.cel ~= nil
    end,
    onclick = function() HeightDialog.open(app.site) end,
  }

  plugin:newCommand{
    id = "SubstancepriteTexture",
    title = "Texture Generator",
    group = group,
    onenabled = function() return app.isUIAvailable and app.sprite ~= nil end,
    onclick = function() TextureDialog.open(plugin, app.site) end,
  }

  plugin:newCommand{
    id = "SubstancepriteLinkedWeathering",
    title = "Linked Weathering",
    group = group,
    onenabled = function()
      local sprite = app.sprite
      return app.isUIAvailable and sprite ~= nil and sprite.colorMode == ColorMode.RGB
    end,
    onclick = function() LinkedDialog.open(plugin, app.site) end,
  }

  live.start()
end

function exit(plugin)
  if live then live.stop() end
end
