/*
 * WaveShaders.metal
 *
 * GPU compute shader for 2D wave equation simulation.
 *
 * The wave equation  u_tt = c^2 * laplacian(u)  is discretized with
 * a standard finite-difference stencil.  Three textures are rotated
 * (previous, current, next) to avoid extra copies.
 *
 * Color mapping and lighting are done on the CPU side (WaveSimulation.mm)
 * so only the compute kernel is needed here.
 */

#include <metal_stdlib>
using namespace metal;

// Must match the C++ WaveParams layout in WaveSimulation.mm exactly (48 bytes).
struct WaveParams {
    float speed;           // offset 0
    float damping;         // offset 4
    float sourceX;         // offset 8
    float sourceY;         // offset 12
    float sourceStrength;  // offset 16
    float sourceRadius;    // offset 20
    float time;            // offset 24
    int   colorScheme;     // offset 28
    float normalScale;     // offset 32
    float padding1;        // offset 36
    uint2 gridSize;        // offset 40
};

kernel void waveStep(
    texture2d<float, access::read>  current  [[texture(0)]],
    texture2d<float, access::read>  previous [[texture(1)]],
    texture2d<float, access::write> nextTex  [[texture(2)]],
    constant WaveParams& params              [[buffer(0)]],
    uint2 gid                                [[thread_position_in_grid]]
) {
    uint w = params.gridSize.x;
    uint h = params.gridSize.y;
    if (gid.x >= w || gid.y >= h) return;

    float c = current.read(gid).r;
    float p = previous.read(gid).r;

    // Neighbor reads with Neumann (reflecting) boundary conditions
    float L = (gid.x > 0)   ? current.read(uint2(gid.x - 1, gid.y)).r : c;
    float R = (gid.x < w-1) ? current.read(uint2(gid.x + 1, gid.y)).r : c;
    float U = (gid.y > 0)   ? current.read(uint2(gid.x, gid.y - 1)).r : c;
    float D = (gid.y < h-1) ? current.read(uint2(gid.x, gid.y + 1)).r : c;

    float laplacian = L + R + U + D - 4.0 * c;
    float v2 = params.speed * params.speed;
    float n = 2.0 * c - p + v2 * laplacian;

    n *= (1.0 - params.damping);

    // Absorbing boundary layer (20 cells wide, smooth fade)
    float border = 20.0;
    float dx = min(float(gid.x), float(w - 1 - gid.x));
    float dy = min(float(gid.y), float(h - 1 - gid.y));
    float dEdge = min(dx, dy);
    if (dEdge < border) {
        n *= smoothstep(0.0, border, dEdge);
    }

    // Source injection with cosine-squared falloff
    if (params.sourceX >= 0.0) {
        float2 delta = float2(gid) - float2(params.sourceX, params.sourceY);
        float dist = length(delta);
        if (dist < params.sourceRadius) {
            float falloff = cos(dist / params.sourceRadius * M_PI_F * 0.5);
            n += params.sourceStrength * falloff * falloff;
        }
    }

    n = clamp(n, -10.0f, 10.0f);
    nextTex.write(float4(n, 0.0, 0.0, 1.0), gid);
}
