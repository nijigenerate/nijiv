# nijiv

`nijiv` is a sample host viewer that renders nijilive puppets through the **nijilive Unity DLL ABI (`njg*`)**.

This repository focuses on host-side integration:
- load `libnijilive-unity` and bind exported C ABI symbols
- create rendering context (SDL2 + OpenGL or Vulkan)
- receive command queue/shared buffers from DLL
- execute rendering on the host backend

## Backends

- OpenGL backend: `source/opengl/opengl_backend.d`
- Vulkan backend: `source/vulkan/vulkan_backend.d`

Both are selectable with DUB configurations.

## DUB Configurations

- `opengl`
  - target: `nijiv-opengl`
  - backend dependency: `bindbc-opengl`
  - excludes: `source/vulkan/**`
- `vulkan`
  - target: `nijiv-vulkan`
  - backend dependency: `erupted`
  - version flag: `EnableVulkanBackend`
  - excludes: `source/opengl/**`

Common dependencies are kept at package root (SDL, math/image/support libs).

## Requirements

- D toolchain (`ldc2` recommended)
- `dub`
- SDL2 runtime
- nijilive Unity library (`libnijilive-unity*`)
- puppet file (`.inp` or `.inx`)

Vulkan runtime requirements:
- Vulkan loader + ICD (MoltenVK on macOS)
- a valid Vulkan SDK/runtime environment when running `nijiv-vulkan`

## Build Order

1. Build nijilive Unity DLL (`libnijilive-unity*`)
2. Build `nijiv` backend (`opengl` or `vulkan`)
3. Run viewer

## Build nijilive Unity DLL

Expected layout:

```text
.../nijigenerate/
  nijiv/
  nijilive/
```

### macOS

In `../nijilive`:

```bash
./build-aux/osx/buildUnityDLL.sh
```

or:

```bash
dub build --config unity-dll-macos
```

### Windows

In `../nijilive`:

```bat
build-aux\\windows\\buildUnityDLL.bat
```

or:

```bat
dub build --config unity-dll
```

### Linux

If `nijilive` does not provide a Linux unity-dll config in your checkout, prepare an equivalent `.so` build path on the nijilive side first.

## Build nijiv

OpenGL:

```bash
dub build --config=opengl
```

Vulkan:

```bash
dub build --config=vulkan
```

## Run

OpenGL:

```bash
./nijiv-opengl <puppet.inp|puppet.inx> [width height] [--test] [--frames N]
```

Vulkan:

```bash
./nijiv-vulkan <puppet.inp|puppet.inx> [width height] [--test] [--frames N]
```

Notes:
- If `.inxd` is passed by mistake, the app attempts fallback to `.inx` / `.inp` with the same stem.

## DLL Search

`source/app.d` resolves Unity library names per OS:

- Windows: `nijilive-unity.dll`, `libnijilive-unity.dll`
- Linux: `libnijilive-unity.so`, `nijilive-unity.so`
- macOS: `libnijilive-unity.dylib`, `nijilive-unity.dylib`

Search order:
1. current working directory
2. `../nijilive`
3. `../../nijilive`
4. relative `../nijilive`

## Runtime Options

CLI:
- `--test`
- `--frames N`

Environment variables:
- `NJIV_TEST_FRAMES`
- `NJIV_TEST_TIMEOUT_MS`

## Vulkan Status

Vulkan backend is actively being brought to parity with OpenGL.
Current implementation includes:
- command queue execution
- texture upload and draw batching
- blend mode table (including advanced equation path when extension is available)
- mask/stencil path under active refinement

If rendering differs from OpenGL on specific assets, treat Vulkan as work-in-progress and verify against `opengl` configuration.

