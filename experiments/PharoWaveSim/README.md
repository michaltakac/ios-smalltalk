# PharoWaveSim

Interactive 2D wave propagation simulation running inside the Pharo VM,
driven by Metal GPU compute shaders.

## What it does

A `WaveSimMorph` opens in the Pharo world displaying a real-time water
surface.  Tap or click anywhere to inject waves that propagate, reflect off
boundaries, and create interference patterns.  The simulation runs on the GPU
via a Metal compute kernel while all UI logic lives in Smalltalk and can be
modified live.

    click/tap     →  inject wave at cursor position
    drag          →  continuous wave injection along path

## How it works

The simulation is split into three layers:

    Smalltalk (wavesim.st)
      WaveSimFFI        FFI bindings to the native wavesim_* functions
      WaveSimMorph      Morphic canvas — event handling, stepping, rendering

    C++ / Objective-C++ (WaveSimulation.mm)
      wavesim_init      Create Metal device, pipeline, triple-buffered textures
      wavesim_step      Dispatch waveStep compute kernel N times
      wavesim_inject    Set source position/strength for the next step
      wavesim_render*   Read GPU texture → CPU, apply color map + lighting,
                        write into the VM's display buffer

    Metal (WaveShaders.metal)
      waveStep          Finite-difference wave equation (u_tt = c² ∇²u) with
                        Neumann boundaries, absorbing border layer, and
                        cosine-squared source injection

Color mapping (ocean, inferno, cool-warm, neon, grayscale) and Blinn-Phong
lighting are computed on the CPU so they can be swapped without recompiling
the shader.

## Adjustable parameters

All tunable from Smalltalk at runtime:

    Parameter        Default    Range          What it controls
    speed            0.3        0.01 – 0.5     Wave propagation speed
    damping          0.001      0 – 0.1        Energy dissipation per step
    colorScheme      0          0 – 4          Color map (0=ocean, 1=inferno, …)
    normalScale      8.0        0.1 – 50       Surface bumpiness for lighting
    sourceStrength   5.0        any float      Displacement at wave center
    sourceRadius     15.0       any float      Radius of injected wave (grid cells)
    stepsPerFrame    3          1 – 20         Simulation substeps per Morphic step

Example — change color scheme live in a Workspace:

    (WaveSimMorph allInstances first) colorScheme: 3.  "neon"

## Files

    wavesim.st           Smalltalk: FFI bindings, WaveSimMorph, auto-open
    WaveSimulation.h     C API header
    WaveSimulation.mm    Metal setup, GPU dispatch, CPU color mapping
    WaveShaders.metal    GPU compute kernel (waveStep)
