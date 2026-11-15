//
//  Bloom.swift
//  RayBreak
//

import MetalKit

/// Progressive downsample / upsample bloom.
///
/// Bright pixels are extracted at half resolution, then repeatedly halved. On the way back
/// up each level is blended additively onto the next finer one, so the final result is the
/// sum of blurs at many radii. That is what gives a natural falloff — a single Gaussian at
/// one radius reads as a uniform halo instead.
final class Bloom {

    /// Five levels from half-res: at 2560 wide that bottoms out around 80px, which is a
    /// wide enough blur to feel like light spilling rather than an outline.
    static let levels = 5

    /// Luminance above which a pixel starts to bloom. The scene is HDR, so 1.0 means
    /// "brighter than white" — reflections and the emissive marker, not lit surfaces.
    var threshold: Float = 1.0
    /// Width of the soft ramp into the threshold.
    var knee: Float = 0.5
    /// How much bloom is added back at composite.
    var intensity: Float = 0.15
    /// Ceiling on any single pixel's contribution to the blur. A near-mirror metal can
    /// reflect the environment's sun into a sub-pixel spot worth thousands; unbounded,
    /// that one sample spreads across ~100 pixels and pulses as the camera moves.
    var maxBrightness: Float = 12

    private(set) var chain: [MTLTexture] = []

    private var brightPipeline: MTLRenderPipelineState!
    private var downPipeline: MTLRenderPipelineState!
    private var upPipeline: MTLRenderPipelineState!

    init(device: MTLDevice) {
        let library = device.makeDefaultLibrary()!
        let vertexFunction = library.makeFunction(name: "vertex_fullscreen")!

        func pipeline(_ fragmentName: String, blending: Bool) -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = library.makeFunction(name: fragmentName)
            descriptor.colorAttachments[0].pixelFormat = RenderSettings.hdrFormat
            descriptor.rasterSampleCount = 1        // post runs on resolved, single-sample data

            if blending {
                // Additive: the upsample accumulates onto the coarser level already there.
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].rgbBlendOperation = .add
                descriptor.colorAttachments[0].alphaBlendOperation = .add
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
            }

            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch let error as NSError {
                fatalError("bloom pipeline \(fragmentName): \(error.localizedDescription)")
            }
        }

        brightPipeline = pipeline("fragment_bloom_bright", blending: false)
        downPipeline   = pipeline("fragment_bloom_down",   blending: false)
        upPipeline     = pipeline("fragment_bloom_up",     blending: true)
    }

    // MARK: - Targets

    func resize(device: MTLDevice, width: Int, height: Int) {
        chain.removeAll()
        guard width > 0, height > 0 else { return }

        var w = max(width / 2, 1)
        var h = max(height / 2, 1)

        for level in 0..<Bloom.levels {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: RenderSettings.hdrFormat,
                width: w, height: h, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private

            guard let texture = device.makeTexture(descriptor: descriptor) else {
                fatalError("could not create bloom target \(level)")
            }
            texture.label = "Bloom \(w)x\(h)"
            chain.append(texture)

            w = max(w / 2, 1)
            h = max(h / 2, 1)
        }
    }

    // MARK: - Encoding

    /// Runs the whole chain and returns the finest level, ready to composite.
    @discardableResult
    func encode(commandBuffer: MTLCommandBuffer, source: MTLTexture) -> MTLTexture? {
        guard chain.count == Bloom.levels else { return nil }

        // Bright pass: full-res scene -> half-res chain[0].
        drawPass(commandBuffer: commandBuffer,
                 pipeline: brightPipeline,
                 source: source,
                 destination: chain[0],
                 loadAction: .clear,
                 label: "Bloom bright")

        // Down: each level halves the one before it.
        for level in 0..<(Bloom.levels - 1) {
            drawPass(commandBuffer: commandBuffer,
                     pipeline: downPipeline,
                     source: chain[level],
                     destination: chain[level + 1],
                     loadAction: .clear,
                     label: "Bloom down \(level + 1)")
        }

        // Up: additively blended back down the chain, so .load rather than .clear —
        // clearing here would throw away everything the downsample just built.
        for level in stride(from: Bloom.levels - 2, through: 0, by: -1) {
            drawPass(commandBuffer: commandBuffer,
                     pipeline: upPipeline,
                     source: chain[level + 1],
                     destination: chain[level],
                     loadAction: .load,
                     label: "Bloom up \(level)")
        }

        return chain[0]
    }

    private func drawPass(commandBuffer: MTLCommandBuffer,
                          pipeline: MTLRenderPipelineState,
                          source: MTLTexture,
                          destination: MTLTexture,
                          loadAction: MTLLoadAction,
                          label: String) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = loadAction
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.label = label

        // texelSize is the SOURCE's, because the taps are offsets into what we're reading.
        var uniforms = BloomUniforms(
            texelSize: SIMD2<Float>(1.0 / Float(source.width), 1.0 / Float(source.height)),
            threshold: threshold,
            knee: knee,
            maxBrightness: maxBrightness)

        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BloomUniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
