//
//  PostProcess.metal
//  RayBreak
//
//  Bloom chain and final composite. The scene now renders to a float target with no tone
//  mapping, so these passes see the real HDR values — which is the whole point: you cannot
//  bloom what has already been compressed into 0..1.
//

#include <metal_stdlib>
using namespace metal;

struct BloomUniforms {
    /// Texel size of the SOURCE texture, not the destination.
    float2 texelSize;
    float threshold;
    float knee;
    /// Ceiling on a single pixel's contribution to the blur — firefly suppression.
    float maxBrightness;
};

struct PostUniforms {
    float exposure;
    float bloomIntensity;
    float vignette;
};

struct FullscreenOut {
    float4 position [[ position ]];
    float2 uv;
};

constexpr sampler postSampler(coord::normalized,
                              filter::linear,
                              mip_filter::none,
                              address::clamp_to_edge);

// Local copy — Metal compiles each .metal file separately, so the `static` versions in
// Shader.metal and IBL.metal aren't visible here.
static float3 tonemapACES(float3 x) {
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

vertex FullscreenOut vertex_fullscreen(uint vertexID [[ vertex_id ]]) {
    // One oversized triangle rather than a quad — no diagonal seam, one fewer vertex.
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    float2 p = positions[vertexID];

    FullscreenOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = p * float2(0.5, -0.5) + 0.5;   // NDC is y-up, texture space is y-down
    return out;
}

/// Isolates the pixels bright enough to bloom.
fragment float4 fragment_bloom_bright(FullscreenOut in [[ stage_in ]],
                                      constant BloomUniforms &uniforms [[ buffer(0) ]],
                                      texture2d<float> source [[ texture(0) ]]) {
    // Karis average. A near-mirror metal reflects the environment's sun into a sub-pixel
    // spot worth thousands, and which pixel catches it jumps as the camera moves. A plain
    // mean lets that one sample dominate its neighbours, so the whole bloom halo pulses.
    // Weighting by 1/(1+luma) caps how much any single sample can contribute.
    float2 t = uniforms.texelSize;
    float3 taps[4] = {
        source.sample(postSampler, in.uv + t * float2(-0.5, -0.5)).rgb,
        source.sample(postSampler, in.uv + t * float2( 0.5, -0.5)).rgb,
        source.sample(postSampler, in.uv + t * float2(-0.5,  0.5)).rgb,
        source.sample(postSampler, in.uv + t * float2( 0.5,  0.5)).rgb,
    };

    float3 c = 0.0;
    float totalWeight = 0.0;
    for (uint i = 0; i < 4; ++i) {
        float luma = dot(taps[i], float3(0.2126, 0.7152, 0.0722));
        float w = 1.0 / (1.0 + luma);
        c += taps[i] * w;
        totalWeight += w;
    }
    c /= max(totalWeight, 1e-4);

    // Soft knee. A hard cutoff makes bloom switch on and off as a pixel crosses the
    // threshold, which flickers badly on a moving highlight — exactly what this scene has.
    float brightness = max(c.r, max(c.g, c.b));
    float soft = brightness - uniforms.threshold + uniforms.knee;
    soft = clamp(soft, 0.0, 2.0 * uniforms.knee);
    soft = soft * soft / (4.0 * uniforms.knee + 1e-4);

    float contribution = max(soft, brightness - uniforms.threshold) / max(brightness, 1e-4);
    float3 result = c * contribution;

    // Hard ceiling on what one pixel may feed the blur. Without it a single 13,000-value
    // reflection spreads that energy over ~100 pixels and the halo swamps the frame.
    // Values are still HDR — this only bounds the bloom source, not the scene.
    float peak = max(result.r, max(result.g, result.b));
    if (peak > uniforms.maxBrightness) {
        result *= uniforms.maxBrightness / peak;   // scale, don't clamp per channel: that shifts hue
    }

    return float4(result, 1.0);
}

/// Halves resolution. Four bilinear taps at the corners of a texel quad average 16 texels.
fragment float4 fragment_bloom_down(FullscreenOut in [[ stage_in ]],
                                    constant BloomUniforms &uniforms [[ buffer(0) ]],
                                    texture2d<float> source [[ texture(0) ]]) {
    float2 t = uniforms.texelSize;
    float3 sum = source.sample(postSampler, in.uv + t * float2(-1.0, -1.0)).rgb;
    sum += source.sample(postSampler, in.uv + t * float2( 1.0, -1.0)).rgb;
    sum += source.sample(postSampler, in.uv + t * float2(-1.0,  1.0)).rgb;
    sum += source.sample(postSampler, in.uv + t * float2( 1.0,  1.0)).rgb;
    return float4(sum * 0.25, 1.0);
}

/// Doubles resolution with a 3x3 tent filter. Blended additively onto the destination,
/// so each level accumulates the blur of every coarser level — that progressive
/// accumulation is what produces a wide, soft falloff instead of a single blur radius.
fragment float4 fragment_bloom_up(FullscreenOut in [[ stage_in ]],
                                  constant BloomUniforms &uniforms [[ buffer(0) ]],
                                  texture2d<float> source [[ texture(0) ]]) {
    float2 t = uniforms.texelSize;
    float3 sum = source.sample(postSampler, in.uv + t * float2(-1.0, -1.0)).rgb;
    sum += source.sample(postSampler, in.uv + t * float2( 0.0, -1.0)).rgb * 2.0;
    sum += source.sample(postSampler, in.uv + t * float2( 1.0, -1.0)).rgb;
    sum += source.sample(postSampler, in.uv + t * float2(-1.0,  0.0)).rgb * 2.0;
    sum += source.sample(postSampler, in.uv).rgb * 4.0;
    sum += source.sample(postSampler, in.uv + t * float2( 1.0,  0.0)).rgb * 2.0;
    sum += source.sample(postSampler, in.uv + t * float2(-1.0,  1.0)).rgb;
    sum += source.sample(postSampler, in.uv + t * float2( 0.0,  1.0)).rgb * 2.0;
    sum += source.sample(postSampler, in.uv + t * float2( 1.0,  1.0)).rgb;
    return float4(sum * (1.0 / 16.0), 1.0);
}

/// Scene + bloom, then exposure and tone mapping — the single place either now happens.
fragment half4 fragment_composite(FullscreenOut in [[ stage_in ]],
                                  constant PostUniforms &uniforms [[ buffer(0) ]],
                                  texture2d<float> sceneColor [[ texture(0) ]],
                                  texture2d<float> bloom [[ texture(1) ]]) {
    float3 color = sceneColor.sample(postSampler, in.uv).rgb;
    color += bloom.sample(postSampler, in.uv).rgb * uniforms.bloomIntensity;

    color *= uniforms.exposure;
    color = tonemapACES(color);

    // Vignette after tone mapping, so it darkens the presented image rather than acting
    // as a spatially varying exposure (which would also change the tone curve's response).
    float2 offset = in.uv - 0.5;
    color *= saturate(1.0 - dot(offset, offset) * uniforms.vignette);

    return half4(half3(color), 1.0h);
}
