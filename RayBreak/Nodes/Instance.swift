//
//  Instance.swift
//  RayBreak
//
//  Created by Nathan Lin on 8/3/26.
//

import MetalKit

class Instance: Node {
    var model: Model
    
    var nodes = [Node]()
    /// Parallel to `nodes` — per-instance material overrides, seeded from the shared model.
    /// Textures still come from `model.material`, since all instances share one mesh and
    /// one set of maps; only the factors vary.
    var materials = [Material]()
    var instanceConstants = [ModelConstants]()
    
    /// TOne buffer per pass  per frame in flight
    private var instanceBuffer: [MTLBuffer?] = Array(repeating: nil, count: RenderSettings.maxFramesInFlight)
    private var shadowInstanceBuffer: [MTLBuffer?] = Array(repeating: nil, count: RenderSettings.maxFramesInFlight)
    
    // Renderable
    var pipelineState: MTLRenderPipelineState!
    var shadowPipelineState: MTLRenderPipelineState!
    var vertexFunctionName: String = "vertex_instance_shader"
    var shadowVertexFunctionName: String = "vertex_depth_instance"
    var fragmentFunctionName: String
    var vertexDescriptor: MTLVertexDescriptor
    var modelConstants = ModelConstants()
    
    init(device: MTLDevice, modelName: String, instances: Int) {
        model = Model(device: device, modelName: modelName)
        vertexDescriptor = model.vertexDescriptor
        fragmentFunctionName = model.fragmentFunctionName
        super.init()
        name = modelName
        create(instances: instances)
        makeBuffer(device: device)
        pipelineState = buildPipelineState(device: device)
        shadowPipelineState = buildShadowPipelineState(device: device)
    }
    
    func create(instances: Int) {
        for i in 0..<instances {
            let node = Node()
            node.name = "Instance \(i)"
            nodes.append(node)
            materials.append(model.material)
            instanceConstants.append(ModelConstants())
        }
    }

    func removeInstance(instance: Int) {
        nodes.remove(at: instance)
        materials.remove(at: instance)
        instanceConstants.remove(at: instance)
    }
    
    func makeBuffer(device: MTLDevice) {
        let length = instanceConstants.count * MemoryLayout<ModelConstants>.stride
        
        for i in 0..<RenderSettings.maxFramesInFlight {
            instanceBuffer[i] = device.makeBuffer(length: length, options: [])
            instanceBuffer[i]?.label = "Instance Buffer \(i)"
            shadowInstanceBuffer[i] = device.makeBuffer(length: length, options: [])
            shadowInstanceBuffer[i]?.label = "Instance Buffer (shadow) \(i)"
        }
    }
}

extension Instance: Renderable {
    func doRender(
        commandEncoder: any MTLRenderCommandEncoder,
        modelViewMatrix: matrix_float4x4,
        modelMatrix: matrix_float4x4,
        pass: RenderPass,
        frameIndex: Int) {
        // Each pass owns its own buffer — see the declaration for why sharing one breaks.
        let buffer = (pass == .shadow) ? shadowInstanceBuffer[frameIndex] : instanceBuffer[frameIndex]
        guard let buffer, nodes.count > 0 else { return }

        var pointer = buffer.contents().bindMemory(to: ModelConstants.self, capacity: nodes.count)
        
        for (index, node) in nodes.enumerated() {
            pointer.pointee.modelViewMatrix = matrix_multiply(modelViewMatrix, node.modelMatrix)

            switch pass
            {
            case .shadow:
                // The caller already set sceneConstants.projectionMatrix to the light's ortho
                // matrix and passed the light's view matrix as the root, so modelViewMatrix
                // above is all the depth pass needs. Pipeline state is set once, after the loop.
                break
            case .main:
                // Parent world matrix first, then the instance's local transform — the same
                // order as modelViewMatrix above. Reversed, instances shadow from the wrong
                // place whenever the Instance itself is transformed.
                pointer.pointee.shadowMatrix =
                matrix_multiply(Model.lightViewProjection,
                                matrix_multiply(modelMatrix, node.modelMatrix)
                )
                pointer.pointee.normalMatrix = pointer.pointee.modelViewMatrix.upperLeft3x3()
                materials[index].apply(to: &pointer.pointee)
            }
            
            pointer = pointer.advanced(by: 1)
        }
        
        switch pass {
        case .shadow:
            // Depth-only pass has no fragment shader, so binding maps there is pointless.
            commandEncoder.setRenderPipelineState(shadowPipelineState)
        case .main:
            model.material.bindTextures(to: commandEncoder)
            commandEncoder.setRenderPipelineState(pipelineState)
        }

        commandEncoder.setVertexBuffer(buffer, offset: 0, index: 1)
        
        guard let meshes = model.meshes,
              meshes.count > 0 else { return }
        
        for mesh in meshes {
            let vertexBuffer = mesh.vertexBuffers[0]
            commandEncoder.setVertexBuffer(vertexBuffer.buffer, offset: vertexBuffer.offset, index: 0)
            for submesh in mesh.submeshes {
                commandEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                     indexCount: submesh.indexCount,
                                                     indexType: submesh.indexType,
                                                     indexBuffer: submesh.indexBuffer.buffer,
                                                     indexBufferOffset: submesh.indexBuffer.offset,
                                                     instanceCount: nodes.count)
            }
        }
    }
}
