//
//  Shader.metal
//  RayBreak
//
//  Created by Nathan Lin on 7/13/26.
//

#include <metal_stdlib>
using namespace metal;

struct ModelConstants {
    float4x4 modelViewMatrix;
    float4x4 shadowMatrix;
    float4 albedo;
    float3x3 normalMatrix;
    float metallic;
    float roughness;
    float ao;
    float emissiveStrength;
    float2 uvScale;
};

struct SceneConstants {
    float4x4 projectionMatrix;
    float3x3 viewToWorldRotation;
    float exposure;
};

constant uint LIGHT_DIRECTIONAL = 0;
constant uint LIGHT_POINT = 1;
constant uint MAX_LIGHTS = 8;

struct Light {
    float3 color;
    float ambientIntensity;
    float diffuseIntensity;
    float3 direction;
    float3 position;
    float range;
    uint type;
};

struct VertexIn {
    float4 position [[ attribute(0) ]];
    float4 color [[ attribute(1) ]];
    float2 textureCoordinates [[ attribute(2) ]];
    float3 normal [[ attribute(3) ]];
    float3 tangent [[ attribute(4) ]];
    float3 bitangent [[ attribute(5) ]];
};

struct VertexOut {
    float4 position [[ position ]];
    float4 color;
    float2 textureCoordinates [[ attribute(2) ]];
    float4 albedo;
    float3 normal;
    float3 tangent;
    float3 bitangent;
    float metallic;
    float roughness;
    float ao;
    float emissiveStrength;
    float3 eyePosition;
    float4 shadowPosition;
};

struct DepthVertexIn {
    float4 position [[ attribute(0) ]];
};

struct DepthVertexOut {
    float4 position [[ position ]];
};

constant float PI = 3.14159265359;

constexpr sampler iblSampler(coord::normalized,
                             filter::linear,
                             mip_filter::linear,
                             address::clamp_to_edge);

constexpr sampler lutSampler(coord::normalized,
                             filter::linear,
                             mip_filter::none,
                             address::clamp_to_edge);   // repeat would wrap the roughness axis

// GGX / Trowbridge-Reitz normal distribution
static float distributionGGX(float NdotH, float roughness) {
    float a  = roughness * roughness;
    float a2 = a * a;
    float d  = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}

// Smith geometry term, Schlick-GGX with the direct-lighting remap of k
static float geometrySmith(float NdotV, float NdotL, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    float ggxV = NdotV / (NdotV * (1.0 - k) + k);
    float ggxL = NdotL / (NdotL * (1.0 - k) + k);
    return ggxV * ggxL;
}

static float3 fresnelSchlick(float VdotH, float3 F0) {
    return F0 + (1.0 - F0) * pow(saturate(1.0 - VdotH), 5.0);
}

// For IBL the incoming light comes from every direction at once, so there's no half-vector.
// Use N·V, and let roughness raise the grazing response — a rough surface still reflects
// broadly at glancing angles, which plain Schlick under-predicts.
static float3 fresnelSchlickRoughness(float cosTheta, float3 F0, float roughness) {
    float3 Fr = max(float3(1.0 - roughness), F0);
    return F0 + (Fr - F0) * pow(saturate(1.0 - cosTheta), 5.0);
}

constexpr sampler shadowSampler(coord::normalized,
                                filter::linear,
                                mip_filter::none,
                                address::clamp_to_edge,
                                compare_func::less);

static float shadowFactor(depth2d<float> shadowMap, float4 shadowPosition) {
    float3 proj = shadowPosition.xyz / shadowPosition.w;

    // Metal NDC is y-up in [-1,1]; texture coords are y-down in [0,1]. The Y flip
    // is mandatory — without it the shadow appears mirrored vertically.
    float2 uv = proj.xy * float2(0.5, -0.5) + 0.5;

    // Outside the light's frustum we have no depth information. Return lit, never
    // shadowed — the alternative makes everything beyond `extent` go black.
    if (any(uv < 0.0) || any(uv > 1.0) || proj.z > 1.0) { return 1.0; }

    float depth = proj.z - 0.0015;   // constant bias, on top of the encoder's slope bias

    // 3x3 PCF. sample_compare runs the depth test in hardware and filters the RESULT,
    // which is what gives soft edges — averaging raw depths would just blur the
    // occluder surface and produce a hard edge in the wrong place.
    float2 texel = 1.0 / float2(shadowMap.get_width(), shadowMap.get_height());
    float sum = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            sum += shadowMap.sample_compare(shadowSampler, uv + float2(x, y) * texel, depth);
        }
    }
    return sum / 9.0;
}


vertex VertexOut vertex_shader(const VertexIn vertexIn [[ stage_in ]],
                               constant ModelConstants &modelConstants [[ buffer(1) ]],
                               constant SceneConstants &sceneConstants [[ buffer(2) ]]) {
    
    VertexOut vertexOut;
    vertexOut.position = sceneConstants.projectionMatrix * modelConstants.modelViewMatrix * vertexIn.position;
    vertexOut.color = vertexIn.color;
    vertexOut.textureCoordinates = vertexIn.textureCoordinates * modelConstants.uvScale;
    vertexOut.albedo = modelConstants.albedo;
    vertexOut.normal = modelConstants.normalMatrix * vertexIn.normal;
    vertexOut.tangent = modelConstants.normalMatrix * vertexIn.tangent;
    vertexOut.bitangent = modelConstants.normalMatrix * vertexIn.bitangent;
    vertexOut.metallic = modelConstants.metallic;
    vertexOut.roughness = modelConstants.roughness;
    vertexOut.ao = modelConstants.ao;
    vertexOut.emissiveStrength = modelConstants.emissiveStrength;
    vertexOut.eyePosition = (modelConstants.modelViewMatrix * vertexIn.position).xyz;
    vertexOut.shadowPosition = modelConstants.shadowMatrix * vertexIn.position;
    
    return vertexOut;
}

vertex VertexOut vertex_instance_shader(const VertexIn vertexIn [[ stage_in ]],
                                        constant ModelConstants *instances [[ buffer(1) ]],
                                        constant SceneConstants &sceneConstants [[ buffer(2) ]],
                                        uint instanceId [[ instance_id ]]) {
    ModelConstants modelConstants = instances[instanceId];
    
    VertexOut vertexOut;
    vertexOut.position = sceneConstants.projectionMatrix * modelConstants.modelViewMatrix * vertexIn.position;
    vertexOut.color = vertexIn.color;
    vertexOut.textureCoordinates = vertexIn.textureCoordinates * modelConstants.uvScale;
    vertexOut.albedo = modelConstants.albedo;
    vertexOut.normal = modelConstants.normalMatrix * vertexIn.normal;
    vertexOut.tangent = modelConstants.normalMatrix * vertexIn.tangent;
    vertexOut.bitangent = modelConstants.normalMatrix * vertexIn.bitangent;
    vertexOut.metallic = modelConstants.metallic;
    vertexOut.roughness = modelConstants.roughness;
    vertexOut.ao = modelConstants.ao;
    vertexOut.emissiveStrength = modelConstants.emissiveStrength;
    vertexOut.eyePosition = (modelConstants.modelViewMatrix * vertexIn.position).xyz;
    vertexOut.shadowPosition = modelConstants.shadowMatrix * vertexIn.position;
    
    return vertexOut;
}

vertex DepthVertexOut vertex_depth(const DepthVertexIn vertexIn [[ stage_in ]],
                                   constant ModelConstants &modelConstants [[ buffer(1) ]],
                                   constant SceneConstants &sceneConstants [[ buffer(2) ]]) {
    DepthVertexOut out;
    out.position = sceneConstants.projectionMatrix * modelConstants.modelViewMatrix * vertexIn.position;
    return out;
}

/// Instanced depth pass. Must index by instance_id — a single `constant ModelConstants &`
/// would give every instance element 0's matrix, collapsing N shadows into one.
vertex DepthVertexOut vertex_depth_instance(const DepthVertexIn vertexIn [[ stage_in ]],
                                            constant ModelConstants *instances [[ buffer(1) ]],
                                            constant SceneConstants &sceneConstants [[ buffer(2) ]],
                                            uint instanceId [[ instance_id ]]) {
    DepthVertexOut out;
    out.position = sceneConstants.projectionMatrix
                 * instances[instanceId].modelViewMatrix
                 * vertexIn.position;
    return out;
}

fragment half4 fragment_shader(const VertexOut vertexIn [[ stage_in ]]) {
    return half4(vertexIn.color);
}

fragment half4 textured_fragment(const VertexOut vertexIn [[ stage_in ]],
                                 sampler sampler2d [[ sampler(0) ]],
                                 texture2d<float> texture [[ texture(0) ]]) {
    float4 color = texture.sample(sampler2d, vertexIn.textureCoordinates);
    
    float4 finalColor = color * vertexIn.albedo;
    
    return half4(finalColor.r, finalColor.g, finalColor.b, 1);
}

fragment half4 pbr_textured_fragment(const VertexOut vertexIn [[ stage_in ]],
                                     sampler sampler2d [[ sampler(0) ]],
                                     constant SceneConstants &sceneConstants [[ buffer(2) ]],
                                     constant Light *lights [[ buffer(3) ]],
                                     constant uint &lightCount [[ buffer(4) ]],
                                     texture2d<float> albedoMap [[ texture(0) ]],
                                     texture2d<float> ormMap [[ texture(1) ]],
                                     texture2d<float> normalMap [[ texture(2) ]],
                                     depth2d<float> shadowMap [[ texture(3) ]],
                                     texturecube<float> irradianceMap [[ texture(4) ]],
                                     texturecube<float> prefilteredMap [[ texture(5) ]],
                                     texture2d<float>   brdfLUT        [[ texture(6) ]],
                                     texturecube<float> environmentMap [[ texture(7) ]]) {
    float3 albedo = albedoMap.sample(sampler2d, vertexIn.textureCoordinates).rgb
                  * vertexIn.albedo.rgb;

    // glTF ORM packing: R = occlusion, G = roughness, B = metallic.
    // Each channel is a map x factor, so an absent map (white) leaves the factor alone.
    float3 orm = ormMap.sample(sampler2d, vertexIn.textureCoordinates).rgb;
    float ao        = orm.r * vertexIn.ao;
    float roughness = clamp(orm.g * vertexIn.roughness, 0.005, 1.0);
    float metallic  = saturate(orm.b * vertexIn.metallic);

    // Linear interpolation across the triangle leaves T, B, N non-orthogonal and
    // non-unit, so rebuild the basis per fragment (Gram-Schmidt).
    float3 N = normalize(vertexIn.normal);
    float3 T = normalize(vertexIn.tangent - dot(vertexIn.tangent, N) * N);
    float3 B = normalize(cross(N, T));
    // Recover handedness — mirrored UVs flip the bitangent relative to cross(N,T).
    if (dot(B, vertexIn.bitangent) < 0.0) { B = -B; }

    float3x3 TBN = float3x3(T, B, N);   // columns, so TBN * v maps tangent -> view

    float3 tangentNormal = normalMap.sample(sampler2d, vertexIn.textureCoordinates).xyz * 2.0 - 1.0;
    N = normalize(TBN * tangentNormal);
    float3 V = normalize(-vertexIn.eyePosition);  // camera is at the origin in view space
    
    float NdotV = saturate(dot(N, V)) + 1e-4;
    // Dielectrics reflect ~4% head-on; metals tint their reflection with albedo instead.
    float3 F0 = mix(float3(0.04), albedo, metallic);
    
    float3 Lo = 0.0;

    for (uint i = 0; i < min(lightCount, MAX_LIGHTS); ++i) {
        Light lit = lights[i];

        float3 L;
        float attenuation = 1.0;

        if (lit.type == LIGHT_POINT) {
            // Both are in view space, so this is a straight subtraction.
            float3 toLight = lit.position - vertexIn.eyePosition;
            float distance = length(toLight);
            if (distance > lit.range) { continue; }

            L = toLight / max(distance, 1e-4);

            // Inverse-square, windowed so it reaches exactly zero at `range` rather than
            // cutting off at a visible value.
            float d2 = distance * distance;
            float window = saturate(1.0 - pow(distance / lit.range, 4.0));
            attenuation = (window * window) / max(d2, 1e-4);
        } else {
            L = normalize(-lit.direction);
        }

        float NdotL = saturate(dot(N, L));
        if (NdotL <= 0.0) { continue; }

        float3 H = normalize(V + L);
        float NdotH = saturate(dot(N, H));
        float VdotH = saturate(dot(V, H));

        float  D = distributionGGX(NdotH, roughness);
        float  G = geometrySmith(NdotV, NdotL, roughness);
        float3 F = fresnelSchlick(VdotH, F0);

        float3 specular = (D * G * F) / (4.0 * NdotV * NdotL + 1e-4);
        float3 kD = (1.0 - F) * (1.0 - metallic);

        // Only the directional light has a shadow map. A point light would need
        // map and six passes, so it casts no shadow for now.
        float shadow = (lit.type == LIGHT_DIRECTIONAL)
                     ? shadowFactor(shadowMap, vertexIn.shadowPosition)
                     : 1.0;

        float3 radiance = lit.color * lit.diffuseIntensity * attenuation;
        Lo += (kD * albedo / PI + specular) * radiance * NdotL * shadow;
    }
    
    // Diffuse IBL. The 1/PI is already folded into the irradiance map, so this is just
    // albedo * E. kD is recomputed here with the view-based, roughness-aware Fresnel —
    // and kS will be reused for specular IBL in the next step.
    float3 kSambient = fresnelSchlickRoughness(NdotV, F0, roughness);
    float3 kDambient = (1.0 - kSambient) * (1.0 - metallic);

    // The irradiance cube is in WORLD space; N is in view space. Rotate before sampling,
    // or the environment appears welded to the camera.
    float3 worldN = sceneConstants.viewToWorldRotation * N;
    float3 irradiance = irradianceMap.sample(iblSampler, worldN).rgb;
    float3 diffuseIBL = kDambient * irradiance * albedo;

    // Specular IBL, split-sum. R is view space like N and V, so rotate it to world.
    float3 R = reflect(-V, N);
    float3 worldR = sceneConstants.viewToWorldRotation * R;

    float maxMip = float(prefilteredMap.get_num_mip_levels() - 1);
    float3 rough = prefilteredMap.sample(iblSampler, worldR, level(roughness * maxMip)).rgb;

    // The prefiltered chain's top mip is resolution-limited, so near-mirror materials read
    // the full-res environment instead. Its mips are box-filtered rather than GGX-convolved,
    // but at this roughness the lobe is narrow enough that the difference doesn't show.
    float envMaxMip = float(environmentMap.get_num_mip_levels() - 1);
    float3 sharp = environmentMap.sample(iblSampler, worldR, level(roughness * envMaxMip * 2.0)).rgb;

    float3 prefiltered = mix(sharp, rough, saturate(roughness / 0.25));

    // brdf.x scales F0, brdf.y is an additive bias — this is the half of the split-sum
    // that depends on the BRDF rather than the environment.
    float2 brdf = brdfLUT.sample(lutSampler, float2(NdotV, roughness)).rg;
    float3 specularIBL = prefiltered * (kSambient * brdf.x + brdf.y);
    
    float3 ambient = (diffuseIBL + specularIBL) * ao;

    float3 color = ambient + Lo + albedo * vertexIn.emissiveStrength;
    // No tone map here any more — the scene renders to a float target so bloom can see
    // values above 1.0. Exposure and ACES both happen once, in fragment_composite.

    return half4(half3(color), 1.0h);
}

fragment half4 fragment_color(const VertexOut vertexIn [[ stage_in ]]) {
    return half4(vertexIn.albedo);
}
