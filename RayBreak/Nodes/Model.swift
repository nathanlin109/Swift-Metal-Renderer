//
//  Model.swift
//  RayBreak
//
//  Created by Nathan Lin on 8/2/26.
//

import MetalKit

class Model: Node {
    
    var meshes: [MTKMesh]?
    
    /// Factors and maps together. Will become `[Material]` indexed by submesh when a model
    /// needs more than one — the draw loop below is already the right seam for that.
    var material = Material()

    /// Texturable's storage requirement. The maps a Model actually renders with live on
    /// `material`; this stays only to satisfy the protocol that provides `setTexture`.
    var texture: MTLTexture?

    // Renderable
    var pipelineState: MTLRenderPipelineState!
    var shadowPipelineState: MTLRenderPipelineState!
    var vertexFunctionName: String = "vertex_shader"
    var fragmentFunctionName: String = "pbr_textured_fragment"
    var modelConstants = ModelConstants()
    
    static var lightViewProjection: matrix_float4x4 = matrix_identity_float4x4
    
    var vertexDescriptor: MTLVertexDescriptor {
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        
        vertexDescriptor.attributes[1].format = .float4
        vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.stride * 3
        vertexDescriptor.attributes[1].bufferIndex = 0
        
        vertexDescriptor.attributes[2].format = .float2
        vertexDescriptor.attributes[2].offset = MemoryLayout<Float>.stride * 7
        vertexDescriptor.attributes[2].bufferIndex = 0
        
        vertexDescriptor.attributes[3].format = .float3
        vertexDescriptor.attributes[3].offset = MemoryLayout<Float>.stride * 9
        vertexDescriptor.attributes[3].bufferIndex = 0
        
        vertexDescriptor.attributes[4].format = .float3
        vertexDescriptor.attributes[4].offset = MemoryLayout<Float>.stride * 12
        vertexDescriptor.attributes[4].bufferIndex = 0
        
        vertexDescriptor.attributes[5].format = .float3
        vertexDescriptor.attributes[5].offset = MemoryLayout<Float>.stride * 15
        vertexDescriptor.attributes[5].bufferIndex = 0
        
        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.stride * 18
        return vertexDescriptor
    }
    
    /// Meshes are immutable once loaded, so several materials can share one. Without this,
    /// eight Models of a 33k-vert shaderball would mean eight loads and eight tangent-basis
    /// generations at launch.
    private static var meshCache: [String: (meshes: [MTKMesh], width: Float, height: Float)] = [:]

    /// - Parameter meshName: which .obj to load. Defaults to `modelName`; pass it explicitly
    ///   when several materials render onto the same geometry.
    init(device: MTLDevice, modelName: String, meshName: String? = nil) {
        super.init()

        name = modelName
        loadModel(device: device, meshName: meshName ?? modelName)

        // Colour art is sRGB; ORM and normal maps are data and must stay linear.
        material.albedoTexture = setTexture(device: device, imageName: modelName + ".png", srgb: true)
        material.ormTexture    = setTexture(device: device, imageName: modelName + "_orm.png", srgb: false)
        material.normalTexture = setTexture(device: device, imageName: modelName + "_normal.png", srgb: false)

        pipelineState = buildPipelineState(device: device)
        shadowPipelineState = buildShadowPipelineState(device: device)
    }
    
    func loadModel(device: MTLDevice, meshName: String) {
        if let cached = Model.meshCache[meshName] {
            meshes = cached.meshes
            width = cached.width
            height = cached.height
            return
        }

        guard let assetURL = Bundle.main.url(forResource: meshName, withExtension: "obj")
        else {
            fatalError("Asset \(meshName) does not exist.")
        }
        
        let descriptor = MTKModelIOVertexDescriptorFromMetal(vertexDescriptor)
        
        let attributePosition = descriptor.attributes[0] as! MDLVertexAttribute
        attributePosition.name = MDLVertexAttributePosition
        descriptor.attributes[0] = attributePosition
        
        let attributeColor = descriptor.attributes[1] as! MDLVertexAttribute
        attributeColor.name = MDLVertexAttributeColor
        descriptor.attributes[1] = attributeColor
        
        let attributeTextureCoordinates = descriptor.attributes[2] as! MDLVertexAttribute
        attributeTextureCoordinates.name = MDLVertexAttributeTextureCoordinate
        descriptor.attributes[2] = attributeTextureCoordinates
        
        let attributeNormals = descriptor.attributes[3] as! MDLVertexAttribute
        attributeNormals.name = MDLVertexAttributeNormal
        descriptor.attributes[3] = attributeNormals
        
        let attributeTangent = descriptor.attributes[4] as! MDLVertexAttribute
        attributeTangent.name = MDLVertexAttributeTangent
        descriptor.attributes[4] = attributeTangent

        let attributeBitangent = descriptor.attributes[5] as! MDLVertexAttribute
        attributeBitangent.name = MDLVertexAttributeBitangent
        descriptor.attributes[5] = attributeBitangent
        
        let bufferAllocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(url: assetURL,
                             vertexDescriptor: descriptor,
                             bufferAllocator: bufferAllocator)
        
        let boundingBox = asset.boundingBox;
        width = boundingBox.maxBounds.x - boundingBox.minBounds.x
        height = boundingBox.maxBounds.y - boundingBox.minBounds.y
        
        if let mdlMeshes = asset.childObjects(of: MDLMesh.self) as? [MDLMesh] {
            for mdlMesh in mdlMeshes {
                mdlMesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal,
                                   creaseThreshold: 0.5)
                mdlMesh.addTangentBasis(
                    forTextureCoordinateAttributeNamed: MDLVertexAttributeTextureCoordinate,
                    tangentAttributeNamed: MDLVertexAttributeTangent,
                    bitangentAttributeNamed: MDLVertexAttributeBitangent)

                // Re-assert the layout AFTER generating. Model I/O appends generated
                // attributes in its own layout — often a second buffer — so without this
                // the tangents are not at the offsets you declared and lighting is garbage.
                mdlMesh.vertexDescriptor = descriptor
            }
        }
        
        do {
            let loadedMeshes = try MTKMesh.newMeshes(asset: asset, device: device)
            meshes = loadedMeshes.metalKitMeshes
        } catch {
            print ("mesh error")
        }

        Model.meshCache[meshName] = (meshes ?? [], width, height)
    }
}

extension Model: Renderable {
    func doRender(
        commandEncoder: MTLRenderCommandEncoder,
        modelViewMatrix: matrix_float4x4,
        modelMatrix: matrix_float4x4,
        pass: RenderPass,
        frameIndex: Int) {
            
        modelConstants.modelViewMatrix = modelViewMatrix
            
        switch pass {
        case .shadow:
            // The caller has already set sceneConstants.projectionMatrix tothe light's
            // ortho matrix and passed the light's view matrix as the root,so the existing
            // projection * modelView * position math produces light clipspace unchanged.
            commandEncoder.setRenderPipelineState(shadowPipelineState)
        case .main:
            modelConstants.shadowMatrix = matrix_multiply(Model.lightViewProjection, modelMatrix)
            modelConstants.normalMatrix = modelViewMatrix.upperLeft3x3()
            material.apply(to: &modelConstants)
            material.bindTextures(to: commandEncoder)
            commandEncoder.setRenderPipelineState(pipelineState)
            commandEncoder.setFrontFacing(.counterClockwise)
            commandEncoder.setCullMode(.back)
        }
            
        commandEncoder.setVertexBytes(&modelConstants, length: MemoryLayout<ModelConstants>.stride, index: 1)
        
        guard let meshes = meshes, meshes.count > 0 else { return }
        
        for mesh in meshes {
            let vertexBuffer = mesh.vertexBuffers[0]
            commandEncoder.setVertexBuffer(vertexBuffer.buffer, offset: vertexBuffer.offset, index: 0)
            
            for submesh in mesh.submeshes {
                commandEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                     indexCount: submesh.indexCount,
                                                     indexType: submesh.indexType,
                                                     indexBuffer: submesh.indexBuffer.buffer,
                                                     indexBufferOffset: submesh.indexBuffer.offset)
            }
        }
    }
}

extension Model: Texturable {
    
}
