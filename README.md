# nijiv

`nijiv` is a sample viewer that renders nijilive puppets via the **nijilive Unity DLL interface**.

This project focuses on the "host side" implementation:
- loading `libnijilive-unity` and calling exported `njg*` APIs
- creating an SDL2 + OpenGL context
- receiving command queues/shared buffers from the DLL
- executing rendering on the host side

## Purpose

This repository is intended as a practical reference for integrating nijilive through the Unity-facing C ABI, rather than as a full engine/runtime.

## Current Scope

- Rendering backend: OpenGL (`source/opengl/opengl_backend.d`)
- Debug texture thumbnails: separated module (`source/opengl/opengl_thumb.d`)
- Main entry point: `source/app.d`

A Vulkan-related file exists in `source/vulkan/`, but the current executable path is OpenGL-based.

## Requirements

- D toolchain (`ldc2` recommended)
- `dub`
- SDL2 runtime library
- `libnijilive-unity.dylib` (built from nijilive side)
- Puppet file (`.inp` or `.inx`)

## Build Order

Build in this order:

1. Build `nijilive` Unity DLL (`libnijilive-unity*`)
2. Build `nijiv`
3. Run `nijiv`

## Build `libnijilive-unity` (DLL/.so/.dylib)

`nijiv` consumes the Unity-facing exported `njg*` API from the sibling `nijilive` project.

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

or directly:

```bash
dub build --config unity-dll-macos
```

This produces `nijilive-unity.dylib` (typically as `libnijilive-unity.dylib` in the project root).

### Windows

In `../nijilive`:

```bat
build-aux\\windows\\buildUnityDLL.bat
```

or:

```bat
dub build --config unity-dll
```

This produces `nijilive-unity.dll` (plus import library files).

### Linux

At the moment, `nijilive` has dedicated Unity DLL configs for:
- `unity-dll` (Windows)
- `unity-dll-macos` (macOS)

There is no dedicated Linux Unity-DLL config in `nijilive/dub.sdl` yet, so `.so` generation for this interface is not standardized in this sample workflow.

## Build `nijiv`

```bash
dub build
```

Binary name is `nijiv`.

## Run

```bash
./nijiv <puppet.inp|puppet.inx> [width height] [--test] [--frames N]
```

Examples:

```bash
./nijiv ./sample.inx
./nijiv ./sample.inx 1920 1080
./nijiv ./sample.inx --test --frames 10
```

## DLL Search Paths

`source/app.d` now resolves library names by OS:

- Windows: `nijilive-unity.dll` (and `libnijilive-unity.dll` fallback)
- Linux: `libnijilive-unity.so` (and `nijilive-unity.so` fallback)
- macOS: `libnijilive-unity.dylib` (and `nijilive-unity.dylib` fallback)

For each name, these directories are searched in order:

1. executable working directory
2. `../nijilive`
3. `../../nijilive`
4. relative `../nijilive`

If not found, startup fails with an `enforce` error.

## Platform Status (nijiv host app)

Current `nijiv` host loading path supports multi-OS library names in `source/app.d`.
The OpenGL backend still contains a macOS-specific SDL fallback path (`/opt/homebrew/lib/libSDL2-2.0.0.dylib`), so runtime validation remains strongest on macOS.

### What is needed for Windows/Linux host support

1. OS-appropriate SDL loading fallback paths in `source/opengl/opengl_backend.d`
2. (Linux) a dedicated `nijilive` unity-dll config for `.so` output, or equivalent documented build path

## Runtime Options

CLI:
- `--test`: run in test mode
- `--frames N`: max frames in test mode

Environment variables:
- `NJIV_TEST_FRAMES`: test-mode frame cap
- `NJIV_TEST_TIMEOUT_MS`: test-mode timeout in milliseconds

Mouse:
- mouse wheel changes puppet scale (`njgSetPuppetScale`)

## Rendering Flow (high level)

1. Initialize SDL2/OpenGL
2. Load Unity DLL and bind `njg*` symbols
3. Create renderer/puppet via DLL
4. Per frame:
   - `njgBeginFrame`
   - `njgTickPuppet`
   - `njgEmitCommands`
   - `njgGetSharedBuffers`
   - `renderCommands(...)` executes command queue on OpenGL backend
   - `njgFlushCommandBuffer`
   - swap window buffers

## Notes

- This is a sample/reference project, so implementation is intentionally direct and integration-oriented.
- Some build warnings may appear depending on local dependency versions and import-path settings.
