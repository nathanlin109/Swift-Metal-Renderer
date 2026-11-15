//
//  Types.swift
//  RayBreak
//
//  Created by Nathan Lin on 7/21/26.
//

import simd

struct Vertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
    var texture: SIMD2<Float>
}

struct ModelConstants {
    var modelViewMatrix = matrix_identity_float4x4
    var shadowMatrix = matrix_identity_float4x4     // lightViewProjection * world
    var albedo = SIMD4<Float>(repeating: 1)
    var normalMatrix = matrix_identity_float3x3
    var metallic = Float(0)
    var roughness = Float(0.5)
    var ao = Float(1)
    var emissiveStrength = Float(0)
    /// Texture coordinates are multiplied by this before sampling, so one material can
    /// tile across a large surface. SIMD2 is free here — it lands in the same padding a
    /// single Float would, and the struct rounds to a 224 stride either way.
    var uvScale = SIMD2<Float>(1, 1)
}

struct SceneConstants {
    var projectionMatrix = matrix_identity_float4x4
    var viewToWorldRotation = matrix_identity_float3x3
    var exposure = Float(1)
}

struct Light {
    var color = SIMD3<Float>(repeating: 1)
    var ambientIntensity = Float(1)
    var diffuseIntensity = Float(1)
    /// Direction of travel. Directional lights only.
    var direction = SIMD3<Float>(repeating: 0)
    /// World position. Point lights only.
    var position = SIMD3<Float>(repeating: 0)
    /// Contribution is forced to zero past this distance, so the falloff reaches 0
    /// smoothly instead of popping when a light drops out.
    var range = Float(20)
    var type = LightType.directional.rawValue
}

struct SkyboxUniforms {
    var inverseProjection = matrix_identity_float4x4
    var viewToWorldRotation = matrix_identity_float3x3
    var exposure = Float(1)
}

struct PrefilterUniforms {
    var roughness: Float
    var size: UInt32
}

enum LightType: UInt32 {
    case directional = 0
    case point = 1
}

struct BloomUniforms {
    /// Texel size of the SOURCE texture, not the destination.
    var texelSize = SIMD2<Float>(1, 1)
    var threshold = Float(1)
    var knee = Float(0.5)
    /// Ceiling on a single pixel's contribution to the blur — firefly suppression.
    var maxBrightness = Float(12)
}

struct PostUniforms {
    var exposure = Float(1)
    var bloomIntensity = Float(0.06)
    var vignette = Float(0.25)
}
