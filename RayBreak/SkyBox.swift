//
//  SkyBox.swift
//  RayBreak
//
//  Created by Nathan Lin on 8/26/26.
//

import MetalKit

class SkyBox {
    /// Resolution of one cube face. 1024 is ample for a 4K equirect source.
    static let cubeSize = 1024
    
    /// 32 per face is plenty — irradiance is by definition extremely low frequency.
    static let irradianceSize = 32

    let environmentCube: MTLTexture
    let irradianceCube: MTLTexture
    
    static var prefilteredSize: Int { RenderSettings.prefilteredSize }
    static var prefilteredMipCount: Int { RenderSettings.prefilteredMipCount }
    static let brdfLUTSize = 256

    let prefilteredCube: MTLTexture
    let brdfLUT: MTLTexture

    init(device: MTLDevice, commandQueue: MTLCommandQueue, name: String) {
        guard let equirect = SkyBox.loadHDR(device: device, name: name) else {
            fatalError("environment map \(name).exr could not be loaded")
        }

        environmentCube = SkyBox.makeCubeTexture(device: device, size: SkyBox.cubeSize)

        SkyBox.convert(device: device, commandQueue: commandQueue,
                       equirect: equirect, cube: environmentCube)
        // equirect goes out of scope here — the cubemap is the only copy we keep.
        
        irradianceCube = SkyBox.makeCubeTexture(device: device,
                                                size: SkyBox.irradianceSize,
                                                mipmapped: false)
        irradianceCube.label = "Irradiance Cube"

        SkyBox.convolveIrradiance(device: device, commandQueue: commandQueue,
                                  environment: environmentCube, irradiance: irradianceCube)
        
        prefilteredCube = SkyBox.makePrefilteredCube(device: device)
        SkyBox.prefilter(device: device, commandQueue: commandQueue,
                         environment: environmentCube, prefiltered: prefilteredCube)

        brdfLUT = SkyBox.makeBRDFLUT(device: device)
        SkyBox.integrateBRDF(device: device, commandQueue: commandQueue, lut: brdfLUT)
    }

    // MARK: - Source

    static func loadHDR(device: MTLDevice, name: String) -> MTLTexture? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "exr") else {
            print("HDR not found in bundle: \(name).exr")
            return nil
        }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,        // HDR data is already linear — never sRGB-decode it
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue
        ]
        do {
            let texture = try loader.newTexture(URL: url, options: options)
            texture.label = "Equirect HDR"
            print("HDR loaded: \(texture.width)x\(texture.height) format=\(texture.pixelFormat.rawValue)")
            return texture
        } catch {
            print("HDR load failed: \(error)")
            return nil
        }
    }

    // MARK: - Destination

    private static func makeCubeTexture(device: MTLDevice, size: Int, mipmapped: Bool = true) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: .rgba16Float,   // HDR needs values > 1.0; rgba8 would clamp them
            size: size,
            mipmapped: mipmapped)
        descriptor.usage = [.shaderRead, .shaderWrite]   // shaderWrite: a kernel fills it
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("could not create environment cubemap")
        }
        texture.label = "Environment Cube"
        return texture
    }
    
    private static func makePrefilteredCube(device: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: .rgba16Float, size: prefilteredSize, mipmapped: true)
        descriptor.mipmapLevelCount = prefilteredMipCount
        // pixelFormatView so we can make a per-mip view to write into.
        descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("could not create prefiltered cubemap")
        }
        texture.label = "Prefiltered Cube"
        return texture
    }
    
    private static func makeBRDFLUT(device: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float,       // only two channels needed: scale and bias
            width: brdfLUTSize, height: brdfLUTSize, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("could not create BRDF LUT")
        }
        texture.label = "BRDF LUT"
        return texture
    }

    // MARK: - Conversion

    private static func convert(device: MTLDevice, commandQueue: MTLCommandQueue,
                                equirect: MTLTexture, cube: MTLTexture) {
        let library = device.makeDefaultLibrary()!
        let function = library.makeFunction(name: "equirect_to_cube")!
        let pipeline = try! device.makeComputePipelineState(function: function)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(equirect, index: 0)
        encoder.setTexture(cube, index: 1)

        // One thread per texel per face; z indexes the six faces.
        let size = cube.width
        let threadgroup = MTLSize(width: 8, height: 8, depth: 1)
        let threadgroups = MTLSize(width: (size + 7) / 8,
                                   height: (size + 7) / 8,
                                   depth: 6)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroup)
        encoder.endEncoding()

        // Mips feed the prefilter step later, and the skybox at grazing angles.
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: cube)
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()   // load-time only; blocking here is fine
    }
    
    private static func convolveIrradiance(device: MTLDevice, commandQueue: MTLCommandQueue,
                                           environment: MTLTexture, irradiance: MTLTexture) {
        let library = device.makeDefaultLibrary()!
        let function = library.makeFunction(name: "irradiance_convolve")!
        let pipeline = try! device.makeComputePipelineState(function: function)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(environment, index: 0)
        encoder.setTexture(irradiance, index: 1)

        let size = irradiance.width
        let threadgroup = MTLSize(width: 8, height: 8, depth: 1)
        let threadgroups = MTLSize(width: (size + 7) / 8, height: (size + 7) / 8, depth: 6)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    
    private static func prefilter(device: MTLDevice, commandQueue: MTLCommandQueue,
                                  environment: MTLTexture, prefiltered: MTLTexture) {
        let library = device.makeDefaultLibrary()!
        let function = library.makeFunction(name: "prefilter_environment")!
        let pipeline = try! device.makeComputePipelineState(function: function)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let mipCount = prefiltered.mipmapLevelCount
        for mip in 0..<mipCount {
            // A compute kernel writes to mip 0 of whatever texture it's given, so bind a
            // view onto the single mip we want rather than the whole chain.
            guard let view = prefiltered.makeTextureView(
                    pixelFormat: prefiltered.pixelFormat,
                    textureType: .typeCube,
                    levels: mip..<(mip + 1),
                    slices: 0..<6) else {
                fatalError("prefilter: could not create texture view for mip \(mip)")
            }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                fatalError("prefilter: could not create compute encoder")
            }

            let size = max(prefiltered.width >> mip, 1)
            // Never exactly 0: at roughness 0 every GGX sample collapses to H = N, so
            // NdotH is exactly 1 and the distribution term divides 0 by 0. Metal compiles
            // with fast math by default, where NaN behaviour is undefined — so the ternary
            // guard in the kernel isn't reliable protection.
            let t = Float(mip) / Float(mipCount - 1)
            var uniforms = PrefilterUniforms(roughness: max(t, 0.04), size: UInt32(size))

            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(environment, index: 0)
            encoder.setTexture(view, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<PrefilterUniforms>.stride, index: 0)

            let threadgroup = MTLSize(width: 8, height: 8, depth: 1)
            let threadgroups = MTLSize(width: (size + 7) / 8, height: (size + 7) / 8, depth: 6)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroup)
            encoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    
    private static func integrateBRDF(device: MTLDevice, commandQueue: MTLCommandQueue,
                                      lut: MTLTexture) {
        let library = device.makeDefaultLibrary()!
        let function = library.makeFunction(name: "integrate_brdf")!
        let pipeline = try! device.makeComputePipelineState(function: function)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(lut, index: 0)

        let size = lut.width
        let threadgroup = MTLSize(width: 8, height: 8, depth: 1)
        let threadgroups = MTLSize(width: (size + 7) / 8, height: (size + 7) / 8, depth: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}
