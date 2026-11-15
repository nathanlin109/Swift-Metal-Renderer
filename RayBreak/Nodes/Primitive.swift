//
//  Primitive.swift
//  RayBreak
//
//  Created by Nathan Lin on 7/19/26.
//

import MetalKit

class Primitive: Node, Renderable, Texturable {
    var vertexBuffer: MTLBuffer?
    var indexBuffer: MTLBuffer?
    
    var pipelineState: MTLRenderPipelineState!
    var shadowPipelineState: MTLRenderPipelineState!
    var vertexFunctionName: String = "vertex_shader"
    var fragmentFunctionName: String = "fragment_color"
    
    var vertexDescriptor: MTLVertexDescriptor {
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        
        vertexDescriptor.attributes[1].format = .float4
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        
        vertexDescriptor.attributes[2].format = .float2
        vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<SIMD4<Float>>.stride
        vertexDescriptor.attributes[2].bufferIndex = 0
        
        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride
        return vertexDescriptor
    }
    
    var vertices: [Vertex] = [
    ]
    
    var indices: [UInt16] = [
    ]
    
    var time: Float = 0.0
    
    var modelConstants = ModelConstants()

    var material = Material()

    // Texturable
    var texture: MTLTexture?
    
    init(device: MTLDevice) {
        super.init()
        buildVertices()
        buildBuffers(device: device)
        pipelineState = buildPipelineState(device: device)
    }
    
    init(device: MTLDevice, imageName: String) {
        super.init()
        buildVertices()
        
        if let texture = setTexture(device: device, imageName: imageName, srgb: true) {
            self.texture = texture;
            fragmentFunctionName = "textured_fragment"
        }
        
        buildBuffers(device: device)
        pipelineState = buildPipelineState(device: device)
    }
    
    func buildVertices() {
        
    }
    
    private func buildBuffers(device: MTLDevice) {
        vertexBuffer = device.makeBuffer(bytes: vertices,
                                         length: vertices.count * MemoryLayout<Vertex>.stride,
                                         options: [])
        indexBuffer = device.makeBuffer(bytes: indices,
                                        length: indices.count *
                                            MemoryLayout<UInt16>.size,
                                        options: [])
    }
    
    func doRender(
        commandEncoder: MTLRenderCommandEncoder,
        modelViewMatrix: matrix_float4x4,
        modelMatrix: matrix_float4x4,
        pass: RenderPass,
        frameIndex: Int) {
        
        if pass == .shadow { return }
            
        guard let indexBuffer = indexBuffer else { return }
        
        modelConstants.modelViewMatrix = modelViewMatrix
        modelConstants.albedo = material.albedo
        
        commandEncoder.setRenderPipelineState(pipelineState)
        
        commandEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        commandEncoder.setVertexBytes(&modelConstants, length: MemoryLayout<ModelConstants>.stride, index: 1)
        
        commandEncoder.setFragmentTexture(texture, index: 0)
        
        commandEncoder.setFrontFacing(.counterClockwise)
        commandEncoder.setCullMode(.back)
        
        commandEncoder.drawIndexedPrimitives(type: .triangle,
                                             indexCount: indices.count,
                                             indexType: MTLIndexType.uint16,
                                             indexBuffer: indexBuffer,
                                             indexBufferOffset: 0)
    }
}
