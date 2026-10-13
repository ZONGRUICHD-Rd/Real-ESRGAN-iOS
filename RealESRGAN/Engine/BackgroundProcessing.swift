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

/// What happened when a run tried to show its progress outside the app, for the diagnostics section.
struct BackgroundDiagnostics: Equatable {
    var liveActivity: String
    var liveActivityOK: Bool
    var extensionInstalled: Bool
    var backgroundTask: String
    var backgroundOK: Bool
}

/// Everything that keeps one upscale run visible and alive outside the app:
/// - our own Live Activity (Dynamic Island + Lock Screen) with progress and a countdown;
/// - an iOS 26 `BGContinuedProcessingTask`, so the work keeps running after the app is backgrounded.
/// - a short background-task assertion as a fallback when the system declines the request.
@MainActor
final class ProcessingSession {
    typealias State = UpscaleActivityAttributes.ContentState

    /// Whether the run can keep going for a long time in the background.
    private(set) var runsInBackground = false
    private(set) var diagnostics: BackgroundDiagnostics

    private let box = TaskBox()
    private let title: String
    private var fallbackID: UIBackgroundTaskIdentifier = .invalid
    private var activity: Activity<UpscaleActivityAttributes>?
    private var lastPushed: (state: State, date: Date)?
    private var finished = false

    /// - Parameter onExpire: Called when the person cancels from the system Live Activity or the task expires.
    init(
        modelTitle: String, sizeDescription: String, showsLiveActivity: Bool,
        onExpire: @escaping @Sendable () -> Void
    ) {
        title = "超分 · \(modelTitle)"
        let initial = State(stage: .preparing, completed: 0, total: 1, estimatedEnd: nil)
        let extensionURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent("RealESRGANWidgets.appex")
        diagnostics = BackgroundDiagnostics(
            liveActivity: "", liveActivityOK: false,
            extensionInstalled: extensionURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
            backgroundTask: "", backgroundOK: false)

        if !showsLiveActivity {
            diagnostics.liveActivity = "已在 App 中关闭"
            diagnostics.liveActivityOK = true
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                activity = try Activity.request(
                    attributes: UpscaleActivityAttributes(modelTitle: modelTitle, sizeDescription: sizeDescription),
                    content: ActivityContent(state: initial, staleDate: nil),
                    pushType: nil)
                diagnostics.liveActivity = "已创建"
                diagnostics.liveActivityOK = true
            } catch {
                diagnostics.liveActivity = "创建失败：\(error.localizedDescription)"
            }
        } else {
            diagnostics.liveActivity = "已在“设置”中关闭"
        }

        let outcome = submitContinuedTask(subtitle: initial.stageText, onExpire: onExpire)
        runsInBackground = outcome.ok
        diagnostics.backgroundTask = outcome.message
        diagnostics.backgroundOK = outcome.ok
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

    private func submitContinuedTask(
        subtitle: String, onExpire: @escaping @Sendable () -> Void
    ) -> (ok: Bool, message: String) {
        // Use the wildcard prefix declared in Info.plist rather than the runtime bundle ID:
        // sideloading tools often rewrite the bundle ID, which would no longer match the permitted list.
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard let wildcard = permitted.first(where: { $0.hasSuffix(".*") }) else {
            return (false, "Info.plist 中没有后台任务标识符")
        }
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
        guard registered else { return (false, "注册后台任务失败") }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return (true, "已提交，等待系统启动")
        } catch {
            let error = error as NSError
            let reason: String
            switch error.code {
            case 1: reason = "系统不允许（可能关闭了“后台 App 刷新”，或开启了低电量模式）"
            case 2: reason = "待处理的后台任务太多"
            case 3: reason = "标识符不被允许（签名工具可能修改了 Bundle ID）"
            default: reason = error.localizedDescription
            }
            return (false, "\(reason)［\(error.domain) \(error.code)］")
        }
    }

    private func pushActivity(_ state: State) {
        if box.isAttached, !diagnostics.backgroundTask.hasPrefix("系统已开始") {
            diagnostics.backgroundTask = "系统已开始运行，可切到后台"
        }
        guard let activity else { return }
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

#if DEBUG
/// Starts a sample Live Activity when launched with `-LiveActivityDemo`, so CI can screenshot the
/// Dynamic Island in the simulator.
enum LiveActivityDemo {
    @MainActor
    static func startIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-LiveActivityDemo") else { return }
        let state = UpscaleActivityAttributes.ContentState(
            stage: .upscaling, completed: 97, total: 252, estimatedEnd: Date().addingTimeInterval(150))
        _ = try? Activity.request(
            attributes: UpscaleActivityAttributes(modelTitle: "通用照片 x4", sizeDescription: "4032 × 3024 → 8064 × 6048"),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil)
    }
}
#endif
