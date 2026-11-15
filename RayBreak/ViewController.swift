//
//  ViewController.swift
//  RayBreak
//
//  Created by Nathan Lin on 7/12/26.
//

import UIKit
import MetalKit

enum Colors {
    static let wenderlichGreen = MTLClearColor(red: 0.0, green: 0.4, blue: 0.21, alpha: 1.0)
    static let skyBlue = MTLClearColor(red: 0.66, green: 0.9, blue: 0.96, alpha: 1.0)
}

class ViewController: UIViewController {

    var metalView: MTKView {
        return view as! MTKView
    }
    
    var renderer: Renderer!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        metalView.isMultipleTouchEnabled = true
        // The drawable is single-sampled: MSAA now happens in the renderer's offscreen HDR
        // pass and is resolved before post-processing. Leaving this at 4 would give the
        // composite pass a multisampled descriptor its pipeline doesn't match.
        metalView.sampleCount = 1
        
        metalView.device = MTLCreateSystemDefaultDevice()
        
        guard let device = metalView.device, let commandQueue = device.makeCommandQueue() else { return }
        renderer = Renderer(device: device, commandQueue: commandQueue)
        let scene = PbrScene(device: device, size: view.bounds.size)
        scene.sceneNodeDelegate = self
        renderer?.scene = scene
        
        metalView.clearColor = Colors.wenderlichGreen

        metalView.delegate = renderer
        
        // No depth on the drawable either — the composite is a fullscreen triangle, and
        // the scene's depth buffer lives with the offscreen target.
        metalView.depthStencilPixelFormat = .invalid

        metalView.colorPixelFormat = RenderSettings.outputFormat
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.renderer?.scene?.clearKeys()
            }
        
        //SoundController.shared.playBackgroundMusic("bulletstorm_bg_v1.mp3", volume: 0.1)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !becomeFirstResponder() {
            print("keyboard: failed to become first responder")
        }
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        renderer?.scene?.touchesBegan(view, touches: touches, with: event)
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        renderer?.scene?.touchesMoved(view, touches: touches, with: event)
    }
    
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        renderer?.scene?.touchesEnded(view, touches: touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        renderer?.scene?.touchesCancelled(view, touches: touches, with: event)
    }
    
    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        
        var handled = false
        for press in presses {
            print("key down: \(press.key?.charactersIgnoringModifiers ?? "nil")")
            if let key = press.key?.charactersIgnoringModifiers.lowercased(),
               renderer?.scene?.keyDown(key) == true {
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key?.charactersIgnoringModifiers.lowercased(),
               renderer?.scene?.keyUp(key) == true {
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)   // otherwise a key can stick down
    }
}

extension ViewController: SceneNodeDelegate {
    func transition(to scene: Scene) {
        scene.size = view.bounds.size
        scene.sceneNodeDelegate = self
        renderer?.scene = scene
    }
}
