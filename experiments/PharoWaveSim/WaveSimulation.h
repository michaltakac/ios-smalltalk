/*
 * WaveSimulation.h
 *
 * C API for the GPU-accelerated 2D wave propagation simulation.
 * Functions are registered in the FFI cache so Pharo can call them via UFFI.
 */

#ifndef WAVE_SIMULATION_H
#define WAVE_SIMULATION_H

#ifdef __cplusplus
extern "C" {
#endif

/* Initialize the wave simulation with given grid dimensions. */
void wavesim_init(int gridWidth, int gridHeight);

/* Advance the simulation by numSteps time steps. */
void wavesim_step(int numSteps);

/* Inject a circular wave source at grid coordinates (x, y). */
void wavesim_inject(float x, float y, float strength, float radius);

/*
 * Render the current wave state as BGRA pixels into destPixels.
 * destPitch: bytes per row of destination buffer.
 * destX, destY: offset into destination where rendering starts.
 * width, height: size of the region to render (in pixels, not grid cells).
 * The wave grid is scaled to fill width x height.
 */
void wavesim_render(void* destPixels, int destPitch,
                    int destX, int destY, int width, int height);

/* Set wave propagation speed (0.05 .. 0.5). */
void wavesim_set_speed(float speed);

/* Set damping factor (0.0 .. 0.05). */
void wavesim_set_damping(float damping);

/* Set color scheme (0=Ocean, 1=Inferno, 2=CoolWarm, 3=Neon, 4=Grayscale). */
void wavesim_set_color_scheme(int scheme);

/* Set lighting normal scale (1 .. 30). */
void wavesim_set_normal_scale(float scale);

/* Reset simulation to flat. */
void wavesim_reset(void);

/* Returns 1 if initialized, 0 otherwise. */
int wavesim_is_initialized(void);

/* Returns the grid width/height. */
int wavesim_grid_width(void);
int wavesim_grid_height(void);

/*
 * Render wave state directly into the VM's shared display surface.
 * destX, destY: pixel offset into the display.
 * width, height: size of region to fill (wave grid is scaled to fit).
 * Uses vm_getDisplayBufferInfo() to find the buffer, so this
 * writes into the same memory that the Metal renderer reads.
 */
void wavesim_render_to_display(int destX, int destY, int width, int height);

/* Register all wavesim_* functions in the FFI cache. */
void registerWaveSimFunctions(void);

#ifdef __cplusplus
}
#endif

#endif /* WAVE_SIMULATION_H */
