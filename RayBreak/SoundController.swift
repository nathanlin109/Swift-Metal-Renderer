//
//  SoundController.swift
//  RayBreak
//
//  Created by Nathan Lin on 8/5/26.
//

import AVFoundation

class SoundController {
    static let shared = SoundController()
    
    var backgroundMusicPlayer: AVAudioPlayer?
    var popEffect: AVAudioPlayer?
    
    private init() {
        popEffect = preloadSoundEffect("pop.wav")
    }
    
    func preloadSoundEffect(_ filename: String) -> AVAudioPlayer? {
        if let url = Bundle.main.url(forResource: filename, withExtension: nil) {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                return player
            } catch {
                print("file \(filename) not found")
            }
        }
        
        return nil
    }
    
    func playBackgroundMusic(_ filename: String, volume: Float) {
        backgroundMusicPlayer = preloadSoundEffect(filename)
        backgroundMusicPlayer?.numberOfLoops = -1
        backgroundMusicPlayer?.volume = volume
        backgroundMusicPlayer?.play()
    }
    
    func playPopEffect() {
        popEffect?.play()
    }
}
