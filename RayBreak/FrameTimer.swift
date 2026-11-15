//
//  FrameTimer.swift
//  RayBreak
//
//  Created by Nathan Lin on 9/11/26.
//

import QuartzCore
import OSLog

final class FrameTimer {
    // Config
    private let smoothing: Double = 0.1
    private let maxDeltaTime: Double = 0.1
    private let reportInterval: Double = 1.0
    private let firstFrameTime: Double = 0.016
    private let lock = NSLock()
    private let logger = Logger()
    
    // Main thread
    private var lastFrameStart: CFTimeInterval?
    private var encodeStart: CFTimeInterval = 0.0
    private var lastReport: CFTimeInterval = 0.0
    
    // Smoothed results
    private(set) var cpuFrameTimeSec: Double = 0.0
    private(set) var encodeTimeSec: Double = 0.0
    var drawableWaitSeconds: Double = 0.0
    private(set) var gpuTimeSec: Double = 0.0
    private(set) var maxCpuFrameTimeSec: Double = 0.0
    private(set) var maxEncodeTimeSec: Double = 0.0
    private(set) var maxGpuTimeSec: Double = 0.0
    
    init()
    {
    }
    
    func beginFrame() -> Float {
        let currentTime = CACurrentMediaTime()
        
        if lastFrameStart == nil {
            lastFrameStart = currentTime
            encodeStart = currentTime
            return Float(firstFrameTime)
        }
        
        let deltaTime = currentTime - lastFrameStart!
        
        cpuFrameTimeSec = (cpuFrameTimeSec == 0) ? deltaTime : calculateEma(avg: cpuFrameTimeSec, deltaTime)
        maxCpuFrameTimeSec = max(maxCpuFrameTimeSec, deltaTime)
        
        lastFrameStart = currentTime
        encodeStart = currentTime
        return min(Float(deltaTime), Float(maxDeltaTime))
    }
    
    func endEncoding() {
        let deltaTime = (CACurrentMediaTime() - encodeStart) - drawableWaitSeconds
        encodeTimeSec = (encodeTimeSec == 0) ? deltaTime : calculateEma(avg: encodeTimeSec, deltaTime)
        maxEncodeTimeSec = max(maxEncodeTimeSec, deltaTime)
    }
    
    func calculateGpuTime(_ deltaTime: Double) {
        lock.lock()
        defer { lock.unlock() }
        gpuTimeSec = (gpuTimeSec == 0) ? deltaTime : calculateEma(avg: gpuTimeSec, deltaTime)
        maxGpuTimeSec = max(maxGpuTimeSec, deltaTime)
    }
    
    func calculateEma(avg: Double, _ deltaTime: Double) -> Double {
        return avg * (1 - smoothing) + deltaTime * smoothing
    }
    
    func report() {
        if CACurrentMediaTime() - lastReport < reportInterval {
            return
        }
        lastReport = CACurrentMediaTime()
        
        logger.notice("cpuFrameTimeSec: \(self.cpuFrameTimeSec * 1000, format: .fixed(precision: 2), privacy: .public)")
        logger.notice("maxCpuFrameTimeSec: \(self.maxCpuFrameTimeSec * 1000, format: .fixed(precision: 2), privacy: .public)")
        logger.notice("encodeTimeSec: \(self.encodeTimeSec * 1000, format: .fixed(precision: 2), privacy: .public)")
        logger.notice("maxEncodeTimeSec: \(self.maxEncodeTimeSec * 1000, format: .fixed(precision: 2), privacy: .public)")
        
        lock.lock()
        let gpuTimePrint = gpuTimeSec * 1000
        let maxGpuTimePrint = maxGpuTimeSec * 1000
        logger.notice("gpuTimeSec: \(gpuTimePrint, format: .fixed(precision: 2), privacy: .public)")
        logger.notice("maxGpuTimeSec: \(maxGpuTimePrint, format: .fixed(precision: 2), privacy: .public)")
        maxGpuTimeSec = 0
        lock.unlock()
        
        maxCpuFrameTimeSec = 0
        maxEncodeTimeSec = 0
    }
}
