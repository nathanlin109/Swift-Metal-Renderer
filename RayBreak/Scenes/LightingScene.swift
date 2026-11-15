//
//  LightingScene.swift
//  RayBreak
//
//  Created by Nathan Lin on 8/3/26.
//

import MetalKit

class LightingScene: Scene {
    
    let mushroom: Model
    var previousTouchLocation: CGPoint = .zero
    
    override init(device: any MTLDevice, size: CGSize) {
        mushroom = Model(device: device, modelName: "mushroom")
        super.init(device: device, size: size)
        mushroom.position.y = -1
        mushroom.material.metallic = 0
        mushroom.material.roughness = 0.4
        addChild(mushroom)
        
        light.color = SIMD3<Float>(1, 1, 1)
        light.ambientIntensity = 0.2
        light.diffuseIntensity = 0.8
        light.direction = SIMD3<Float>(0, 0, -1)
    }
    
    override func update(deltaTime: Float) {
        
    }
    
    override func touchesBegan(_ view: UIView, touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        previousTouchLocation = touch.location(in: view)
    }
    
    override func touchesMoved(_ view: UIView, touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let touchLocation = touch.location(in: view)
        let delta = CGPoint(x: previousTouchLocation.x - touchLocation.x,
        y: previousTouchLocation.y - touchLocation.y)
        
        let sensitivity: Float = 0.01
        mushroom.rotation.x += Float(delta.y) * sensitivity
        mushroom.rotation.y += Float(delta.x) * sensitivity
        
        previousTouchLocation = touchLocation
    }
}
