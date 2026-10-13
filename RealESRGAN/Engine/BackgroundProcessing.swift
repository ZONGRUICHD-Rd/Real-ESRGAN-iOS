import ActivityKit
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

/// Everything that keeps one upscale run visible and alive outside the app:
/// - our own Live Activity (Dynamic Island + Lock Screen) with progress and a countdown;
/// - an iOS 26 `BGContinuedProcessingTask`, so the work keeps running after the app is backgrounded.
///   When the system accepts it, it shows its own progress Live Activity, so ours is ended to avoid
///   showing two.
/// - a short background-task assertion as a fallback when the system declines the request.
@MainActor
final class ProcessingSession {
    typealias State = UpscaleActivityAttributes.ContentState

    /// Whether the run can keep going for a long time in the background.
    private(set) var runsInBackground = false

    private let box = TaskBox()
    private let title: String
    private var fallbackID: UIBackgroundTaskIdentifier = .invalid
    private var activity: Activity<UpscaleActivityAttributes>?
    private var lastPushed: (state: State, date: Date)?
    private var finished = false

    /// - Parameter onExpire: Called when the person cancels from the system Live Activity or the task expires.
    init(modelTitle: String, sizeDescription: String, onExpire: @escaping @Sendable () -> Void) {
        title = "超分 · \(modelTitle)"
        let initial = State(stage: .preparing, completed: 0, total: 1, estimatedEnd: nil)

        if ActivityAuthorizationInfo().areActivitiesEnabled {
            activity = try? Activity.request(
                attributes: UpscaleActivityAttributes(modelTitle: modelTitle, sizeDescription: sizeDescription),
                content: ActivityContent(state: initial, staleDate: nil),
                pushType: nil)
        }

        runsInBackground = submitContinuedTask(subtitle: initial.stageText, onExpire: onExpire)
        if !runsInBackground {
            fallbackID = UIApplication.shared.beginBackgroundTask(withName: "upscale") { [weak self] in
                MainActor.assumeIsolated { self?.endFallback() }
            }
        }
    }

    func update(stage: State.Stage, completed: Int, total: Int, remaining: TimeInterval?) {
        guard !finished else { return }
        let state = State(
            stage: stage, completed: completed, total: max(total, 1),
            estimatedEnd: remaining.map { Date().addingTimeInterval($0) })
        box.update(title: title, subtitle: state.stageText, completed: Int64(state.completed), total: Int64(state.total))
        pushActivity(state)
    }

    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        box.finish(success: success)
        endFallback()
        if let activity {
            let state = State(stage: success ? .finished : .failed, completed: 1, total: 1, estimatedEnd: nil)
            let policy: ActivityUIDismissalPolicy = success ? .after(Date().addingTimeInterval(8)) : .immediate
            Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy) }
            self.activity = nil
        }
    }

    // MARK: Private

    private func submitContinuedTask(subtitle: String, onExpire: @escaping @Sendable () -> Void) -> Bool {
        // Use the wildcard prefix declared in Info.plist rather than the runtime bundle ID:
        // sideloading tools often rewrite the bundle ID, which would no longer match the permitted list.
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard let wildcard = permitted.first(where: { $0.hasSuffix(".*") }) else { return false }
        let identifier = String(wildcard.dropLast()) + UUID().uuidString

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
        guard registered else { return false }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
    }

    private func pushActivity(_ state: State) {
        guard let activity else { return }
        // The system is showing its own progress Live Activity for the continued task.
        if box.isAttached {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            self.activity = nil
            return
        }
        // Keep updates modest: on stage changes, on each new percent, or every few seconds.
        if let lastPushed, lastPushed.state.stage == state.stage {
            let percentChanged = Int(state.fraction * 100) != Int(lastPushed.state.fraction * 100)
            guard percentChanged || Date().timeIntervalSince(lastPushed.date) > 5 else { return }
        }
        lastPushed = (state, Date())
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func endFallback() {
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

    var isAttached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return task != nil
    }

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
