import Foundation
import BackgroundTasks
import MultiverseCore

/// Runs queued research in the short windows iOS grants via BGProcessingTask.
/// iOS decides when (and whether) these run — typically while charging on Wi-Fi — and stops them
/// after a few minutes. For uninterrupted large jobs, use the `mvt` companion on your own computer.
enum BackgroundResearch {
    static let identifier = "com.multiversetree.research"

    static func register(scheduler: @escaping () -> ResearchScheduler?) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGProcessingTask, let s = scheduler() else { task.setTaskCompleted(success: false); return }
            schedule()
            let work = Task {
                _ = try? s.recoverInterruptedJobs()
                // Leave a safety margin before iOS's deadline.
                await s.runPending(maxJobs: 25, deadline: Date().addingTimeInterval(150))
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = {
                work.cancel()
                _ = try? s.recoverInterruptedJobs()
                task.setTaskCompleted(success: false)
            }
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
