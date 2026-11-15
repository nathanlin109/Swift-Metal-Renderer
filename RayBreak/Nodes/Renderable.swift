//
//  Renderable.swift
//  RayBreak
//
//  Created by Nathan Lin on 7/22/26.
//

import MetalKit

enum RenderPass {
    case shadow
    case main
}

protocol Renderable {
    var pipelineState: MTLRenderPipelineState! { get set }
    var shadowPipelineState: MTLRenderPipelineState! { get set }
    var vertexFunctionName: String { get }
    var fragmentFunctionName: String { get }
    /// Vertex function for the depth-only pass. Instanced types must override this —
    /// the default reads a single ModelConstants and would collapse N shadows into one.
    var shadowVertexFunctionName: String { get }
    var vertexDescriptor: MTLVertexDescriptor { get }
    
    var modelConstants: ModelConstants { get set }
    
    func doRender(commandEncoder: MTLRenderCommandEncoder, modelViewMatrix: matrix_float4x4, modelMatrix: matrix_float4x4, pass: RenderPass, frameIndex: Int)
}

extension Renderable {
    var shadowVertexFunctionName: String { "vertex_depth" }

    func buildPipelineState(device: MTLDevice) -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: vertexFunctionName)
        let fragmentFunction = library?.makeFunction(name: fragmentFunctionName)
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = RenderSettings.hdrFormat
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.rasterSampleCount = RenderSettings.sampleCount
        
        let pipelineState: MTLRenderPipelineState
        
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch let error as NSError {
            fatalError("error: \(error.localizedDescription)")
        }
        
        return pipelineState
    }
    
    func buildShadowPipelineState(device: MTLDevice) -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library?.makeFunction(name: shadowVertexFunctionName)
        descriptor.fragmentFunction = nil                    // depth-only
        descriptor.vertexDescriptor = vertexDescriptor       // each type's own layout
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.colorAttachments[0].pixelFormat = .invalid
        descriptor.rasterSampleCount = 1                     // shadow map is NOT multisampled

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch let error as NSError {
            fatalError("shadow pipeline error: \(error.localizedDescription)")
        }
    }
}
