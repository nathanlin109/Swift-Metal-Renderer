//
//  GameScene.swift
//  RayBreak
//
//  Created by Nathan Lin on 7/19/26.
//

import MetalKit

class GameScene: Scene {
    
    enum Constants {
        static let gameHeight = Float(48)
        static let gameWidth = Float(27)
        static let bricksPerRow = 8
        static let bricksPerColumn = 8
    }
    
    let ball: Model
    let paddle: Model
    
    let bricks: Instance
    
    var previousTouchLocation: CGPoint = .zero
    
    var ballVelocity = SIMD3<Float>(repeating: 0)
    
    override init(device: MTLDevice, size: CGSize) {
        ball = Model(device: device, modelName: "ball")
        paddle = Model(device: device, modelName: "paddle")
        bricks = Instance(device: device, modelName: "brick", instances: Constants.bricksPerRow * Constants.bricksPerColumn)
        
        super.init(device: device, size: size)
        
        camera.position.z = -sceneOffset(height: Constants.gameHeight, fov: camera.fovRadians)
        camera.position.x = -Constants.gameWidth / 2
        camera.position.y = -Constants.gameHeight / 2 + 5
        camera.rotation.x = radians(fromDegrees: 20)
        
        light.color = SIMD3<Float>(repeating: 1)
        light.ambientIntensity = 0.3
        light.diffuseIntensity = 0.8
        light.direction = SIMD3<Float>(0, -1, -1)
        
        setupScene()
    }
    
    func setupScene() {
        ballVelocity.x = 20
        ballVelocity.y = 15
        ball.position.x = Constants.gameWidth / 2
        ball.position.y = Constants.gameHeight * 0.1
        ball.material.albedo = SIMD4<Float>(0.5, 0.9, 0, 1)
        addChild(ball)
        
        paddle.position.x = Constants.gameWidth / 2
        paddle.position.y = Constants.gameHeight * 0.05
        paddle.material.albedo = SIMD4<Float>(1, 0, 0, 1)
        addChild(paddle)
        
        let border = Model(device: device, modelName: "border")
        border.position.x = Constants.gameWidth / 2
        border.position.y = Constants.gameHeight / 2
        border.material.albedo = SIMD4<Float>(0.51, 0.24, 0, 1)
        addChild(border)
        
        let colors = generateColors(number: Constants.bricksPerRow)
        
        let margin = Constants.gameWidth * 0.11
        let startY = Constants.gameHeight * 0.5
        
        for row in 0..<Constants.bricksPerRow {
            for col in 0..<Constants.bricksPerColumn {
                var position = SIMD3<Float>()
                position.x = margin + (margin * Float(row))
                position.y = startY + (margin * Float(col))
                let index = row * Constants.bricksPerColumn + col
                bricks.nodes[index].position = position
                bricks.materials[index].albedo = colors[row]
                bricks.materials[index].metallic = 1
                bricks.materials[index].roughness = 0.2
            }
        }
        
        addChild(bricks)
    }
    
    func endGame(win: Bool) {
        let gameOverScene = GameOverScene(device: device, size: size)
        gameOverScene.win = win
        sceneNodeDelegate?.transition(to: gameOverScene)
    }
    
    override func update(deltaTime: Float) {
        for brick in bricks.nodes {
            brick.rotation.y += Float.pi / 4 * deltaTime
            brick.rotation.z += Float.pi / 4 * deltaTime
        }
        
        var ballBounced = false
        
        ball.position.x += ballVelocity.x * deltaTime
        ball.position.y += ballVelocity.y * deltaTime
        
        if ball.position.y > Constants.gameHeight {
            ball.position.y = Constants.gameHeight
            ballVelocity.y = -ballVelocity.y
            ballBounced = true
        }
        
        if ball.position.x < 0 {
            ball.position.x = 0
            ballVelocity.x = -ballVelocity.x
            ballBounced = true
        }
        
        if ball.position.x > Constants.gameWidth {
            ball.position.x = Constants.gameWidth
            ballVelocity.x = -ballVelocity.x
            ballBounced = true
        }
        
        if ball.position.y < 0 {
            endGame(win: false)
        }
        
        // Collisions
        let ballRect = ball.boundingBox(camera.viewMatrix)
        let paddleRect = paddle.boundingBox(camera.viewMatrix)

        if ballRect.intersects(paddleRect) {
            ballVelocity.y = -ballVelocity.y
            ballBounced = true
        }
        
        for (index, brick) in bricks.nodes.enumerated() {
            let brickRect = brick.boundingBox(camera.viewMatrix)
            
            if ballRect.intersects(brickRect) {
                ballVelocity.y = -ballVelocity.y
                bricks.removeInstance(instance: index)
                break
            }
        }
        
        if ballBounced {
            //SoundController.shared.playPopEffect()
        }
        
        if bricks.nodes.count == 0 {
            endGame(win: true)
        }
    }
    
    func sceneOffset(height: Float, fov: Float) -> Float {
        return (height / 2) / tan(fov / 2)
    }
    
    override func touchesBegan(_ view: UIView, touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        previousTouchLocation = touch.location(in: view);
    }
    
    override func touchesMoved(_ view: UIView, touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let touchLocation = touch.location(in: view);
        let delta = CGPoint(x: touchLocation.x - previousTouchLocation.x, y: touchLocation.y - previousTouchLocation.y)
        
        let deltaX = Float(delta.x) * (Constants.gameWidth / Float(size.width))
        
        let newX = paddle.position.x + deltaX
        paddle.position.x = min(max(newX, paddle.width / 2), Constants.gameWidth - paddle.width / 2)
        
        previousTouchLocation = touchLocation
    }
}
