//
//  Camera.swift
//  RayBreak
//
//  Created by Nathan Lin on 8/2/26.
//

import MetalKit

class Camera: Node {
    var fovDegrees: Float = 65
    var aspect: Float = 1
    var nearZ: Float = 0.1
    var farZ: Float = 100

    // Fly-camera state
    /// x = strafe (+right), y = rise (+up), z = advance (+forward). Magnitude <= 1.
    var moveInput: SIMD3<Float> = .zero
    var moveSpeed: Float = 6          // world units per second
    var pitchLimit: Float = 1.4       // ~80 degrees, stops you tumbling over the top
    
    var exposure: Float = 0.5

    var viewMatrix: matrix_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix = matrix.rotatedBy(rotationAngle: -rotation.x, x: 1, y: 0, z: 0)
        matrix = matrix.rotatedBy(rotationAngle: -rotation.y, x: 0, y: 1, z: 0)
        matrix = matrix.translatedBy(x: -position.x, y: -position.y, z: -position.z)
        return matrix
    }

    /// The view matrix's 3x3 is R⁻¹, and R is orthonormal, so R⁻¹ == Rᵀ.
    /// Transposing recovers R, whose columns are the camera's world-space axes.
    private var worldBasis: matrix_float3x3 {
        return viewMatrix.upperLeft3x3().transpose
    }

    var right:   SIMD3<Float> { worldBasis.columns.0 }
    var up:      SIMD3<Float> { worldBasis.columns.1 }
    var forward: SIMD3<Float> { -worldBasis.columns.2 }   //

    func clampPitch() {
        rotation.x = min(max(rotation.x, -pitchLimit), pitchLimit)
    }

    /// Point the camera at a world-space target.
    ///
    /// Derived by inverting `forward` rather than by assuming a convention: this project's
    /// `matrix_float4x4(rotationAngle:x:y:z:)` builds a NEGATED rotation compared to the
    /// textbook form, so working it out from first principles gives the wrong signs.
    /// Expanding the real basis gives
    ///     forward = (cos(pitch)·sin(yaw), −sin(pitch), −cos(pitch)·cos(yaw))
    /// which inverts to the two lines below.
    func look(at target: SIMD3<Float>) {
        let offset = target - position
        guard length_squared(offset) > 1e-8 else { return }
        let f = normalize(offset)

        rotation.x = -asin(max(-1, min(1, f.y)))
        rotation.y = atan2(f.x, -f.z)
        rotation.z = 0
    }

    func update(deltaTime: Float) {
        guard length_squared(moveInput) > 1e-6 else { return }
        
        let basis = worldBasis     // compute once; the getters each rebuild viewMatrix
        let direction = basis.columns.0 * moveInput.x
        + basis.columns.1 * moveInput.y
        - basis.columns.2 * moveInput.z
        
        guard length_squared(direction) > 1e-6 else { return }
            // Normalize so holding W+D isn't 1.41x faster than W
            position += normalize(direction) * moveSpeed * deltaTime
    }

    var fovRadians: Float { radians(fromDegrees: fovDegrees) }

    var projectionMatrix: matrix_float4x4 {
        return matrix_float4x4(projectionFov: fovRadians,
                               aspect: aspect,
                               nearZ: nearZ,
                               farZ: farZ)
    }
}
