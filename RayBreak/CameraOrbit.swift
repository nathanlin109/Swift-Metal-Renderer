//
//  CameraOrbit.swift
//  RayBreak
//

import simd

/// A scripted camera move for recording, rather than a control scheme.
///
/// Azimuth and height are driven by sines at deliberately unrelated rates, so the path
/// never visibly repeats and never snaps at a turnaround — a sine decelerates into its
/// own extremes for free, which a looping linear sweep does not.
///
/// It sweeps an arc rather than orbiting a full circle: the lineup is composed to be seen
/// from the front, and the far side of a 360 is eight shaderballs seen from behind.
struct CameraOrbit {

    /// What the camera looks at, and orbits.
    var target = SIMD3<Float>(0, 1.0, 0.4)

    var radius: Float = 10.5
    /// Half-width of the arc. 55 degrees each way keeps every ball in frame at the extremes.
    var azimuthDegrees: Float = 55
    /// Seconds for one out-and-back sweep.
    var azimuthPeriod: Float = 30

    var baseHeight: Float = 2.1
    var heightAmplitude: Float = 1.1
    /// Deliberately not a whole-number ratio of azimuthPeriod, so the two never re-sync.
    var heightPeriod: Float = 29

    /// Seconds to ease in from wherever the free camera was left.
    var blendDuration: Float = 1.5

    private(set) var isRunning = false
    private var elapsed: Float = 0
    private var blend: Float = 0
    private var fromPosition = SIMD3<Float>.zero
    private var fromRotation = SIMD3<Float>.zero

    // MARK: - Control

    mutating func start(from camera: Camera) {
        // Restart from t = 0 so a recording always begins at the same point in the sweep.
        elapsed = 0
        blend = 0
        fromPosition = camera.position
        fromRotation = camera.rotation
        isRunning = true
    }

    mutating func stop() {
        isRunning = false
    }

    mutating func toggle(camera: Camera) {
        if isRunning { stop() } else { start(from: camera) }
    }

    // MARK: - Driving

    mutating func update(deltaTime: Float, camera: Camera) {
        guard isRunning else { return }

        elapsed += deltaTime
        blend = min(blend + deltaTime / max(blendDuration, 1e-4), 1)

        let azimuth = sin(elapsed * 2 * .pi / azimuthPeriod)
                    * radians(fromDegrees: azimuthDegrees)
        let height = baseHeight
                   + sin(elapsed * 2 * .pi / heightPeriod) * heightAmplitude

        let targetPosition = SIMD3<Float>(
            target.x + sin(azimuth) * radius,
            height,
            target.z + cos(azimuth) * radius)

        // Solve the orbit pose first, then blend toward it, so the ease-in converges on a
        // pose that is already correct rather than chasing a moving one.
        camera.position = targetPosition
        camera.look(at: target)
        let orbitRotation = camera.rotation

        if blend >= 1 {
            return
        }

        // Smoothstep — a linear blend leaves a visible kink in the motion at both ends.
        let t = blend * blend * (3 - 2 * blend)

        camera.position = fromPosition + (targetPosition - fromPosition) * t
        camera.rotation = SIMD3<Float>(
            CameraOrbit.blendAngle(from: fromRotation.x, to: orbitRotation.x, t: t),
            CameraOrbit.blendAngle(from: fromRotation.y, to: orbitRotation.y, t: t),
            CameraOrbit.blendAngle(from: fromRotation.z, to: orbitRotation.z, t: t))
    }

    /// Interpolate along the SHORT way around. A plain lerp between, say, 3.0 and -3.0 rad
    /// spins the camera almost all the way round instead of crossing the nearby wrap point.
    private static func blendAngle(from: Float, to: Float, t: Float) -> Float {
        var delta = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        return from + delta * t
    }
}
