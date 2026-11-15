//
//  Material.swift
//  RayBreak
//

import MetalKit

/// Everything about how a surface responds to light, in one place.
///
/// The factors and the maps used to live apart — factors on `Node`, textures on `Model` —
/// which is how a `metallic` factor of 0 silently cancelled a fully-metallic ORM map with
/// nothing in the code putting those two facts side by side.
///
/// Every factor is a **multiplier** on its map, so the neutral value is always 1.0.
/// A material with no maps is driven entirely by its factors, because a missing map
/// resolves to a neutral 1x1 texture.
struct Material {

    // MARK: - Factors

    var albedo = SIMD4<Float>(repeating: 1)
    var metallic = Float(1)
    var roughness = Float(1)
    var ao = Float(1)
    var emissiveStrength = Float(0)
    /// Multiplies texture coordinates. Raise it to tile a material across a large surface;
    /// requires the sampler's address mode to be .repeat, not .clampToEdge.
    var uvScale = SIMD2<Float>(1, 1)

    // MARK: - Maps

    /// Colour art, loaded sRGB. Everything below is data and must stay linear.
    var albedoTexture: MTLTexture?
    /// glTF ORM packing: R = occlusion, G = roughness, B = metallic.
    var ormTexture: MTLTexture?
    var normalTexture: MTLTexture?

    // MARK: - Binding

    func apply(to constants: inout ModelConstants) {
        constants.albedo = albedo
        constants.metallic = metallic
        constants.roughness = roughness
        constants.ao = ao
        constants.emissiveStrength = emissiveStrength
        constants.uvScale = uvScale
    }

    /// Binds all three maps, substituting neutral 1x1 textures where a map is absent so the
    /// shader can sample unconditionally — no branching, no separate pipeline variants.
    func bindTextures(to commandEncoder: MTLRenderCommandEncoder) {
        let device = commandEncoder.device
        let white = DefaultTextures.white(device: device)
        let flat = DefaultTextures.flatNormal(device: device)

        commandEncoder.setFragmentTexture(albedoTexture ?? white, index: 0)
        commandEncoder.setFragmentTexture(ormTexture ?? white, index: 1)
        commandEncoder.setFragmentTexture(normalTexture ?? flat, index: 2)
    }
}

extension Material {

    /// A dielectric with no maps — plastic, ceramic, painted surfaces.
    static func dielectric(albedo: SIMD3<Float>, roughness: Float) -> Material {
        var material = Material()
        material.albedo = SIMD4<Float>(albedo, 1)
        material.metallic = 0
        material.roughness = roughness
        return material
    }

    /// A metal with no maps. For metals the albedo *is* F0 — the tinted reflectance —
    /// rather than a diffuse colour, since metals have no diffuse response at all.
    static func metal(f0: SIMD3<Float>, roughness: Float) -> Material {
        var material = Material()
        material.albedo = SIMD4<Float>(f0, 1)
        material.metallic = 1
        material.roughness = roughness
        return material
    }
}
