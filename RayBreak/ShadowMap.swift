//
//  ShadowMap.swift
//  RayBreak
//
//  Created by Nathan Lin on 8/24/26.
//

import MetalKit

/// Offscreen depth-only target for one directional light.
class ShadowMap {
    static var size: Int { RenderSettings.shadowMapSize }

    /// Half-width of the orthographic light frustum. Must enclose everything that
    /// casts or receives — too large wastes resolution, too small clips shadows off.
    var extent: Float = 8
    var nearZ: Float = 0.1
    var farZ: Float = 40
    /// How far back along the light direction to place the light's "camera".
    var distance: Float = 20

    let texture: MTLTexture
    let renderPassDescriptor = MTLRenderPassDescriptor()

    private(set) var viewMatrix = matrix_identity_float4x4
    private(set) var projectionMatrix = matrix_identity_float4x4
    var viewProjectionMatrix: matrix_float4x4 {
        matrix_multiply(projectionMatrix, viewMatrix)
    }

    init(device: MTLDevice) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: ShadowMap.size, height: ShadowMap.size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("could not create shadow map")
        }
        self.texture = texture

        renderPassDescriptor.depthAttachment.texture = texture
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 1.0
        // No colour attachment at all — this pass writes dept
    }

    /// A directional light has no position, so place a virtual camera back along the
    /// direction of travel and frame the scene centre.
    func update(light: Light, center: SIMD3<Float> = .zero) {
        let direction = normalize(light.direction)      // poi
        let eye = center - direction * distance

        // cross() degenerates when the light is near-vertical; swap the up axis.
        var up = SIMD3<Float>(0, 1, 0)
        if abs(dot(direction, up)) > 0.99 { up = SIMD3<Float>(0, 0, 1) }

        viewMatrix = matrix_float4x4(lookAtEye: eye, target: center, up: up)
        projectionMatrix = matrix_float4x4(
            orthographicLeft: -extent,
            right: extent,
            bottom: -extent, top: extent,
            nearZ: nearZ, farZ: farZ
        )
    }
}
