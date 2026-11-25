# Contributing to Substanceprite

Use Lua 5.4 to test the algorithms and Aseprite to test dialogs, sprite changes, and Undo. Run these commands from the repository root.

```sh
lua5.4 tests/run.lua
aseprite -b --script tests/aseprite_smoke.lua
aseprite -b --script tests/material_project_smoke.lua
aseprite -b --script tests/material_lighting_smoke.lua
aseprite -b --script tests/prop_details_smoke.lua
aseprite -b --script tests/scene_lighting_smoke.lua
python tools/package.py --source-output dist/Substanceprite-source.zip
```

The Lua suite tests procedural algorithms independently of Aseprite. The integration tests use Aseprite's Lua API to check palettes, layers, maps, masks, and lighting. If Aseprite is absent from your PATH, specify its executable path. GitHub Actions checks Lua syntax, runs the algorithm tests, and builds both archives.

To save and reopen a test sprite, pass `--script-param material-project-file=path.aseprite` or `--script-param material-lighting-file=path.aseprite` before the matching `--script` argument.

When publishing a new version, update the downloadable extension with `python tools/package.py --output download/Substanceprite.aseprite-extension`.

## Project structure

- `main.lua` registers Aseprite commands and loads generator extensions.
- `ui/` contains tool dialogs, previews, and controls.
- `lib/` contains procedural algorithms, compositing, effect and mask registries, and Aseprite adapters.
- `lib/detail_alphas.lua` defines prop detail stamps with separate coverage, height, and tone values.
- `generators/user.lua` loads custom generators and masks.
- `tests/` contains algorithm tests, Aseprite integration tests, and a small sprite fixture.
- `tools/package.py` builds the archives using the Python standard library.

## Generators and masks

The `generators/user.lua` module returns a function that takes `Effects` and `Masks`. The extension calls it at initialization. To load the example **Example Flecks** effect and **Example Upper Third** mask, uncomment the call to `require("generators.example")` and restart Aseprite. For tests in standalone Lua, import `lib.effect_registry` and `lib.mask_registry` directly.

Use `Effects.register({ ... })` to register an effect. Supply a unique `name`, default settings in `profile`, a `colors` palette, and the functions `generate(width, height, settings, footprint, rect)` and `sampler(colors)`. The generator returns an array of samples for `rect` in row order. The sampler returns a function that converts a sample to RGBA and, when needed, a relief value.

Use `Masks.register({ ... })` to register a mask. Supply a unique `name` and a `sampler(width, height, options, footprint, layer)` that returns a coverage function for coordinates `x, y`. The function returns a value from 0 to 1. Set `requiresHeight` for masks that need a height map.

Procedural algorithms should reproduce the same result for the same inputs and Seed. Check transparency, partial selections, and small sprites. Changes to an algorithm affect both the preview and the canvas.

Generators, masks, and test images included in the repository must have compatible licenses. The [license](LICENSE) credits the Substanceprite contributors collectively.
