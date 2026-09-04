import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
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
    private var systemSleepAssertionID: IOPMAssertionID?
    private var displaySleepAssertionID: IOPMAssertionID?
    private var reconciliationScheduled = false
    private var shouldRebuildActiveSession = false
    private var clamshellHeartbeat: DispatchSourceTimer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?

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
        isSleepPreventionActive = false

        refreshExternalDisplayCount()
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        powerSourceRunLoopSource = IOPSCreateLimitedPowerNotification(
            powerSourceChangeCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )?.takeRetainedValue()
        if let powerSourceRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAfterSystemTransition()
            }
        }
        scheduleReconcile()
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let systemSleepAssertionID {
            IOPMAssertionRelease(systemSleepAssertionID)
        }
        if let displaySleepAssertionID {
            IOPMAssertionRelease(displaySleepAssertionID)
        }
        clamshellHeartbeat?.cancel()
        ClamshellSleepOverride.setDisabled(false)
    }

    func refreshExternalDisplayCount() {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
        externalDisplayCount = displays.prefix(Int(displayCount)).filter { CGDisplayIsBuiltin($0) == 0 }.count
        scheduleReconcile()
    }

    fileprivate func refreshAfterSystemTransition() {
        refreshExternalDisplayCount()
        scheduleReconcile(rebuildActiveSession: true)
    }

    /// SwiftUI can call binding setters while it is rendering. Deferring this
    /// work prevents the resulting @Published changes from occurring in that
    /// same view-update transaction.
    private func scheduleReconcile(rebuildActiveSession: Bool = false) {
        if rebuildActiveSession {
            shouldRebuildActiveSession = true
        }
        guard !reconciliationScheduled else { return }
        reconciliationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconciliationScheduled = false
            let rebuildActiveSession = self.shouldRebuildActiveSession
            self.shouldRebuildActiveSession = false
            self.reconcile(rebuildActiveSession: rebuildActiveSession)
        }
    }

    private func reconcile(rebuildActiveSession: Bool = false) {
        guard !isChangingSetting else { return }

        let shouldPreventSleep = mode == .automatic
            ? externalDisplayCount >= 1
            : manualPreventSleep

        if shouldPreventSleep {
            if rebuildActiveSession, isSleepPreventionActive {
                setSleepPrevention(false)
            }
            guard !isSleepPreventionActive else { return }
            setSleepPrevention(true)
        } else if isSleepPreventionActive {
            setSleepPrevention(false)
        }
    }

    private func setSleepPrevention(_ enabled: Bool) {
        isChangingSetting = true
        lastError = nil

        let result = SleepAssertion.setActive(
            enabled,
            systemAssertionID: &systemSleepAssertionID,
            displayAssertionID: &displaySleepAssertionID
        )
        isChangingSetting = false
        switch result {
        case .success:
            isSleepPreventionActive = enabled
            if enabled {
                startClamshellHeartbeat()
            } else {
                clamshellHeartbeat?.cancel()
                clamshellHeartbeat = nil
            }
        case .failure(let error):
            lastError = error.message
        }
    }

    private func startClamshellHeartbeat() {
        clamshellHeartbeat?.cancel()
        let heartbeat = DispatchSource.makeTimerSource(queue: .main)
        heartbeat.schedule(deadline: .now() + 30, repeating: 30)
        heartbeat.setEventHandler {
            ClamshellSleepOverride.setDisabled(true)
        }
        heartbeat.resume()
        clamshellHeartbeat = heartbeat
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
        controller.refreshAfterSystemTransition()
    }
}

private enum SleepAssertion {
    enum CommandError: Error {
        case failed(String)

        var message: String {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    static func setActive(
        _ enabled: Bool,
        systemAssertionID: inout IOPMAssertionID?,
        displayAssertionID: inout IOPMAssertionID?
    ) -> Result<Void, CommandError> {
        if enabled {
            guard systemAssertionID == nil, displayAssertionID == nil else { return .success(()) }

            var newSystemAssertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
            let systemStatus = IOPMAssertionCreateWithName(
                NSString(string: kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                NSString(string: "MacOnCall") as CFString,
                &newSystemAssertionID
            )
            guard systemStatus == kIOReturnSuccess else {
                return .failure(.failed("macOS could not create a sleep-prevention assertion (error \(systemStatus))."))
            }

            var newDisplayAssertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
            let displayStatus = IOPMAssertionCreateWithName(
                NSString(string: kIOPMAssertionTypePreventUserIdleDisplaySleep) as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                NSString(string: "MacOnCall") as CFString,
                &newDisplayAssertionID
            )
            guard displayStatus == kIOReturnSuccess else {
                IOPMAssertionRelease(newSystemAssertionID)
                return .failure(.failed("macOS could not create a display-sleep assertion (error \(displayStatus))."))
            }

            systemAssertionID = newSystemAssertionID
            displayAssertionID = newDisplayAssertionID
            guard ClamshellSleepOverride.setDisabled(true) else {
                IOPMAssertionRelease(newSystemAssertionID)
                IOPMAssertionRelease(newDisplayAssertionID)
                systemAssertionID = nil
                displayAssertionID = nil
                return .failure(.failed("macOS could not enable clamshell mode."))
            }
        } else {
            ClamshellSleepOverride.setDisabled(false)
            if let existingSystemAssertionID = systemAssertionID {
                IOPMAssertionRelease(existingSystemAssertionID)
                systemAssertionID = nil
            }
            if let existingDisplayAssertionID = displayAssertionID {
                IOPMAssertionRelease(existingDisplayAssertionID)
                displayAssertionID = nil
            }
        }
        return .success(())
    }
}

private enum ClamshellSleepOverride {
    // kPMSetClamshellSleepState is a private IOKit user-client selector used by
    // macOS power-management utilities. It is not exposed by the public SDK.
    private static let setClamshellSleepStateSelector: UInt32 = 12

    static func setDisabled(_ disabled: Bool) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            return false
        }
        defer { IOServiceClose(connection) }

        var input: UInt64 = disabled ? 1 : 0
        return IOConnectCallScalarMethod(
            connection,
            setClamshellSleepStateSelector,
            &input,
            1,
            nil,
            nil
        ) == KERN_SUCCESS
    }
}
