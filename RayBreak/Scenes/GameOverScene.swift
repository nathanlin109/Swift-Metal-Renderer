//
//  GameOverScene.swift
//  RayBreak
//
//  Created by Nathan Lin on 8/9/26.
//

import MetalKit

class GameOverScene: Scene {
    
    var gameOverModel: Model!
    var registerTouch = false
    var time: Float = 0
    
    var win: Bool = false {
        didSet {
            if win {
                gameOverModel = Model(device: device, modelName: "youwin")
                gameOverModel.material.albedo = SIMD4<Float>(0, 1, 0, 1)
            } else {
                gameOverModel = Model(device: device, modelName: "youlose")
                gameOverModel.material.albedo = SIMD4<Float>(1, 0, 0, 1)
            }
            
            addChild(gameOverModel)
        }
    }
    
    override init(device: any MTLDevice, size: CGSize) {
        super.init(device: device, size: size)
        
        light.color = SIMD3<Float>(1, 1, 1)
        light.ambientIntensity = 0.3
        light.diffuseIntensity = 0.8
        light.direction = SIMD3<Float>(0, -1, -1)
        
        camera.position.z = -30
    }
    
    override func update(deltaTime: Float) {
        time += deltaTime
        
        let amplitude: Float = 0.5
        let period: Float = 2
        let periodicAmount = sin(Float(time + 0.8) * period) * amplitude * deltaTime
        
        gameOverModel.rotation.x -= π * periodicAmount // π is Option+P
        gameOverModel.scale += SIMD3<Float>(repeating: periodicAmount/4)
    }
    
    override func touchesBegan(_ view: UIView, touches: Set<UITouch>,with event: UIEvent?) {
        registerTouch = true
    }
    override func touchesEnded(_ view: UIView, touches: Set<UITouch>,with event: UIEvent?) {
    if registerTouch {
        let scene = GameScene(device: device, size: size)
            sceneNodeDelegate?.transition(to: scene)
        }
    }
}
