//
//  DefaultTextures.swift
//  RayBreak
//
//  Created by Nathan Lin on 8/19/26.
//

import MetalKit

/// 1x1 white fallback, so a missing map is a mathematical no-op:
/// albedo 1.0 x factor = factor, and ORM (1,1,1) = unoccluded x factor for each channel.
enum DefaultTextures {
    private static var cache: [ObjectIdentifier: MTLTexture] = [:]
    private static var flatNormalCache: [ObjectIdentifier: MTLTexture] = [:]

    static func white(device: MTLDevice) -> MTLTexture {
        let key = ObjectIdentifier(device)
        if let cached = cache[key] { return cached }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,   // linear, NOT _srgb — this feeds the ORM slot
            width: 1,
            height: 1,
            mipmapped: false)
        descriptor.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("could not create fallback texture")
        }

        var pixel: [UInt8] = [255, 255, 255, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                        mipmapLevel: 0,
                        withBytes: &pixel,
                        bytesPerRow: 4)

        cache[key] = texture
        return texture
    }
    
    /// (128,128,255) decodes to (0,0,1) — the unperturbed tangent-space normal.
    /// White would decode to a 45-degree tilt on every axis.
    static func flatNormal(device: MTLDevice) -> MTLTexture {
        let key = ObjectIdentifier(device)
        if let cached = flatNormalCache[key] { return cached }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,   // linear, same as the ORM slot
            width: 1,
            height: 1,
            mipmapped: false)
        descriptor.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("could not create flat normal texture")
        }

        var pixel: [UInt8] = [128, 128, 255, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                        mipmapLevel: 0,
                        withBytes: &pixel,
                        bytesPerRow: 4)

        flatNormalCache[key] = texture
        return texture
    }
}
