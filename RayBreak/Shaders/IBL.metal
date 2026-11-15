//
//  IBL.metal
//  RayBreak
//
//  Created by Nathan Lin on 8/26/26.
//

#include <metal_stdlib>
using namespace metal;

struct SceneConstants {
    float4x4 projectionMatrix;
    float3x3 viewToWorldRotation;
    float exposure;
};

struct SkyboxUniforms {
    float4x4 inverseProjection;
    float3x3 viewToWorldRotation;
    float exposure;
};

struct SkyboxOut {
    float4 position [[ position ]];
    float2 ndc;
};

struct PrefilterUniforms {
    float roughness;
    uint size;
};

constant float2 invAtan = float2(0.15915494, 0.31830989);   // 1/(2pi), 1/pi

static float2 equirectUV(float3 dir) {
    float2 uv = float2(atan2(dir.z, dir.x), asin(clamp(dir.y, -1.0, 1.0)));
    uv = uv * invAtan + 0.5;
    uv.y = 1.0 - uv.y;          // flip so +Y maps to the top of the image
    return uv;
}

/// Metal cube face order: 0=+X 1=-X 2=+Y 3=-Y 4=+Z 5=-Z
static float3 cubeDirection(uint face, float2 uv) {
    float u = uv.x, v = uv.y;
    switch (face) {
        case 0:  return normalize(float3( 1.0,   -v,   -u));
        case 1:  return normalize(float3(-1.0,   -v,    u));
        case 2:  return normalize(float3(   u,  1.0,    v));
        case 3:  return normalize(float3(   u, -1.0,   -v));
        case 4:  return normalize(float3(   u,   -v,  1.0));
        default: return normalize(float3(  -u,   -v, -1.0));
    }
}

// Van der Corput radical inverse — bit-reverses i to give a low-discrepancy sequence.
static float radicalInverseVdC(uint bits) {
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10;
}

static float2 hammersley(uint i, uint count) {
    return float2(float(i) / float(count), radicalInverseVdC(i));
}


/// Draws a half-vector from the GGX distribution rather than uniformly over the
/// hemisphere — most samples land where the lobe actually has energy.
static float3 importanceSampleGGX(float2 Xi, float3 N, float roughness) {
    float a = roughness * roughness;          // matches distributionGGX's convention

    float phi = 2.0 * M_PI_F * Xi.x;
    float cosTheta = sqrt((1.0 - Xi.y) / (1.0 + (a * a - 1.0) * Xi.y));
    float sinTheta = sqrt(1.0 - cosTheta * cosTheta);

    float3 H = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);

    float3 up = abs(N.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 tangentX = normalize(cross(up, N));
    float3 tangentY = cross(N, tangentX);
    return normalize(tangentX * H.x + tangentY * H.y + N * H.z);
}

static float distributionGGX_local(float NdotH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float d = max(NdotH * NdotH * (a2 - 1.0) + 1.0, 1e-7);
    return a2 / (M_PI_F * d * d);
}

// IBL uses k = a/2, NOT the (roughness+1)^2/8 remap in geometrySmith. That remap is
// derived for direct lighting only and is noticeably too dark here.
static float geometrySchlickGGX_IBL(float NdotV, float roughness) {
    float a = roughness * roughness;
    float k = a / 2.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

constexpr sampler equirectSampler(coord::normalized,
                                  filter::linear,
                                  address::repeat);

constexpr sampler cubeSampler(coord::normalized,
                              filter::linear,
                              mip_filter::linear,
                              address::clamp_to_edge);

kernel void equirect_to_cube(texture2d<float, access::sample> equirect [[ texture(0) ]],
                             texturecube<float, access::write> cube    [[ texture(1) ]],
                             uint3 gid [[ thread_position_in_grid ]]) {
    uint size = cube.get_width();
    if (gid.x >= size || gid.y >= size) { return; }

    // Pixel centre -> [-1, 1] across the face
    float2 uv = (float2(gid.xy) + 0.5) / float(size) * 2.0 - 1.0;
    float3 dir = cubeDirection(gid.z, uv);

    float4 color = equirect.sample(equirectSampler, equirectUV(dir));
    cube.write(color, gid.xy, gid.z);
}

vertex SkyboxOut vertex_skybox(uint vertexID [[ vertex_id ]]) {
    // One oversized triangle covering the viewport — cheaper than a quad and with no
    // diagonal seam. No vertex buffer is bound; these are generated from the index.
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    float2 p = positions[vertexID];

    SkyboxOut out;
    out.position = float4(p, 1.0, 1.0);   // z/w = 1.0 — sits exactly on the far plane
    out.ndc = p;                          // w is 1 everywhere, so this interpolates linearly
    return out;
}

kernel void irradiance_convolve(texturecube<float, access::sample> environment [[ texture(0) ]],
                                texturecube<float, access::write> irradiance  [[ texture(1) ]],
                                uint3 gid [[ thread_position_in_grid ]]) {
    uint size = irradiance.get_width();
    if (gid.x >= size || gid.y >= size) { return; }

    float2 uv = (float2(gid.xy) + 0.5) / float(size) * 2.0 - 1.0;
    float3 N = cubeDirection(gid.z, uv);

    // Any orthonormal basis around N. Swap the seed axis near the pole so cross() can't degenerate.
    float3 up = abs(N.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 right = normalize(cross(up, N));
    up = normalize(cross(N, right));

    float3 sum = 0.0;
    int samples = 0;
    const float delta = 0.025;

    for (float phi = 0.0; phi < 2.0 * M_PI_F; phi += delta) {
        for (float theta = 0.0; theta < 0.5 * M_PI_F; theta += delta) {
            float sinTheta = sin(theta);
            float cosTheta = cos(theta);

            float3 tangent = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            float3 direction = tangent.x * right + tangent.y * up + tangent.z * N;

            // cosTheta is the Lambert term; sinTheta is the solid-angle weight of the
            // spherical parameterisation (bands near the pole cover less area).
            // Mip 2 (256/face) instead of 0: we're integrating anyway, and it stops a
            // handful of near-sun texels from producing fireflies.
            sum += environment.sample(cubeSampler, direction, level(2.0)).rgb * cosTheta * sinTheta;
            samples++;
        }
    }

    // The PI here (rather than PI*PI) folds the Lambertian 1/PI into the stored value,
    // so the fragment shader can just do `irradiance * albedo`.
    float3 result = M_PI_F * sum / float(samples);
    irradiance.write(float4(result, 1.0), gid.xy, gid.z);
}

fragment half4 fragment_skybox(SkyboxOut in [[ stage_in ]],
                               constant SkyboxUniforms &uniforms [[ buffer(0) ]],
                               constant SceneConstants &sceneConstants [[ buffer(2) ]],
                               sampler cubeSampler [[ sampler(0) ]],
                               texturecube<float> environment [[ texture(0) ]]) {
    // Unproject the pixel to a view-space ray. z = 1 is the far plane in Metal's [0,1] range.
    float4 viewPosition = uniforms.inverseProjection * float4(in.ndc, 1.0, 1.0);
    float3 viewDirection = normalize(viewPosition.xyz / viewPosition.w);

    // Rotation only — a direction has no position, so the camera's translation is irrelevant.
    float3 worldDirection = uniforms.viewToWorldRotation * viewDirection;

    // Linear HDR out — exposure and tone mapping happen once at composite, so the sky
    // and the objects reflecting it are guaranteed to share one curve.
    float3 color = environment.sample(cubeSampler, worldDirection).rgb * uniforms.exposure;
    return half4(half3(color), 1.0h);
}

kernel void prefilter_environment(texturecube<float, access::sample> environment [[ texture(0) ]],
                                  texturecube<float, access::write> prefiltered  [[ texture(1) ]],
                                  constant PrefilterUniforms &uniforms [[ buffer(0) ]],
                                  uint3 gid [[ thread_position_in_grid ]]) {
    uint size = uniforms.size;
    if (gid.x >= size || gid.y >= size) { return; }

    float2 uv = (float2(gid.xy) + 0.5) / float(size) * 2.0 - 1.0;
    float3 N = cubeDirection(gid.z, uv);

    // The standard approximation: assume the viewer looks straight down the normal.
    // It costs the stretched grazing-angle reflections, which is why a 2D lookup
    // can stand in for what is really a 4D integral.
    float3 V = N;
    float roughness = uniforms.roughness;

    // Scale the sample count with roughness. A near-mirror lobe is almost a delta function
    // and converges in a handful of samples, while the rough mips genuinely need the full
    // count — and those mips are tiny, so their samples are cheap. This is what makes a
    // 256-per-face mip 0 affordable: flat 512 everywhere would be ~200M samples at launch.
    uint SAMPLE_COUNT = uint(mix(32.0, 512.0, roughness));
    float envSize = float(environment.get_width());
    float saTexel = 4.0 * M_PI_F / (6.0 * envSize * envSize);

    float3 color = 0.0;
    float totalWeight = 0.0;

    for (uint i = 0u; i < SAMPLE_COUNT; ++i) {
        float2 Xi = hammersley(i, SAMPLE_COUNT);
        float3 H = importanceSampleGGX(Xi, N, roughness);
        float3 L = normalize(2.0 * dot(V, H) * H - V);

        float NdotL = dot(N, L);
        if (NdotL <= 0.0) { continue; }

        // Pick a mip from the sample's solid angle. Without this, a few bright texels
        // get hit by single samples and show up as fireflies in the rough mips.
        float NdotH = saturate(dot(N, H));
        float HdotV = saturate(dot(H, V));
        float pdf = (distributionGGX_local(NdotH, roughness) * NdotH / (4.0 * HdotV)) + 1e-4;
        float saSample = 1.0 / (float(SAMPLE_COUNT) * pdf + 1e-4);
        float mip = 0.5 * log2(saSample / saTexel);
        
        color += environment.sample(cubeSampler, L, level(mip)).rgb * NdotL;
        totalWeight += NdotL;
    }

    prefiltered.write(float4(color / max(totalWeight, 1e-4), 1.0), gid.xy, gid.z);
}

kernel void integrate_brdf(texture2d<float, access::write> lut [[ texture(0) ]],
                           uint2 gid [[ thread_position_in_grid ]]) {
    uint width = lut.get_width();
    uint height = lut.get_height();
    if (gid.x >= width || gid.y >= height) { return; }

    float NdotV    = (float(gid.x) + 0.5) / float(width);
    float roughness = (float(gid.y) + 0.5) / float(height);

    float3 V = float3(sqrt(1.0 - NdotV * NdotV), 0.0, NdotV);
    float3 N = float3(0.0, 0.0, 1.0);

    const uint SAMPLE_COUNT = 1024u;
    float A = 0.0;
    float B = 0.0;

    for (uint i = 0u; i < SAMPLE_COUNT; ++i) {
        float2 Xi = hammersley(i, SAMPLE_COUNT);
        float3 H = importanceSampleGGX(Xi, N, roughness);
        float3 L = normalize(2.0 * dot(V, H) * H - V);

        float NdotL = saturate(L.z);
        if (NdotL <= 0.0) { continue; }

        float NdotH = saturate(H.z);
        float VdotH = saturate(dot(V, H));

        float G = geometrySchlickGGX_IBL(NdotV, roughness) * geometrySchlickGGX_IBL(NdotL, roughness);
        float GVis = (G * VdotH) / (NdotH * NdotV);
        float Fc = pow(1.0 - VdotH, 5.0);

        A += (1.0 - Fc) * GVis;   // scale on F0
        B += Fc * GVis;           // bias
    }

    lut.write(float4(A / float(SAMPLE_COUNT), B / float(SAMPLE_COUNT), 0.0, 1.0), gid);
}
