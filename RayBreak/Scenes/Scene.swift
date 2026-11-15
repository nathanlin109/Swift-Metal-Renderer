//
//  Scene.swift
//  RayBreak
//
//  Created by Nathan Lin on 7/19/26.
//

import MetalKit

protocol SceneNodeDelegate {
    func transition(to scene: Scene)
}

class Scene: Node {
    var device: MTLDevice
    var size: CGSize {
        didSet {
            sceneSizeWillChange(to: size)
        }
    }
    var camera = Camera()
    var sceneConstants = SceneConstants()
    var lights: [Light] = [Light()]

    /// The scene's primary directional light — `lights[0]`. Kept as a named accessor
    /// because it's the one the shadow map is built from.
    var light: Light {
        get { lights[0] }
        set { lights[0] = newValue }
    }
    
    var sceneNodeDelegate: SceneNodeDelegate?
    
    /// Where the shadow frustum is centred. Each scene declares its own region of interest.
    var shadowCenter: SIMD3<Float> = .zero
    /// Half-width of the light's orthographic frustum. Only geometry inside this box casts
    /// or receives — tighter means sharper shadows, since the map's resolution is fixed.
    var shadowExtent: Float = 8
    
    /// Return true if the key was consumed.
    func keyDown(_ key: String) -> Bool { return false }
    func keyUp(_ key: String) -> Bool { return false }
    
    init(device: MTLDevice, size: CGSize) {
        self.device = device
        self.size = size
        super.init()
        
        // Derive from the actual drawable rather than hardcoding a phone's portrait ratio —
        // on Mac the window is resizable and starts wide.
        camera.aspect = size.height > 0 ? Float(size.width / size.height) : 1
        addChild(camera)
    }
    
    func renderShadow(commandEncoder: MTLRenderCommandEncoder, shadowMap: ShadowMap, frameIndex: Int) {
        sceneConstants.projectionMatrix = shadowMap.projectionMatrix
        commandEncoder.setVertexBytes(&sceneConstants,
                                      length: MemoryLayout<SceneConstants>.stride, index: 2)

        for child in children {
            child.render(commandEncoder: commandEncoder,
                         parentModelViewMatrix: shadowMap.viewMatrix,
                         parentModelMatrix: matrix_identity_float4x4,
                         pass: .shadow,
                         frameIndex: frameIndex)
        }
    }
    
    func render(commandEncoder: MTLRenderCommandEncoder, shadowMap: ShadowMap, skybox: SkyBox, frameIndex: Int) {
        Model.lightViewProjection = shadowMap.viewProjectionMatrix

        sceneConstants.projectionMatrix = camera.projectionMatrix
        // viewMatrix's 3x3 is R⁻¹; transposing recovers R, which maps view -> world.
        sceneConstants.viewToWorldRotation = camera.viewMatrix.upperLeft3x3().transpose
        sceneConstants.exposure = camera.exposure
        
        commandEncoder.setVertexBytes(&sceneConstants,
                                      length: MemoryLayout<SceneConstants>.stride, index: 2)
        commandEncoder.setFragmentBytes(&sceneConstants,
                                        length: MemoryLayout<SceneConstants>.stride, index: 2)
        
        // Lighting happens in view space, so both the directions and the positions have to
        // be converted. A direction takes the rotation only; a POSITION needs the full view
        // matrix — rotating a position without translating it puts the light in the wrong
        // place the moment the camera moves.
        let viewMatrix = camera.viewMatrix
        let viewRotation = viewMatrix.upperLeft3x3()

        var viewLights = lights
        for index in viewLights.indices {
            viewLights[index].direction = normalize(viewRotation * lights[index].direction)
            let p = matrix_multiply(viewMatrix, SIMD4<Float>(lights[index].position, 1))
            viewLights[index].position = SIMD3<Float>(p.x, p.y, p.z)
        }

        var lightCount = UInt32(min(viewLights.count, 8))
        viewLights.withUnsafeBytes { raw in
            commandEncoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 3)
        }
        commandEncoder.setFragmentBytes(&lightCount,
                                        length: MemoryLayout<UInt32>.stride, index: 4)

        commandEncoder.setFragmentTexture(shadowMap.texture, index: 3)
        commandEncoder.setFragmentTexture(skybox.irradianceCube, index: 4)
        commandEncoder.setFragmentTexture(skybox.prefilteredCube, index: 5)
        commandEncoder.setFragmentTexture(skybox.brdfLUT, index: 6)
        commandEncoder.setFragmentTexture(skybox.environmentCube, index: 7)

        for child in children {
            child.render(commandEncoder: commandEncoder,
                         parentModelViewMatrix: camera.viewMatrix,
                         parentModelMatrix: matrix_identity_float4x4,
                         pass: .main,
                         frameIndex: frameIndex)
        }
    }
    
    func update(deltaTime: Float) {
        
    }
    
    func sceneSizeWillChange(to size: CGSize) {
        // Guard against a zero-height drawable — a Mac window mid-resize can report one,
        // and dividing by it puts a NaN in the projection matrix that never washes out.
        guard size.height > 0 else { return }
        camera.aspect = Float(size.width / size.height)
    }
    
    func touchesBegan(_ view: UIView, touches: Set<UITouch>, with event: UIEvent?){}
    
    func touchesMoved(_ view: UIView, touches: Set<UITouch>, with event: UIEvent?) {}
    
    func touchesEnded(_ view: UIView, touches: Set<UITouch>, with event: UIEvent?) {}
    
    func touchesCancelled(_ view: UIView, touches: Set<UITouch>, with event: UIEvent?) {}
    
    func clearKeys() {}
}
