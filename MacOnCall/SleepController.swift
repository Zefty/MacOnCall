import AppKit
import CoreGraphics
import Foundation
import IOKit.ps

@MainActor
final class SleepController: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case automatic
        case manual

        var id: Self { self }
        var title: String { self == .automatic ? "Automatic" : "Manual" }
    }

    @Published var mode: Mode {
        didSet {
            defaults.set(mode.rawValue, forKey: Keys.mode)
            scheduleReconcile()
        }
    }
    @Published var manualPreventSleep: Bool {
        didSet {
            defaults.set(manualPreventSleep, forKey: Keys.manualPreventSleep)
            scheduleReconcile()
        }
    }
    @Published private(set) var externalDisplayCount = 0
    @Published private(set) var isSleepPreventionActive: Bool
    @Published private(set) var isChangingSetting = false
    @Published private(set) var lastError: String?

    private let defaults = UserDefaults.standard
    private var hasEnabledSleepPrevention: Bool
    private var reconciliationScheduled = false
    private var powerSourceRunLoopSource: CFRunLoopSource?

    var isPreventingSleep: Bool { isSleepPreventionActive }
    var iconName: String { isPreventingSleep ? "cup.and.saucer.fill" : "moon.zzz" }
    var statusText: String {
        if isChangingSetting { return "Updating power setting…" }
        return isPreventingSleep ? "Sleep prevention is active" : "Normal sleep behaviour"
    }

    init() {
        let storedMode = defaults.string(forKey: Keys.mode).flatMap(Mode.init(rawValue:)) ?? .automatic
        mode = storedMode
        manualPreventSleep = defaults.bool(forKey: Keys.manualPreventSleep)
        hasEnabledSleepPrevention = defaults.bool(forKey: Keys.hasEnabledSleepPrevention)
        isSleepPreventionActive = PrivilegedPowerSettings.currentSleepDisabled() ?? false

        refreshExternalDisplayCount()
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        powerSourceRunLoopSource = IOPSCreateLimitedPowerNotification(
            powerSourceChangeCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )?.takeRetainedValue()
        if let powerSourceRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
        }
        scheduleReconcile()
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
        }
    }

    func refreshExternalDisplayCount() {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
        externalDisplayCount = displays.prefix(Int(displayCount)).filter { CGDisplayIsBuiltin($0) == 0 }.count
        scheduleReconcile()
    }

    fileprivate func refreshPowerSetting() {
        if let currentSetting = PrivilegedPowerSettings.currentSleepDisabled() {
            isSleepPreventionActive = currentSetting
        }
        scheduleReconcile()
    }

    /// SwiftUI can call binding setters while it is rendering. Deferring this
    /// work prevents the resulting @Published changes from occurring in that
    /// same view-update transaction.
    private func scheduleReconcile() {
        guard !reconciliationScheduled else { return }
        reconciliationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconciliationScheduled = false
            self.reconcile()
        }
    }

    private func reconcile() {
        guard !isChangingSetting else { return }

        let shouldPreventSleep = mode == .automatic
            ? externalDisplayCount >= 1
            : manualPreventSleep

        if shouldPreventSleep {
            guard !isSleepPreventionActive else { return }
            setSleepPrevention(true)
        } else if hasEnabledSleepPrevention {
            setSleepPrevention(false)
        }
    }

    private func setSleepPrevention(_ enabled: Bool) {
        isChangingSetting = true
        lastError = nil

        // Authorization is inherently latency-bound on a system service. Utility QoS
        // avoids making that service inherit an interactive-priority wait.
        DispatchQueue.global(qos: .utility).async {
            let result = PrivilegedPowerSettings.setSleepDisabled(enabled)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isChangingSetting = false
                switch result {
                case .success:
                    self.hasEnabledSleepPrevention = enabled
                    self.defaults.set(enabled, forKey: Keys.hasEnabledSleepPrevention)
                    self.isSleepPreventionActive = enabled
                    self.scheduleReconcile()
                case .failure(let error):
                    self.lastError = error.message
                }
            }
        }
    }

    func retry() {
        let shouldPreventSleep = mode == .automatic
            ? externalDisplayCount >= 1
            : manualPreventSleep
        setSleepPrevention(shouldPreventSleep)
    }
}

private enum Keys {
    static let mode = "mode"
    static let manualPreventSleep = "manualPreventSleep"
    static let hasEnabledSleepPrevention = "hasEnabledSleepPrevention"
}

private func displayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let controller = Unmanaged<SleepController>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        controller.refreshExternalDisplayCount()
    }
}

private func powerSourceChangeCallback(_ userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let controller = Unmanaged<SleepController>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        controller.refreshPowerSetting()
    }
}

private enum PrivilegedPowerSettings {
    enum CommandError: Error {
        case failed(String)

        var message: String {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    static func setSleepDisabled(_ disabled: Bool) -> Result<Void, CommandError> {
        let value = disabled ? "1" : "0"
        let source = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure(.failed("Could not prepare the power-setting command."))
        }
        script.executeAndReturnError(&error)

        if let error {
            let description = error[NSAppleScript.errorMessage] as? String ?? "macOS could not update the power setting."
            return .failure(.failed(description))
        }

        guard currentSleepDisabled() == disabled else {
            return .failure(.failed("macOS did not apply the requested sleep setting."))
        }
        return .success(())
    }

    static func currentSleepDisabled() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let output = Pipe()
        process.standardOutput = output

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else {
            return nil
        }

        return text.range(of: #"(?m)^\s*SleepDisabled\s+1\s*$"#, options: .regularExpression) != nil
    }
}
