//
//  LandscapeScene.swift
//  RayBreak
//
//  Created by Nathan Lin on 8/3/26.
//

import MetalKit

class LandscapeScene: Scene {
    
    var sun: Model
    let ground: Plane
    let grass: Instance
    let mushroom: Model
    
    override init(device: any MTLDevice, size: CGSize) {
        sun = Model(device: device, modelName: "sun")
        ground = Plane(device: device)
        grass = Instance(device: device, modelName: "grass", instances: 10000)
        mushroom = Model(device: device, modelName: "mushroom")
        
        super.init(device: device, size: size)
        setupScene()
    }
    
    override func update(deltaTime: Float) {
        
    }
    
    func setupScene() {
        sun.position.y = 7
        sun.position.x = 6
        sun.scale = SIMD3<Float>(repeating: 2)
        sun.material.albedo = SIMD4<Float>(1, 1, 0, 1)
        
        ground.material.albedo = SIMD4<Float>(0.4, 0.3, 0.1, 1)
        ground.scale = SIMD3<Float>(repeating: 20)
        ground.rotation.x = radians(fromDegrees: 90)
        
        mushroom.position.x = -6
        mushroom.position.z = -8
        mushroom.scale = SIMD3<Float>(repeating: 2)
        
        grass.position.x = -12
        grass.position.z = -12
        
        let greens = [
            SIMD4<Float>(0.34, 0.61, 0.01, 1),
            SIMD4<Float>(0.5, 0.5, 0, 1),
            SIMD4<Float>(0.29, 0.36, 0.14, 1)
        ]
        
        for row in 0..<100 {
            for col in 0..<100 {
                var position = SIMD3<Float>(repeating: 0)
                position.x = Float(row) / 4
                position.z = Float(col) / 4
                
                let index = row * 100 + col
                let blade = grass.nodes[index]
                blade.scale = SIMD3<Float>(repeating: 0.5)
                blade.position = position

                grass.materials[index].albedo = greens[Int(arc4random_uniform(3))]
                blade.rotation.y = radians(fromDegrees: Float(arc4random_uniform(360)))
            }
        }
        
        addChild(sun)
        addChild(ground)
        addChild(grass)
        addChild(mushroom)
        
        camera.rotation.x = radians(fromDegrees: -10)
        camera.position.z = -20
        camera.position.y = -2
        camera.fovDegrees = 25
    }
}
