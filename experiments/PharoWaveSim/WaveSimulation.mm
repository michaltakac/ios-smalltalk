/*
 * WaveSimulation.mm
 *
 * GPU-accelerated 2D wave propagation using Metal compute shaders.
 * Manages triple-buffered R32Float textures for the wave state,
 * a Metal compute pipeline for the wave equation, and CPU-side
 * color mapping for rendering into Pharo's display buffer.
 */

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include "WaveSimulation.h"
#include "PlatformBridge.h"
#include "DisplaySurface.hpp"
#include <cmath>
#include <cstring>
#include <mutex>
#include <vector>

// Must match the Metal shader struct layout
struct WaveParams {
    float speed;
    float damping;
    float sourceX;
    float sourceY;
    float sourceStrength;
    float sourceRadius;
    float time;
    int   colorScheme;
    float normalScale;
    float padding1;
    uint32_t gridSize[2]; // {width, height}
};

static std::mutex sMutex;
static bool sInitialized = false;

static id<MTLDevice>              sDevice       = nil;
static id<MTLCommandQueue>        sCommandQueue = nil;
static id<MTLComputePipelineState> sComputePipeline = nil;

// Triple-buffered wave textures (R32Float)
static id<MTLTexture> sWaveTextures[3] = {nil, nil, nil};
static int sStepIndex = 0;
static int sGridWidth = 0;
static int sGridHeight = 0;
static float sTime = 0.0f;

// Simulation parameters
static float sSpeed       = 0.15f;
static float sDamping     = 0.005f;
static int   sColorScheme = 0;
static float sNormalScale = 8.0f;

// Pending source injection
static bool  sHasSource = false;
static float sSourceX = 0, sSourceY = 0;
static float sSourceStrength = 1.0f, sSourceRadius = 5.0f;

// CPU-side wave data readback buffer
static std::vector<float> sWaveData;

static id<MTLTexture> createWaveTexture(int w, int h) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                   width:w
                                                                                  height:h
                                                                               mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    desc.storageMode = MTLStorageModeShared;
    return [sDevice newTextureWithDescriptor:desc];
}

static void clearTexture(id<MTLTexture> tex, int w, int h) {
    std::vector<float> zeros(w * h, 0.0f);
    MTLRegion region = MTLRegionMake2D(0, 0, w, h);
    [tex replaceRegion:region mipmapLevel:0 withBytes:zeros.data() bytesPerRow:w * sizeof(float)];
}

extern "C" void wavesim_init(int gridWidth, int gridHeight) {
    std::lock_guard<std::mutex> lock(sMutex);

    if (gridWidth < 8) gridWidth = 8;
    if (gridHeight < 8) gridHeight = 8;
    if (gridWidth > 2048) gridWidth = 2048;
    if (gridHeight > 2048) gridHeight = 2048;

    if (!sDevice) {
        sDevice = MTLCreateSystemDefaultDevice();
        if (!sDevice) {
            fprintf(stderr, "[wavesim] Metal not available\n");
            return;
        }
        sCommandQueue = [sDevice newCommandQueue];
    }

    if (!sComputePipeline) {
        NSBundle *mainBundle = [NSBundle mainBundle];
        id<MTLLibrary> lib = [sDevice newDefaultLibrary];
        if (!lib) {
            NSString *metalPath = [mainBundle pathForResource:@"default" ofType:@"metallib"];
            if (metalPath) {
                NSError *err = nil;
                lib = [sDevice newLibraryWithFile:metalPath error:&err];
            }
        }
        if (!lib) {
            fprintf(stderr, "[wavesim] Metal library not found\n");
            return;
        }

        id<MTLFunction> fn = [lib newFunctionWithName:@"waveStep"];
        if (!fn) {
            fprintf(stderr, "[wavesim] waveStep kernel not found in Metal library\n");
            return;
        }

        NSError *err = nil;
        sComputePipeline = [sDevice newComputePipelineStateWithFunction:fn error:&err];
        if (!sComputePipeline) {
            fprintf(stderr, "[wavesim] Failed to create compute pipeline: %s\n",
                    [[err localizedDescription] UTF8String]);
            return;
        }
    }

    sGridWidth = gridWidth;
    sGridHeight = gridHeight;
    sStepIndex = 0;
    sTime = 0.0f;
    sHasSource = false;

    for (int i = 0; i < 3; i++) {
        sWaveTextures[i] = createWaveTexture(gridWidth, gridHeight);
        clearTexture(sWaveTextures[i], gridWidth, gridHeight);
    }

    sWaveData.resize(gridWidth * gridHeight, 0.0f);
    sInitialized = true;

    fprintf(stderr, "[wavesim] Initialized %dx%d grid\n", gridWidth, gridHeight);
}

extern "C" void wavesim_step(int numSteps) {
    std::lock_guard<std::mutex> lock(sMutex);
    if (!sInitialized || !sComputePipeline) return;

    id<MTLCommandBuffer> cmdBuf = [sCommandQueue commandBuffer];
    if (!cmdBuf) return;

    for (int step = 0; step < numSteps; step++) {
        int cur  = sStepIndex % 3;
        int prev = (sStepIndex + 2) % 3;
        int next = (sStepIndex + 1) % 3;

        WaveParams params = {};
        params.speed       = sSpeed;
        params.damping     = sDamping;
        params.sourceX     = (sHasSource && step == 0) ? sSourceX : -1.0f;
        params.sourceY     = (sHasSource && step == 0) ? sSourceY : -1.0f;
        params.sourceStrength = sSourceStrength;
        params.sourceRadius   = sSourceRadius;
        params.time        = sTime;
        params.colorScheme = sColorScheme;
        params.normalScale = sNormalScale;
        params.gridSize[0] = (uint32_t)sGridWidth;
        params.gridSize[1] = (uint32_t)sGridHeight;

        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        [enc setComputePipelineState:sComputePipeline];
        [enc setTexture:sWaveTextures[cur]  atIndex:0]; // current
        [enc setTexture:sWaveTextures[prev] atIndex:1]; // previous
        [enc setTexture:sWaveTextures[next] atIndex:2]; // output (next)
        [enc setBytes:&params length:sizeof(params) atIndex:0];

        MTLSize gridSize = MTLSizeMake(sGridWidth, sGridHeight, 1);
        NSUInteger w = sComputePipeline.threadExecutionWidth;
        NSUInteger h = sComputePipeline.maxTotalThreadsPerThreadgroup / w;
        MTLSize threadGroupSize = MTLSizeMake(w, h, 1);
        [enc dispatchThreads:gridSize threadsPerThreadgroup:threadGroupSize];
        [enc endEncoding];

        sStepIndex++;
        sTime += 0.016f;
    }

    sHasSource = false;
    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];
}

extern "C" void wavesim_inject(float x, float y, float strength, float radius) {
    std::lock_guard<std::mutex> lock(sMutex);
    sHasSource = true;
    sSourceX = x;
    sSourceY = y;
    sSourceStrength = strength;
    sSourceRadius = radius;
}

// Color mapping helpers (CPU side, matching the shader aesthetics)
static inline uint32_t packBGRA(float r, float g, float b) {
    uint8_t rb = (uint8_t)(fminf(fmaxf(r, 0.0f), 1.0f) * 255.0f);
    uint8_t gb = (uint8_t)(fminf(fmaxf(g, 0.0f), 1.0f) * 255.0f);
    uint8_t bb = (uint8_t)(fminf(fmaxf(b, 0.0f), 1.0f) * 255.0f);
    return (0xFFu << 24) | ((uint32_t)rb << 16) | ((uint32_t)gb << 8) | (uint32_t)bb;
}

static uint32_t oceanColor(float h) {
    float t = h * 0.5f + 0.5f;
    float r = t * t * 0.3f;
    float g = t * 0.4f + 0.1f;
    float b = 0.3f + t * 0.7f;
    return packBGRA(r, g, b);
}

static uint32_t infernoColor(float h) {
    float t = h * 0.5f + 0.5f;
    float r = fminf(1.0f, t * 3.0f);
    float g = fminf(1.0f, fmaxf(0.0f, (t - 0.33f) * 3.0f));
    float b = fminf(1.0f, fmaxf(0.0f, (t - 0.66f) * 3.0f));
    return packBGRA(r, g, b);
}

static uint32_t coolWarmColor(float h) {
    float t = h * 0.5f + 0.5f;
    float r = t;
    float g = 1.0f - fabsf(t - 0.5f) * 2.0f;
    float b = 1.0f - t;
    return packBGRA(r, g, b);
}

static uint32_t neonColor(float h) {
    float t = h * 0.5f + 0.5f;
    float r = sinf(t * 3.14159f) * 0.8f;
    float g = sinf(t * 3.14159f * 2.0f) * 0.5f + 0.5f;
    float b = cosf(t * 3.14159f) * 0.5f + 0.5f;
    return packBGRA(r, g, b);
}

static uint32_t grayscaleColor(float h) {
    float t = h * 0.5f + 0.5f;
    return packBGRA(t, t, t);
}

extern "C" void wavesim_render(void* destPixels, int destPitch,
                               int destX, int destY, int width, int height) {
    std::lock_guard<std::mutex> lock(sMutex);
    if (!sInitialized || !destPixels || width <= 0 || height <= 0) return;

    // Read current wave state from GPU texture to CPU
    int cur = sStepIndex % 3;
    MTLRegion region = MTLRegionMake2D(0, 0, sGridWidth, sGridHeight);
    [sWaveTextures[cur] getBytes:sWaveData.data()
                     bytesPerRow:sGridWidth * sizeof(float)
                      fromRegion:region
                     mipmapLevel:0];

    auto sample = [&](int gx, int gy) -> float {
        gx = std::max(0, std::min(gx, sGridWidth - 1));
        gy = std::max(0, std::min(gy, sGridHeight - 1));
        return sWaveData[gy * sGridWidth + gx];
    };

    uint8_t* dst = (uint8_t*)destPixels;
    float invW = (float)sGridWidth / (float)width;
    float invH = (float)sGridHeight / (float)height;

    for (int py = 0; py < height; py++) {
        uint32_t* row = (uint32_t*)(dst + (destY + py) * destPitch) + destX;
        float fy = ((float)py + 0.5f) * invH;
        int gy = (int)fy;

        for (int px = 0; px < width; px++) {
            float fx = ((float)px + 0.5f) * invW;
            int gx = (int)fx;

            float h = sample(gx, gy) * 5.0f;

            // Normal estimation for Blinn-Phong lighting
            float dhdx = (sample(gx + 1, gy) - sample(gx - 1, gy)) * 0.5f * sNormalScale;
            float dhdy = (sample(gx, gy + 1) - sample(gx, gy - 1)) * 0.5f * sNormalScale;

            float nx = -dhdx, ny = -dhdy, nz = 1.0f;
            float invLen = 1.0f / sqrtf(nx*nx + ny*ny + nz*nz);
            nx *= invLen; ny *= invLen; nz *= invLen;

            // Light from above-right
            float lx = 0.3f, ly = -0.3f, lz = 1.0f;
            float lLen = 1.0f / sqrtf(lx*lx + ly*ly + lz*lz);
            lx *= lLen; ly *= lLen; lz *= lLen;

            float diffuse = fmaxf(0.0f, nx*lx + ny*ly + nz*lz);
            float ambient = 0.3f;
            float lighting = ambient + diffuse * 0.7f;

            // Specular (Blinn-Phong)
            float hx = lx, hy = ly, hz = lz + 1.0f;
            float hLen = 1.0f / sqrtf(hx*hx + hy*hy + hz*hz);
            hx *= hLen; hy *= hLen; hz *= hLen;
            float spec = powf(fmaxf(0.0f, nx*hx + ny*hy + nz*hz), 32.0f);

            uint32_t baseColor;
            switch (sColorScheme) {
                case 0: baseColor = oceanColor(h); break;
                case 1: baseColor = infernoColor(h); break;
                case 2: baseColor = coolWarmColor(h); break;
                case 3: baseColor = neonColor(h); break;
                case 4: baseColor = grayscaleColor(h); break;
                default: baseColor = oceanColor(h); break;
            }

            uint8_t br = (baseColor >> 16) & 0xFF;
            uint8_t bg = (baseColor >> 8)  & 0xFF;
            uint8_t bb = baseColor & 0xFF;

            float fr = ((float)br / 255.0f) * lighting + spec * 0.5f;
            float fg = ((float)bg / 255.0f) * lighting + spec * 0.5f;
            float fb = ((float)bb / 255.0f) * lighting + spec * 0.5f;

            row[px] = packBGRA(fr, fg, fb);
        }
    }
}

extern "C" void wavesim_set_speed(float speed) {
    std::lock_guard<std::mutex> lock(sMutex);
    sSpeed = fmaxf(0.01f, fminf(speed, 0.5f));
}

extern "C" void wavesim_set_damping(float damping) {
    std::lock_guard<std::mutex> lock(sMutex);
    sDamping = fmaxf(0.0f, fminf(damping, 0.1f));
}

extern "C" void wavesim_set_color_scheme(int scheme) {
    std::lock_guard<std::mutex> lock(sMutex);
    sColorScheme = std::max(0, std::min(scheme, 4));
}

extern "C" void wavesim_set_normal_scale(float scale) {
    std::lock_guard<std::mutex> lock(sMutex);
    sNormalScale = fmaxf(0.1f, fminf(scale, 50.0f));
}

extern "C" void wavesim_reset(void) {
    std::lock_guard<std::mutex> lock(sMutex);
    if (!sInitialized) return;
    for (int i = 0; i < 3; i++) {
        clearTexture(sWaveTextures[i], sGridWidth, sGridHeight);
    }
    sStepIndex = 0;
    sTime = 0.0f;
    sHasSource = false;
}

extern "C" int wavesim_is_initialized(void) {
    std::lock_guard<std::mutex> lock(sMutex);
    return sInitialized ? 1 : 0;
}

extern "C" int wavesim_grid_width(void) {
    std::lock_guard<std::mutex> lock(sMutex);
    return sGridWidth;
}

extern "C" int wavesim_grid_height(void) {
    std::lock_guard<std::mutex> lock(sMutex);
    return sGridHeight;
}

extern "C" void wavesim_render_to_display(int destX, int destY, int width, int height) {
    DisplayBufferInfo info = {};
    vm_getDisplayBufferInfo(&info);
    if (!info.pixels || info.width <= 0 || info.height <= 0) return;
    if (destX < 0 || destY < 0 || width <= 0 || height <= 0) return;
    if (destX + width > info.width) width = info.width - destX;
    if (destY + height > info.height) height = info.height - destY;

    wavesim_render(info.pixels, info.width * 4, destX, destY, width, height);

    // Tell the display surface that this rectangle changed so the Metal
    // renderer picks up the new pixels on its next frame.
    if (pharo::gDisplaySurface) {
        pharo::gDisplaySurface->invalidateRect(destX, destY, width, height);
    }
}

namespace pharo { namespace ffi {
    void registerFunction(const std::string& funcName, void* funcPtr);
}}

extern "C" void registerWaveSimFunctions(void) {
    using pharo::ffi::registerFunction;
    registerFunction("wavesim_init",             reinterpret_cast<void*>(wavesim_init));
    registerFunction("wavesim_step",             reinterpret_cast<void*>(wavesim_step));
    registerFunction("wavesim_inject",           reinterpret_cast<void*>(wavesim_inject));
    registerFunction("wavesim_render",           reinterpret_cast<void*>(wavesim_render));
    registerFunction("wavesim_set_speed",        reinterpret_cast<void*>(wavesim_set_speed));
    registerFunction("wavesim_set_damping",      reinterpret_cast<void*>(wavesim_set_damping));
    registerFunction("wavesim_set_color_scheme", reinterpret_cast<void*>(wavesim_set_color_scheme));
    registerFunction("wavesim_set_normal_scale", reinterpret_cast<void*>(wavesim_set_normal_scale));
    registerFunction("wavesim_reset",            reinterpret_cast<void*>(wavesim_reset));
    registerFunction("wavesim_is_initialized",   reinterpret_cast<void*>(wavesim_is_initialized));
    registerFunction("wavesim_grid_width",       reinterpret_cast<void*>(wavesim_grid_width));
    registerFunction("wavesim_grid_height",      reinterpret_cast<void*>(wavesim_grid_height));
    registerFunction("wavesim_render_to_display",reinterpret_cast<void*>(wavesim_render_to_display));
}
