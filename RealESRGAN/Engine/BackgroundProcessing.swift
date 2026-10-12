import BackgroundTasks
import Foundation
import os
import UIKit

/// Whether the app is currently in the background, readable from any thread.
final class AppActivity: @unchecked Sendable {
    static let shared = AppActivity()

    private let state = OSAllocatedUnfairLock(initialState: false)

    var isInBackground: Bool { state.withLock { $0 } }

    func setInBackground(_ value: Bool) {
        state.withLock { $0 = value }
    }
}

/// Runs an upscale inside a `BGContinuedProcessingTask` (iOS 26), so the work keeps going after the
/// app is backgrounded and the system shows its progress as a Live Activity in the Dynamic Island
/// and on the Lock Screen, with a cancel button. Falls back to a short background-task assertion
/// when the system declines the request.
@MainActor
final class ProcessingSession {
    private let box = TaskBox()
    private var fallbackID: UIBackgroundTaskIdentifier = .invalid

    /// - Parameter onExpire: Called when the person cancels from the Live Activity or the system expires the task.
    init(title: String, subtitle: String, onExpire: @escaping @Sendable () -> Void) {
        let prefix = Bundle.main.bundleIdentifier ?? "com.zongruichd.realesrgan"
        let identifier = "\(prefix).upscale.\(UUID().uuidString)"
        let box = box
        box.update(title: title, subtitle: subtitle, completed: 0, total: 1)

        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            task.expirationHandler = onExpire
            box.attach(task)
        }

        var submitted = false
        if registered {
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            request.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(request)
                submitted = true
            } catch {
                submitted = false
            }
        }
        if !submitted {
            fallbackID = UIApplication.shared.beginBackgroundTask(withName: "upscale") { [weak self] in
                MainActor.assumeIsolated { self?.finish(success: false) }
            }
        }
    }

    func update(title: String, subtitle: String, completed: Int, total: Int) {
        box.update(title: title, subtitle: subtitle, completed: Int64(completed), total: Int64(max(total, 1)))
    }

    func finish(success: Bool) {
        box.finish(success: success)
        if fallbackID != .invalid {
            UIApplication.shared.endBackgroundTask(fallbackID)
            fallbackID = .invalid
        }
    }
}

/// Thread-safe holder for the system task, which is handed to us on a background queue.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: BGContinuedProcessingTask?
    private var outcome: Bool?
    private var title = ""
    private var subtitle = ""
    private var completed: Int64 = 0
    private var total: Int64 = 1

    func attach(_ task: BGContinuedProcessingTask) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        if let outcome {
            task.setTaskCompleted(success: outcome)
        } else {
            apply(to: task)
        }
    }

    func update(title: String, subtitle: String, completed: Int64, total: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == nil else { return }
        self.title = title
        self.subtitle = subtitle
        self.completed = completed
        self.total = total
        if let task { apply(to: task) }
    }

    func finish(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == nil else { return }
        outcome = success
        if let task {
            if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
            task.setTaskCompleted(success: success)
        }
    }

    private func apply(to task: BGContinuedProcessingTask) {
        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = completed
        task.updateTitle(title, subtitle: subtitle)
    }
}
