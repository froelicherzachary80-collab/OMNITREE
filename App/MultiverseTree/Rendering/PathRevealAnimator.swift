import Foundation
import simd

/// Drives the branch-reveal sequence:
/// 1 darken the universe → 2 highlight the start node → 3 pulse down the first branch →
/// 4 reveal each next person → 5 continue through every hop → 6 merge all paths →
/// 7 zoom out over the network → 8 signal that the evidence panel can open.
/// Supports pause, replay and scrubbing; rendering reads `frame(at:)` every frame.
struct PathRevealAnimator {
    struct Hop { let edgeSlot: Int?; let from: Int32; let to: Int32 }

    struct Frame {
        var edgeStates: [Int: SIMD4<Float>] = [:]
        var nodeHighlight: [Int32: Float] = [:]
        var dim: Float = 0
        var focusPoints: [Int32] = []
        var finished = false
        var phaseDescription = ""
    }

    let paths: [[Hop]]
    let darkenDuration: Double = 0.7
    let hopDuration: Double = 1.0
    let mergeDuration: Double = 1.2
    let zoomDuration: Double = 1.4

    private(set) var playhead: Double = 0
    private(set) var isPlaying = true
    private var lastTick: Double?

    init(paths: [[Hop]]) { self.paths = paths.filter { !$0.isEmpty } }

    var primary: [Hop] { paths.first ?? [] }
    var totalDuration: Double { darkenDuration + Double(primary.count) * hopDuration + mergeDuration + zoomDuration }
    var isActive: Bool { !paths.isEmpty }

    mutating func togglePause() { isPlaying.toggle(); lastTick = nil }
    mutating func replay() { playhead = 0; isPlaying = true; lastTick = nil }
    mutating func scrub(to fraction: Double) { playhead = max(0, min(1, fraction)) * totalDuration }

    /// Advances the playhead using wall-clock time (seconds).
    mutating func tick(now: Double) {
        defer { lastTick = now }
        guard isPlaying, let last = lastTick else { return }
        playhead = min(totalDuration, playhead + (now - last))
    }

    /// `shaderTime` is the renderer's clock so pulse starts line up with the branch shader.
    func frame(shaderTime: Float) -> Frame {
        var f = Frame()
        guard let first = primary.first else { return f }
        let t = playhead
        f.dim = Float(min(1, t / darkenDuration))
        f.nodeHighlight[first.from] = 1
        f.focusPoints = [first.from]
        f.phaseDescription = "Locating \(primary.count)-step connection"

        let hopsStart = darkenDuration
        for (i, hop) in primary.enumerated() {
            let start = hopsStart + Double(i) * hopDuration
            guard t >= start else { break }
            let local = Float(min(1, (t - start) / hopDuration))
            if let slot = hop.edgeSlot {
                f.edgeStates[slot] = SIMD4(1, local, shaderTime - Float(t - start), 0)
            }
            if local >= 0.85 { f.nodeHighlight[hop.to] = min(1, (local - 0.85) / 0.15) }
            f.focusPoints = [hop.from, hop.to]
            f.phaseDescription = "Following branch \(i + 1) of \(primary.count)"
        }

        let mergeStart = hopsStart + Double(primary.count) * hopDuration
        if t >= mergeStart {
            let local = Float(min(1, (t - mergeStart) / mergeDuration))
            for path in paths.dropFirst() {
                for hop in path {
                    if let slot = hop.edgeSlot, f.edgeStates[slot] == nil {
                        f.edgeStates[slot] = SIMD4(0.8, local, shaderTime - Float(t - mergeStart), 0)
                    }
                    f.nodeHighlight[hop.from] = max(f.nodeHighlight[hop.from] ?? 0, local * 0.8)
                    f.nodeHighlight[hop.to] = max(f.nodeHighlight[hop.to] ?? 0, local * 0.8)
                }
            }
            f.phaseDescription = paths.count > 1 ? "Merging \(paths.count) documented paths" : "Connection complete"
        }

        let zoomStart = mergeStart + mergeDuration
        if t >= zoomStart {
            f.focusPoints = Array(Set(paths.flatMap { $0.flatMap { [$0.from, $0.to] } }))
            f.phaseDescription = "Revealing the connection network"
        }
        if t >= totalDuration {
            f.finished = true
            f.phaseDescription = "Tap any node or branch to inspect its evidence"
        }
        return f
    }
}

/// Animates newly discovered relationships growing from one node to the other.
struct BranchGrowthAnimator {
    private var starts: [Int: Double] = [:]
    let duration: Double = 1.6

    mutating func grow(slots: [Int], now: Double) {
        for (i, s) in slots.enumerated() { starts[s] = now + Double(i) * 0.12 }
    }

    mutating func states(now: Double, shaderTime: Float) -> [Int: SIMD4<Float>] {
        var out: [Int: SIMD4<Float>] = [:]
        for (slot, start) in starts {
            let p = (now - start) / duration
            if p >= 1.4 { starts[slot] = nil; continue }
            out[slot] = SIMD4(0.9, Float(max(0, min(1, p))), shaderTime - Float(max(0, now - start)), 0)
        }
        return out
    }
}
