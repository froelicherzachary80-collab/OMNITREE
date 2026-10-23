import Foundation
import simd

/// Smooth orbit camera with cinematic idle drift and fly-to transitions.
struct OrbitCamera {
    var target = SIMD3<Float>(0, 0, 0)
    var distance: Float = 90
    var yaw: Float = 0.6
    var pitch: Float = 0.25
    var fovY: Float = 55 * .pi / 180

    // Goals the camera eases toward every frame.
    var goalTarget = SIMD3<Float>(0, 0, 0)
    var goalDistance: Float = 90
    var goalYaw: Float = 0.6
    var goalPitch: Float = 0.25

    var idleDrift = true
    var lastInteraction = Date()

    var position: SIMD3<Float> {
        let cp = cos(pitch)
        return target + SIMD3(cp * sin(yaw), sin(pitch), cp * cos(yaw)) * distance
    }

    mutating func update(dt: Float) {
        let k = 1 - exp(-dt * 4.5)
        if idleDrift && Date().timeIntervalSince(lastInteraction) > 4 { goalYaw += dt * 0.035 }
        target += (goalTarget - target) * k
        distance += (goalDistance - distance) * k
        yaw += (goalYaw - yaw) * k
        pitch += (goalPitch - pitch) * k
    }

    mutating func rotate(dx: Float, dy: Float) {
        goalYaw -= dx * 0.006
        goalPitch = min(1.45, max(-1.45, goalPitch + dy * 0.006))
        lastInteraction = Date()
    }

    mutating func zoom(scale: Float) {
        goalDistance = min(4000, max(3, goalDistance / max(0.2, scale)))
        lastInteraction = Date()
    }

    mutating func pan(dx: Float, dy: Float, right: SIMD3<Float>, up: SIMD3<Float>) {
        let s = distance * 0.0015
        goalTarget -= right * dx * s
        goalTarget += up * dy * s
        lastInteraction = Date()
    }

    /// Fly to frame a set of points (used for zoom-in on a person and zoom-out over a revealed path).
    mutating func frame(_ points: [SIMD3<Float>], padding: Float = 1.4) {
        guard !points.isEmpty else { return }
        let center = points.reduce(SIMD3<Float>(repeating: 0), +) / Float(points.count)
        let radius = points.map { simd_length($0 - center) }.max() ?? 1
        goalTarget = center
        goalDistance = max(8, radius * padding / tan(fovY / 2))
        lastInteraction = Date()
    }

    func viewMatrix() -> simd_float4x4 { Matrix.lookAt(eye: position, center: target, up: SIMD3(0, 1, 0)) }

    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        Matrix.perspective(fovY: fovY, aspect: aspect, near: max(0.05, distance * 0.01), far: max(5000, distance * 20))
    }
}

enum Matrix {
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    /// Right-handed perspective with Metal's [0, 1] clip-space depth.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)))
    }
}
