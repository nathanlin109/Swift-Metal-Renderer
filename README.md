# SwiftMetalRenderer

A real-time 3D renderer written in Swift and Metal, running on iOS and macOS
(via Mac Catalyst).

Built as a learning project to understand how modern rendering engines are put
together.


https://github.com/user-attachments/assets/3df2350e-1d78-4a95-b3d7-71012b3343f5


## What it does

**Physically based materials.** Each material has base color, metallic and roughness.
It also supports normal and ORM maps. Shading uses a Cook-Torrance microfacet model.

**Image-based lighting.** The scene is lit by a 360 degree HDR image,
so surfaces reflect and absorb light from the environment.
Directional and point lights are also supported.

**Directional shadow mapping.** The scene is rendered first from the light's
point of view into a depth-only target, recording the distance to the nearest
surface in each direction. The main pass compares against that to decide what's
occluded.

**HDR pipeline and post-processing.** The scene renders to a 16-bit float render target.
Bloom extracts bright regions and blurs them through down and upsampling.
Exposure, ACES tone mapping, and a vignette are applied, too.

**Scene graph and CPU/GPU overlap.** Objects live in a node tree.
Instanced rendering implemented to reduce draw calls. 
Implemented a frame pacing using a counting semaphore and ring buffers.

**Frame timing instrumentation.** CPU frame time, command encoding time,
and GPU time are measured to determine bottlenecks

## Requirements

- Xcode 26 or later
- iOS 26.5+ / macOS 26.0+
- A device or Mac with Metal support

## Building

Open `RayBreak.xcodeproj` and select a target:

- **My Mac (Mac Catalyst)** — the recommended target. Uses larger shadow maps
  and a longer prefiltered specular chain, since a Mac has the memory and GPU
  headroom a phone budget was sized against.
- **iOS device or simulator** — reduced quality settings sized to a phone GPU.

The default scene, `PbrScene`, lays out shader balls across a set of PBR
materials under image-based lighting.

## Controls

| Input | Action |
|---|---|
| `W` / `A` / `S` / `D` | Move the camera |
| `Q` / `E` | Move down / up |
| `Space` | Toggle the automatic orbit camera |

## Project layout

```
RayBreak/
├── Renderer.swift          Frame structure, render targets, quality settings
├── ShadowMap.swift         Shadow pass and light frustum fitting
├── SkyBox.swift            Environment map loading, cubemap and IBL precomputation
├── Bloom.swift             Bloom bright pass and blur pyramid
├── CameraOrbit.swift       Scripted orbit camera
├── FrameTimer.swift        CPU / encode / GPU timing instrumentation
├── Nodes/                  Scene graph — Node, Model, Instance, Material, Camera
├── Scenes/                 Scene definitions; PbrScene is the showcase
└── Shaders/
    ├── Shader.metal        PBR vertex/fragment shaders and shadow sampling
    ├── IBL.metal           Irradiance, prefilter and BRDF LUT compute kernels
    └── PostProcess.metal   Bloom chain and final composite
```

## Notes

The repository also contains scenes/assets from the project's origin as a
Breakout-style game, which is where the `RayBreak` project name comes from.
They're kept because they're related to different parts of the renderer.
I started this project to learn how to use metal and swift, but it grew into
a bigger project over time, so there are some files unrelated to the renderer.

## Assets

Environment map from [Poly Haven](https://polyhaven.com) (CC0).
Material textures from [ambientCG](https://ambientcg.com) (CC0).
