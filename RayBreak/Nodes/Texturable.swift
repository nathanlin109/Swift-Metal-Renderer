//
//  Texturable.swift
//  RayBreak
//
//  Created by Nathan Lin on 7/27/26.
//

import MetalKit

protocol Texturable {
    var texture: MTLTexture? {get set}
}

extension Texturable {
    func setTexture(device: MTLDevice, imageName: String, srgb: Bool) -> MTLTexture? {
        let textureLoader = MTKTextureLoader(device: device)
        
        var texture: MTLTexture? = nil
        
        let textureLoaderOptions: [MTKTextureLoader.Option: Any]
        textureLoaderOptions = [
            .origin : MTKTextureLoader.Origin.bottomLeft,
            .SRGB: srgb,
            .generateMipmaps: true
        ]
        
        if let textureURL = Bundle.main.url(forResource: imageName, withExtension: nil) {
            do {
                texture = try textureLoader.newTexture(URL: textureURL, options: textureLoaderOptions)
            } catch {
                print("texture not created")
            }
        }

        return texture
    }
}
