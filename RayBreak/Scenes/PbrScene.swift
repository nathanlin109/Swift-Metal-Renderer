//
//  PbrScene.swift
//  RayBreak
//
//  Created by Nathan Lin on 8/19/26.
//

import MetalKit

class PbrScene: Scene {

    private enum Lineup {
        static let scale: Float = 0.35
        /// A large radius with a narrow span gives a gentle bow toward the camera — enough
        /// parallax to read as 3D, without the end pieces turning away from the viewer.
        static let arcRadius: Float = 14
        static let arcSpanDegrees: Float = 50
        static let groundTop: Float = -0.1
        /// shaderBall.obj spans y [-0.48, 4.88], so this seats the base on the ground plane.
        static let baseOffset: Float = 0.48 * scale
    }

    /// Metals first, then dielectrics. Grouping reads as deliberate, and it puts the two
    /// varying-metalness materials (rust, chipped paint) next to the pure ones.
    private static let showcase = [
        "Gold", "BrushedSteel", "RustedMetal", "PaintedMetal",
        "Marble", "Leather", "Wood", "PavedStones",
    ]

    var lineup: [Model] = []
    var shaderBallInstances: Instance
    let instanceCount: Int = 8
    let ground: Model
    let marker: Model

    private var elapsed: Float = 0
    private let lightOrbitCenter = SIMD3<Float>(0, 0, 0.7)
    private let lightOrbitRadius: Float = 7.0
    private let lightOrbitHeight: Float = 4.0
    private let lightOrbitSpeed: Float = 0.35     // slower reads better in a recording

    /// Scripted camera move for recording. Space toggles it; any manual input cancels it.
    private var cameraOrbit = CameraOrbit()

    // Look (right half of screen)
    private var lookTouch: UITouch?
    private var lastLookLocation: CGPoint = .zero
    private let lookSensitivity: Float = 0.005

    // Virtual stick (left half of screen)
    private var moveTouch: UITouch?
    private var stickOrigin: CGPoint = .zero
    private let stickRadius: CGFloat = 60
    private var touchMove: SIMD3<Float> = .zero

    // Hardware keyboard
    private var heldKeys: Set<String> = []
    private var spaceHeld = false
    private let movementKeys: Set<String> = ["w", "a", "s", "d", "q", "e"]

    override init(device: any MTLDevice, size: CGSize) {
        // All eight share shaderBall.obj — one mesh load, eight sets of material bindings.
        lineup = PbrScene.showcase.map {
            Model(device: device, modelName: $0, meshName: "shaderBall")
        }
        shaderBallInstances = Instance(device: device, modelName: "shaderBall", instances: instanceCount)
        // PavedStones maps on the cube mesh — the material name picks the textures,
        // the mesh name picks the geometry.
        ground = Model(device: device, modelName: "PavedStones", meshName: "texturedCube")
        marker = Model(device: device, modelName: "sun")

        super.init(device: device, size: size)

        buildInstances()
        buildGround()
        buildLineup()

        light.color = SIMD3<Float>(1, 1, 1)
        light.diffuseIntensity = 0.8
        light.direction = normalize(SIMD3<Float>(-0.4, -1.0, -0.35))

        var pointLight = Light()
        pointLight.type = LightType.point.rawValue
        pointLight.color = SIMD3<Float>(1.0, 0.55, 0.25)   // warm, to read against the sky
        // Inverse-square puts this in a completely different unit from the directional
        // light's 0..1 — and the orbit is wider now, so it needs more than before.
        pointLight.diffuseIntensity = 60
        pointLight.range = 18
        lights.append(pointLight)

        marker.scale = SIMD3<Float>(repeating: 0.15)
        marker.material.albedo = SIMD4<Float>(1.0, 0.55, 0.25, 1)
        marker.material.emissiveStrength = 6
        addChild(marker)

        shadowCenter = SIMD3<Float>(0, 0.8, 0.3)
        shadowExtent = 9      // the lineup is ~13 units wide now

        // Eye height matched to the middle of the balls, so the camera sits level rather
        // than looking down — a lineup reads better from slightly below its midpoint.
        camera.position = SIMD3<Float>(0, 1.3, 9)
    }

    // MARK: - Scene construction

    private func buildGround() {
        ground.position = SIMD3<Float>(0, 0, 0)
        ground.scale = SIMD3<Float>(30, 0.1, 30)

        // The cube's UVs run 0..1 per face, so without tiling one texture would stretch
        // across all 60 world units. 30 repeats puts a paving tile every 2 units — about
        // 1.5x the width of a shaderball, so the ground reads as ground and not as noise.
        ground.material.uvScale = SIMD2<Float>(30, 30)

        // Factors stay neutral — the maps carry everything. Darkened a little so the ground
        // stays subordinate to the lineup.
        ground.material.albedo = SIMD4<Float>(0.55, 0.55, 0.55, 1)
        addChild(ground)
    }

    private func buildLineup() {
        let half = radians(fromDegrees: Lineup.arcSpanDegrees * 0.5)

        for (index, model) in lineup.enumerated() {
            let t = Float(index) / Float(lineup.count - 1)      // 0 -> 1 across the row
            let angle = -half + t * (half * 2)

            model.position = SIMD3<Float>(
                sin(angle) * Lineup.arcRadius,
                Lineup.groundTop + Lineup.baseOffset,
                // 0 at the centre, positive at the ends — the ends come toward the camera.
                Lineup.arcRadius - cos(angle) * Lineup.arcRadius)

            // Turn each ball to face the viewer instead of all facing straight forward.
            model.rotation.y = angle
            model.scale = SIMD3<Float>(repeating: Lineup.scale)

            // Every factor stays 1 — the maps carry albedo, roughness, metalness and AO.
            addChild(model)
        }
    }
    
    private func buildInstances() {
        for i in 0..<instanceCount {
            shaderBallInstances.nodes[i].position = SIMD3<Float>(-5 + 1.5 * Float(i), Lineup.groundTop + Lineup.baseOffset, 15)
            shaderBallInstances.nodes[i].scale = SIMD3<Float>(repeating: Lineup.scale)
        }
        
        addChild(shaderBallInstances)
    }

    // MARK: - Camera

    override func update(deltaTime: Float) {
        elapsed += deltaTime

        lights[1].position = SIMD3<Float>(
            lightOrbitCenter.x + cos(elapsed * lightOrbitSpeed) * lightOrbitRadius,
            lightOrbitCenter.y + lightOrbitHeight,
            lightOrbitCenter.z + sin(elapsed * lightOrbitSpeed) * lightOrbitRadius)

        marker.position = lights[1].position

        let manualMove = touchMove + keyboardMove()

        // Touching the controls takes the camera back, so you never have to remember to
        // press Space before flying somewhere.
        if cameraOrbit.isRunning && length_squared(manualMove) > 1e-6 {
            cameraOrbit.stop()
        }

        if cameraOrbit.isRunning {
            cameraOrbit.update(deltaTime: deltaTime, camera: camera)
        } else {
            camera.moveInput = manualMove
            camera.update(deltaTime: deltaTime)
        }
    }

    private func keyboardMove() -> SIMD3<Float> {
        var move = SIMD3<Float>.zero
        if heldKeys.contains("w") { move.z += 1 }
        if heldKeys.contains("s") { move.z -= 1 }
        if heldKeys.contains("d") { move.x += 1 }
        if heldKeys.contains("a") { move.x -= 1 }
        if heldKeys.contains("e") { move.y += 1 }
        if heldKeys.contains("q") { move.y -= 1 }
        return move
    }

    override func keyDown(_ key: String) -> Bool {
        if key == " " {
            // Guard against a repeat while held — a toggle that fires every frame would
            // just flicker the orbit on and off.
            if !spaceHeld {
                spaceHeld = true
                cameraOrbit.toggle(camera: camera)
            }
            return true
        }
        guard movementKeys.contains(key) else { return false }
        heldKeys.insert(key)
        return true
    }

    override func keyUp(_ key: String) -> Bool {
        if key == " " {
            spaceHeld = false
            return true
        }
        guard movementKeys.contains(key) else { return false }
        heldKeys.remove(key)
        return true
    }

    override func touchesBegan(_ view: UIView, touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let location = touch.location(in: view)

            #if targetEnvironment(macCatalyst)
            // No virtual stick on desktop — a real keyboard handles movement, so the whole
            // window is drag-to-look rather than giving up half of it to a thumbstick.
            if lookTouch == nil {
                lookTouch = touch
                lastLookLocation = location
            }
            #else
            if location.x < view.bounds.midX && moveTouch == nil {
                moveTouch = touch
                stickOrigin = location
            } else if lookTouch == nil {
                lookTouch = touch
                lastLookLocation = location
            }
            #endif
        }
    }

    override func touchesMoved(_ view: UIView, touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let location = touch.location(in: view)

            if touch === lookTouch {
                let delta = CGPoint(x: lastLookLocation.x - location.x,
                                    y: lastLookLocation.y - location.y)
                // Dragging takes the camera back, same as WASD does.
                cameraOrbit.stop()
                camera.rotation.y -= Float(delta.x) * lookSensitivity
                camera.rotation.x -= Float(delta.y) * lookSensitivity
                camera.clampPitch()
                lastLookLocation = location

            } else if touch === moveTouch {
                var stick = SIMD2<Float>(
                    Float((location.x - stickOrigin.x) / stickRadius),
                    Float((stickOrigin.y - location.y) / stickRadius))  // screen Y is down
                let magnitude = length(stick)
                if magnitude > 1 { stick /= magnitude }
                touchMove = SIMD3<Float>(stick.x, 0, stick.y)
            }
        }
    }

    override func touchesEnded(_ view: UIView, touches: Set<UITouch>, with event: UIEvent?) {
        clearTouches(touches)
    }

    override func touchesCancelled(_ view: UIView, touches: Set<UITouch>, with event: UIEvent?) {
        clearTouches(touches)
    }

    private func clearTouches(_ touches: Set<UITouch>) {
        for touch in touches {
            if touch === lookTouch { lookTouch = nil }
            if touch === moveTouch {
                moveTouch = nil
                touchMove = .zero   // otherwise you drift forever
            }
        }
    }

    override func clearKeys() {
        heldKeys.removeAll()
        spaceHeld = false
    }
}
