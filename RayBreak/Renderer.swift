//
//  Renderer.swift
//  RayBreak
//
//  Created by Nathan Lin on 7/13/26.
//

import Foundation
import MetalKit

enum RenderSettings {
    static let sampleCount = 4
    /// The scene renders to a float target rather than straight to the drawable, so the
    /// post chain can see values above 1.0. Everything that used to tone map inside a
    /// material shader now outputs linear HDR and is compressed once, at composite.
    static let hdrFormat: MTLPixelFormat = .rgba16Float
    static let depthFormat: MTLPixelFormat = .depth32Float
    static let outputFormat: MTLPixelFormat = .bgra8Unorm_srgb

    // Desktop has the memory and the GPU headroom that a phone budget was sized against.
    #if targetEnvironment(macCatalyst)
    static let shadowMapSize = 4096
    static let prefilteredSize = 256
    static let prefilteredMipCount = 7
    #else
    static let shadowMapSize = 2048
    static let prefilteredSize = 128
    static let prefilteredMipCount = 6
    #endif
    
    static let maxFramesInFlight = 3
}

class Renderer : NSObject {
    var device: MTLDevice
    var commandQueue: MTLCommandQueue

    var scene: Scene?

    var samplerState: MTLSamplerState?
    var depthStencilState: MTLDepthStencilState?

    var shadowMap: ShadowMap!

    var skybox: SkyBox!
    var skyboxPipelineState: MTLRenderPipelineState!
    var skyboxDepthStencilState: MTLDepthStencilState!

    var bloom: Bloom!
    var compositePipelineState: MTLRenderPipelineState!

    /// Applied once, at composite. Raise to brighten the whole image.
    var exposure: Float = 1.0
    var vignette: Float = 0.25
    
    var frameTimer: FrameTimer
    
    private let inFlightSemaphore = DispatchSemaphore(value: RenderSettings.maxFramesInFlight)
    private var frameIndex = 0

    // Offscreen scene targets, recreated whenever the drawable resizes.
    private var sceneColorMS: MTLTexture?
    private var sceneColor: MTLTexture?
    private var sceneDepthMS: MTLTexture?
    private var targetSize = CGSize.zero

    init(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.device = device
        self.commandQueue = commandQueue
        frameTimer = FrameTimer()
        super.init()
        buildSamplerState()
        buildDepthStencilState()
        buildSkyboxPipelineState()
        buildSkyboxDepthStencilState()
        buildCompositePipelineState()
        shadowMap = ShadowMap(device: device)
        bloom = Bloom(device: device)
        skybox = SkyBox(device: device, commandQueue: commandQueue, name: "golden_bay_4k")
    }

    private func buildSamplerState() {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear      // without this the mip chain is ignored
        descriptor.maxAnisotropy = 8        // grazing angles — a pot has lots of them
        // Required for uvScale > 1. The default is .clampToEdge, which would smear the
        // border texels across the whole surface instead of repeating the texture.
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        samplerState = device.makeSamplerState(descriptor: descriptor)
    }

    private func buildDepthStencilState() {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .less
        descriptor.isDepthWriteEnabled = true
        depthStencilState = device.makeDepthStencilState(descriptor: descriptor)
    }

    private func buildSkyboxPipelineState() {
        let library = device.makeDefaultLibrary()
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library?.makeFunction(name: "vertex_skybox")
        descriptor.fragmentFunction = library?.makeFunction(name: "fragment_skybox")
        descriptor.colorAttachments[0].pixelFormat = RenderSettings.hdrFormat
        descriptor.depthAttachmentPixelFormat = RenderSettings.depthFormat
        descriptor.rasterSampleCount = RenderSettings.sampleCount   // MUST match the scene pass
        // No vertexDescriptor — vertices come from vertex_id.

        skyboxPipelineState = try! device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func buildSkyboxDepthStencilState() {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual   // z == 1.0 must pass against cleared depth
        descriptor.isDepthWriteEnabled = false         // the sky never occludes anything
        skyboxDepthStencilState = device.makeDepthStencilState(descriptor: descriptor)
    }

    private func buildCompositePipelineState() {
        let library = device.makeDefaultLibrary()
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library?.makeFunction(name: "vertex_fullscreen")
        descriptor.fragmentFunction = library?.makeFunction(name: "fragment_composite")
        descriptor.colorAttachments[0].pixelFormat = RenderSettings.outputFormat
        // The drawable is single-sampled now: MSAA happens in the offscreen scene pass and
        // is resolved before post runs. No depth attachment — this is a fullscreen triangle.
        descriptor.rasterSampleCount = 1

        compositePipelineState = try! device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - Offscreen targets

    private func makeRenderTargets(size: CGSize) {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return }
        targetSize = size

        // The multisampled attachments are resolved or discarded inside the pass and never
        // read afterwards, so on Apple GPUs they can live entirely in tile memory. At
        // 2560x1664 that avoids roughly 200 MB of real allocation.
        let transient: MTLStorageMode = device.supportsFamily(.apple2) ? .memoryless : .private

        let msColor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderSettings.hdrFormat, width: width, height: height, mipmapped: false)
        msColor.textureType = .type2DMultisample
        msColor.sampleCount = RenderSettings.sampleCount
        msColor.usage = .renderTarget
        msColor.storageMode = transient
        sceneColorMS = device.makeTexture(descriptor: msColor)
        sceneColorMS?.label = "Scene Colour (MSAA)"

        let resolved = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderSettings.hdrFormat, width: width, height: height, mipmapped: false)
        resolved.usage = [.renderTarget, .shaderRead]
        resolved.storageMode = .private
        sceneColor = device.makeTexture(descriptor: resolved)
        sceneColor?.label = "Scene Colour (HDR)"

        let msDepth = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderSettings.depthFormat, width: width, height: height, mipmapped: false)
        msDepth.textureType = .type2DMultisample
        msDepth.sampleCount = RenderSettings.sampleCount
        msDepth.usage = .renderTarget
        msDepth.storageMode = transient
        sceneDepthMS = device.makeTexture(descriptor: msDepth)
        sceneDepthMS?.label = "Scene Depth (MSAA)"

        bloom.resize(device: device, width: width, height: height)
    }
}

extension Renderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        scene?.sceneSizeWillChange(to: size)
        makeRenderTargets(size: size)
    }

    func draw(in view: MTKView) {
        guard let scene = scene,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        inFlightSemaphore.wait()
        
        commandBuffer.addCompletedHandler{ [weak self, inFlightSemaphore] buffer in
            inFlightSemaphore.signal()
            
            guard let self else {
                return
            }
            
            let deltaTime = buffer.gpuEndTime - buffer.gpuStartTime
            self.frameTimer.calculateGpuTime(deltaTime)
        }

        if targetSize != view.drawableSize {
            makeRenderTargets(size: view.drawableSize)
        }
        
        let deltaTime = frameTimer.beginFrame()
        
        guard let sceneColorMS, let sceneColor, let sceneDepthMS else {
            commandBuffer.commit()
            
            frameTimer.endEncoding()
            frameTimer.report()
            frameIndex = (frameIndex + 1) % RenderSettings.maxFramesInFlight
            return
        }

        scene.update(deltaTime: deltaTime)

        // ---- Shadow pass: depth only, from the light's point of view.
        shadowMap.extent = scene.shadowExtent
        shadowMap.update(light: scene.light, center: scene.shadowCenter)
        if let shadowEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: shadowMap.renderPassDescriptor) {
            shadowEncoder.label = "Shadow"
            shadowEncoder.setDepthStencilState(depthStencilState)
            // Culling front faces pushes the recorded depth to the far side of the
            // occluder, which trades shadow acne for a little peter-panning.
            shadowEncoder.setCullMode(.front)
            shadowEncoder.setDepthBias(0.005, slopeScale: 1.0, clamp: 0.01)
            scene.renderShadow(commandEncoder: shadowEncoder, shadowMap: shadowMap, frameIndex: frameIndex)
            shadowEncoder.endEncoding()
        }

        // ---- Scene pass, into the HDR target instead of the drawable.
        let sceneDescriptor = MTLRenderPassDescriptor()
        sceneDescriptor.colorAttachments[0].texture = sceneColorMS
        sceneDescriptor.colorAttachments[0].resolveTexture = sceneColor
        sceneDescriptor.colorAttachments[0].loadAction = .clear
        sceneDescriptor.colorAttachments[0].storeAction = .multisampleResolve
        sceneDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        sceneDescriptor.depthAttachment.texture = sceneDepthMS
        sceneDescriptor.depthAttachment.loadAction = .clear
        sceneDescriptor.depthAttachment.storeAction = .dontCare
        sceneDescriptor.depthAttachment.clearDepth = 1.0

        if let sceneEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: sceneDescriptor) {
            sceneEncoder.label = "Scene"
            sceneEncoder.setFragmentSamplerState(samplerState, index: 0)
            sceneEncoder.setDepthStencilState(depthStencilState)
            scene.render(commandEncoder: sceneEncoder, shadowMap: shadowMap, skybox: skybox, frameIndex: frameIndex)
            renderSkybox(commandEncoder: sceneEncoder, camera: scene.camera)
            sceneEncoder.endEncoding()
        }

        // ---- Bloom chain, reading the resolved HDR scene.
        let bloomTexture = bloom.encode(commandBuffer: commandBuffer, source: sceneColor)

        let drawableWaitStart = CACurrentMediaTime()
        // ---- Composite to the drawable: scene + bloom, exposure, tone map, vignette.
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            commandBuffer.commit()
            
            frameTimer.endEncoding()
            frameTimer.report()
            frameIndex = (frameIndex + 1) % RenderSettings.maxFramesInFlight
            return
        }
        frameTimer.drawableWaitSeconds = CACurrentMediaTime() - drawableWaitStart

        compositeEncoder.label = "Composite"

        var uniforms = PostUniforms(exposure: exposure,
                                    bloomIntensity: bloom.intensity,
                                    vignette: vignette)

        compositeEncoder.setRenderPipelineState(compositePipelineState)
        compositeEncoder.setCullMode(.none)
        compositeEncoder.setFragmentBytes(&uniforms,
                                          length: MemoryLayout<PostUniforms>.stride, index: 0)
        compositeEncoder.setFragmentTexture(sceneColor, index: 0)
        compositeEncoder.setFragmentTexture(bloomTexture ?? sceneColor, index: 1)
        compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        compositeEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        
        frameTimer.endEncoding()
        frameTimer.report()
        frameIndex = (frameIndex + 1) % RenderSettings.maxFramesInFlight
    }

    private func renderSkybox(commandEncoder: MTLRenderCommandEncoder, camera: Camera) {
        guard let scene = scene else { return }

        var uniforms = SkyboxUniforms()
        uniforms.inverseProjection = camera.projectionMatrix.inverse
        // viewMatrix's 3x3 is R⁻¹; transposing recovers R, which maps view -> world.
        uniforms.viewToWorldRotation = camera.viewMatrix.upperLeft3x3().transpose
        uniforms.exposure = 1.0

        commandEncoder.setRenderPipelineState(skyboxPipelineState)
        commandEncoder.setDepthStencilState(skyboxDepthStencilState)
        commandEncoder.setCullMode(.none)   // Model left .back set; the triangle's winding is arbitrary
        commandEncoder.setFragmentBytes(&uniforms,
                                        length: MemoryLayout<SkyboxUniforms>.stride, index: 0)
        commandEncoder.setFragmentBytes(&scene.sceneConstants,
                                        length: MemoryLayout<SceneConstants>.stride, index: 2)
        commandEncoder.setFragmentTexture(skybox.environmentCube, index: 0)
        commandEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
