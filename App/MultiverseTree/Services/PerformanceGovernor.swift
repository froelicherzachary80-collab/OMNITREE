import Foundation
import MultiverseCore

/// Automatic quality adjustment from frame time, graph size and device thermal state.
@MainActor
final class PerformanceGovernor {
    private var samples: [Double] = []
    private var lastChange = Date.distantPast
    var onChange: ((RenderQuality) -> Void)?

    func recommended(base: RenderQuality, nodeCount: Int) -> RenderQuality {
        var q = base
        switch ProcessInfo.processInfo.thermalState {
        case .serious: q = min(q, .balanced)
        case .critical: q = .performance
        default: break
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { q = min(q, .balanced) }
        if nodeCount > 50_000 { q = min(q, .balanced) }
        return q
    }

    /// Feed frame durations; drops one tier if the average stays 30 % over budget for ~2 s.
    func sample(frameTime: Double, current: RenderQuality) {
        samples.append(frameTime)
        guard samples.count >= 120 else { return }
        let avg = samples.reduce(0, +) / Double(samples.count)
        samples.removeAll(keepingCapacity: true)
        let budget = 1.0 / Double(current.preferredFPS)
        if avg > budget * 1.3, Date().timeIntervalSince(lastChange) > 5, let lower = current.lower {
            lastChange = Date()
            onChange?(lower)
        }
    }
}

extension RenderQuality: Comparable {
    private var rank: Int { RenderQuality.allCases.firstIndex(of: self)! }
    public static func < (a: RenderQuality, b: RenderQuality) -> Bool { a.rank < b.rank }
}
