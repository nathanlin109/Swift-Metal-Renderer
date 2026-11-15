//
//  InstanceScene.swift
//  RayBreak
//
//  Created by Nathan Lin on 8/3/26.
//

import MetalKit

class InstanceScene: Scene {
    
    var humans: Instance
    
    override init(device: any MTLDevice, size: CGSize) {
        humans = Instance(device: device, modelName: "humanFigure", instances: 40)
        
        super.init(device: device, size: size)
        
        addChild(humans)
        
        for (index, human) in humans.nodes.enumerated() {
            human.scale = SIMD3<Float>(repeating: Float(arc4random_uniform(5)) / 10)
            human.position.x = Float(arc4random_uniform(5)) - 2
            human.position.y = Float(arc4random_uniform(5)) - 3
            humans.materials[index].albedo =
                SIMD4<Float>(Float(drand48()), Float(drand48()), Float(drand48()), 1)
        }
    }
    
    override func update(deltaTime: Float) {
        
    }
}
