import AppKit
import CleanMacCore
import Observation

/// UserDefaults keys for the memory settings, shared by the settings page, the menu bar and the controller.
enum MemorySetting {
    static let showInMenuBar = "memory.showInMenuBar"
    static let showPercent = "memory.showPercent"
    static let purgeOnAppQuit = "memory.purgeOnAppQuit"
    static let purgeWhenLow = "memory.purgeWhenLow"
    static let lowThresholdMB = "memory.lowThresholdMB"
    static let purgeOnWake = "memory.purgeOnWake"

    static let thresholdRange = 1...1024
    static let defaultThresholdMB = 32

    static func register(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            showInMenuBar: true, showPercent: true, purgeOnAppQuit: false, purgeWhenLow: false,
            lowThresholdMB: defaultThresholdMB, purgeOnWake: false,
        ])
    }

    static func anyAutomatic(_ defaults: UserDefaults = .standard) -> Bool {
        [purgeOnAppQuit, purgeWhenLow, purgeOnWake].contains { defaults.bool(forKey: $0) }
    }
}

/// Runs `purge` on its own when a heavy app quits, free memory runs low, or the Mac wakes,
/// at most once every three minutes. It only ever uses the standing authorization, so it never prompts.
@Observable @MainActor
final class AutoPurgeController {
    static let shared = AutoPurgeController()

    private(set) var lastPurge: Date?
    private(set) var isAuthorized = false
    @ObservationIgnored private var throttle = PurgeThrottle()
    @ObservationIgnored private var tracker = AppMemoryTracker()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isPurging = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        MemorySetting.register(defaults)
    }

    func start() {
        guard timer == nil else { return }
        refreshAuthorization()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self.appDidQuit(pid: pid) } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.didWake() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        tick()
    }

    func refreshAuthorization() {
        Task { isAuthorized = await offMain { PurgeAuthorization.isGranted() } }
    }

    /// Asks for the password once. Returns false when the user cancels.
    func authorize() async -> Bool {
        let granted = await offMain { PurgeAuthorization.grant() }
        isAuthorized = granted
        return granted
    }

    func revoke() async {
        _ = await offMain { PurgeAuthorization.revoke() }
        isAuthorized = await offMain { PurgeAuthorization.isGranted() }
    }

    private func tick() {
        if defaults.bool(forKey: MemorySetting.purgeOnAppQuit) {
            let pids = NSWorkspace.shared.runningApplications.map(\.processIdentifier)
            tracker.record(Dictionary(uniqueKeysWithValues: pids.compactMap { pid in SystemMonitor.footprint(of: pid).map { (pid, $0) } }))
        }
        if defaults.bool(forKey: MemorySetting.purgeWhenLow) {
            let threshold = Int64(clampedThreshold(defaults.integer(forKey: MemorySetting.lowThresholdMB))) * 1_048_576
            if SystemMonitor.memory().free < threshold { purge() }
        }
    }

    private func appDidQuit(pid: pid_t) {
        if tracker.didQuit(pid: pid), defaults.bool(forKey: MemorySetting.purgeOnAppQuit) { purge() }
    }

    private func didWake() {
        guard defaults.bool(forKey: MemorySetting.purgeOnWake) else { return }
        // Give the system a moment to settle after waking before dropping its caches.
        Task {
            try? await Task.sleep(for: .seconds(5))
            purge()
        }
    }

    private func purge() {
        guard isAuthorized, !isPurging, throttle.claim() else { return }
        isPurging = true
        Task {
            let ok = await offMain { PurgeAuthorization.purgeWithoutPrompt() }
            isPurging = false
            if ok { lastPurge = Date() } else { refreshAuthorization() }
        }
    }
}

func clampedThreshold(_ value: Int) -> Int {
    min(max(value, MemorySetting.thresholdRange.lowerBound), MemorySetting.thresholdRange.upperBound)
}
