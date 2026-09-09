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
    @Published private(set) var manualPreventSleep: Bool {
        didSet {
            defaults.set(manualPreventSleep, forKey: Keys.manualPreventSleep)
            scheduleReconcile()
        }
    }
    @Published private(set) var manualSessionEndDate: Date?
    @Published private(set) var manualTimeRemaining: TimeInterval?
    @Published private(set) var externalDisplayCount = 0
    @Published private(set) var isSleepPreventionActive: Bool
    @Published private(set) var isChangingSetting = false
    @Published private(set) var lastError: String?

    private let defaults = UserDefaults.standard
    private var systemSleepAssertionID: IOPMAssertionID?
    private var displaySleepAssertionID: IOPMAssertionID?
    private var reconciliationScheduled = false
    private var shouldRebuildActiveSession = false
    private var manualSessionTimer: DispatchSourceTimer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var clamshellNotificationPort: IONotificationPortRef?
    private var clamshellNotification = io_object_t(IO_OBJECT_NULL)

    static let manualDurationPresets = [1, 2, 3, 5, 8]

    var isPreventingSleep: Bool { isSleepPreventionActive }
    var isIndefiniteManualSession: Bool { manualPreventSleep && manualSessionEndDate == nil }
    var isTimedManualSession: Bool { manualPreventSleep && manualSessionEndDate != nil }
    var manualSessionStatusText: String? {
        guard manualPreventSleep else { return nil }
        guard let manualSessionEndDate, let manualTimeRemaining else {
            return "Active indefinitely"
        }

        let totalMinutes = max(1, Int(ceil(manualTimeRemaining / 60)))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let remaining = if hours > 0, minutes > 0 {
            "\(hours)h \(minutes)m remaining"
        } else if hours > 0 {
            "\(hours)h remaining"
        } else {
            "\(minutes)m remaining"
        }
        let endTime = manualSessionEndDate.formatted(date: .omitted, time: .shortened)
        return "\(remaining) · until \(endTime)"
    }
    var iconName: String { isPreventingSleep ? "cup.and.saucer.fill" : "moon.zzz" }
    var statusText: String {
        if isChangingSetting { return "Updating power setting…" }
        return isPreventingSleep ? "Sleep prevention is active" : "Normal sleep behaviour"
    }

    init() {
        let storedMode = defaults.string(forKey: Keys.mode).flatMap(Mode.init(rawValue:)) ?? .automatic
        let storedManualPreventSleep = defaults.bool(forKey: Keys.manualPreventSleep)
        let storedEndTimestamp = defaults.object(forKey: Keys.manualSessionEndDate) as? TimeInterval
        let storedEndDate = storedEndTimestamp.map(Date.init(timeIntervalSince1970:))
        let activeEndDate = storedEndDate.flatMap { $0 > Date() ? $0 : nil }
        mode = storedMode
        manualPreventSleep = storedManualPreventSleep && (storedEndDate == nil || activeEndDate != nil)
        manualSessionEndDate = activeEndDate
        manualTimeRemaining = activeEndDate?.timeIntervalSinceNow
        isSleepPreventionActive = false

        if storedEndDate != nil, activeEndDate == nil {
            defaults.set(false, forKey: Keys.manualPreventSleep)
            defaults.removeObject(forKey: Keys.manualSessionEndDate)
        }

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
        registerForClamshellChanges()
        startManualSessionTimerIfNeeded()
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
        if clamshellNotification != IO_OBJECT_NULL {
            IOObjectRelease(clamshellNotification)
        }
        if let clamshellNotificationPort {
            IONotificationPortSetDispatchQueue(clamshellNotificationPort, nil)
            IONotificationPortDestroy(clamshellNotificationPort)
        }
        if let systemSleepAssertionID {
            IOPMAssertionRelease(systemSleepAssertionID)
        }
        if let displaySleepAssertionID {
            IOPMAssertionRelease(displaySleepAssertionID)
        }
        manualSessionTimer?.cancel()
        _ = ClamshellSleepOverride.setDisabled(false)
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
        expireManualSessionIfNeeded()
        refreshExternalDisplayCount()
        scheduleReconcile(rebuildActiveSession: true)
    }

    fileprivate func handleClamshellStateChange(causesSleep: Bool) {
        guard causesSleep, isSleepPreventionActive else { return }
        if !ClamshellSleepOverride.setDisabled(true) {
            lastError = "macOS could not restore clamshell mode."
        }
    }

    func startManualSession(hours: Int) {
        guard hours > 0 else { return }
        let endDate = Date().addingTimeInterval(TimeInterval(hours) * 60 * 60)
        manualSessionEndDate = endDate
        manualTimeRemaining = endDate.timeIntervalSinceNow
        defaults.set(endDate.timeIntervalSince1970, forKey: Keys.manualSessionEndDate)
        manualPreventSleep = true
        startManualSessionTimerIfNeeded()
    }

    func setIndefiniteManualSession(_ enabled: Bool) {
        clearManualSessionDeadline()
        manualPreventSleep = enabled
    }

    func stopManualSession() {
        clearManualSessionDeadline()
        manualPreventSleep = false
    }

    func refreshManualSessionCountdown() {
        expireManualSessionIfNeeded()
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
        case .failure(let error):
            lastError = error.message
        }
    }

    private func registerForClamshellChanges() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        guard let notificationPort = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(notificationPort, DispatchQueue.main)

        var notification = io_object_t(IO_OBJECT_NULL)
        let status = IOServiceAddInterestNotification(
            notificationPort,
            service,
            kIOGeneralInterest,
            clamshellStateChangeCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            &notification
        )
        guard status == KERN_SUCCESS else {
            IONotificationPortSetDispatchQueue(notificationPort, nil)
            IONotificationPortDestroy(notificationPort)
            return
        }

        clamshellNotificationPort = notificationPort
        clamshellNotification = notification
    }

    private func startManualSessionTimerIfNeeded() {
        manualSessionTimer?.cancel()
        manualSessionTimer = nil
        guard let manualSessionEndDate else { return }

        let remaining = manualSessionEndDate.timeIntervalSinceNow
        guard remaining > 0 else {
            stopManualSession()
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + remaining, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.expireManualSessionIfNeeded()
        }
        timer.resume()
        manualSessionTimer = timer
    }

    private func expireManualSessionIfNeeded() {
        guard let manualSessionEndDate else { return }
        let remaining = manualSessionEndDate.timeIntervalSinceNow
        guard remaining <= 0 else {
            manualTimeRemaining = remaining
            return
        }
        stopManualSession()
    }

    private func clearManualSessionDeadline() {
        manualSessionTimer?.cancel()
        manualSessionTimer = nil
        manualSessionEndDate = nil
        manualTimeRemaining = nil
        defaults.removeObject(forKey: Keys.manualSessionEndDate)
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
    static let manualSessionEndDate = "manualSessionEndDate"
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

private func clamshellStateChangeCallback(
    _ userInfo: UnsafeMutableRawPointer?,
    _ service: io_service_t,
    _ messageType: natural_t,
    _ messageArgument: UnsafeMutableRawPointer?
) {
    guard messageType == clamshellStateChangeMessage, let userInfo else { return }
    let state = UInt(bitPattern: messageArgument)
    let causesSleep = state & UInt(kClamshellSleepBit) != 0
    let controller = Unmanaged<SleepController>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        controller.handleClamshellStateChange(causesSleep: causesSleep)
    }
}

// Swift does not import the nested C macros used to define
// kIOPMMessageClamshellStateChange: iokit_family_msg(13, 0x100).
private let clamshellStateChangeMessage = natural_t(0xE003_4100)

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
            _ = ClamshellSleepOverride.setDisabled(false)
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
