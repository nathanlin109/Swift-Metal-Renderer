//
//  CrowdScene.swift
//  RayBreak
//
//  Created by Nathan Lin on 8/3/26.
//

import MetalKit

class CrowdScene: Scene {
    
    var humans = [Model]()
    
    override init(device: any MTLDevice, size: CGSize) {
        super.init(device: device, size: size)
        
        for _ in 0..<40 {
            let human = Model(device: device, modelName: "humanFigure")
            humans.append(human)
            addChild(human)
            human.scale = SIMD3<Float>(repeating: Float(arc4random_uniform(5)) / 10)
            human.position.x = Float(arc4random_uniform(5)) - 2
            human.position.y = Float(arc4random_uniform(5)) - 3
            human.material.albedo = SIMD4<Float>(Float(drand48()), Float(drand48()), Float(drand48()), 1)
        }
    }
    
    override func update(deltaTime: Float) {
        
    }
}
