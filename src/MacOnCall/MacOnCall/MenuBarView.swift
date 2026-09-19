import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: SleepController
    @State private var customHours = "4"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MacOnCall")
                    .font(.headline)
                Text(controller.statusText)
                    .font(.subheadline)
                    .foregroundStyle(controller.isPreventingSleep ? .green : .secondary)
            }

            Divider()

            Picker("Mode", selection: modeBinding) {
                ForEach(SleepController.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(controller.isChangingSetting)

            modeControls

            if let error = controller.lastError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") {
                        controller.retry()
                    }
                    .font(.caption)
                }
            }

            Divider()

            Button("Quit MacOnCall") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 300)
    }

    private var modeBinding: Binding<SleepController.Mode> {
        Binding(
            get: { controller.mode },
            set: { value in
                DispatchQueue.main.async {
                    controller.mode = value
                }
            }
        )
    }

    private var indefiniteBinding: Binding<Bool> {
        Binding(
            get: { controller.isIndefiniteManualSession },
            set: { value in
                DispatchQueue.main.async {
                    controller.setIndefiniteManualSession(value)
                }
            }
        )
    }

    private var parsedCustomHours: Int? {
        guard let hours = Int(customHours), (1...999).contains(hours) else { return nil }
        return hours
    }

    private var modeControls: some View {
        // Keep both panels in the layout so MenuBarExtra does not resize and
        // lose its menu-bar anchor when switching between modes.
        ZStack(alignment: .topLeading) {
            automaticControls
                .opacity(controller.mode == .automatic ? 1 : 0)
                .allowsHitTesting(controller.mode == .automatic)
                .accessibilityHidden(controller.mode != .automatic)

            manualControls
                .opacity(controller.mode == .manual ? 1 : 0)
                .allowsHitTesting(controller.mode == .manual)
                .disabled(controller.mode != .manual)
                .accessibilityHidden(controller.mode != .manual)
        }
    }

    private var automaticControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Enable with any external display", systemImage: "display.2")
            Text("\(controller.externalDisplayCount) \(controller.externalDisplayCount == 1 ? "external display" : "external displays") connected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep awake for")
                .font(.subheadline.weight(.medium))

            HStack(spacing: 6) {
                ForEach(SleepController.manualDurationPresets, id: \.self) { hours in
                    Button("\(hours)H") {
                        controller.startManualSession(hours: hours)
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isChangingSetting)
                }
            }

            HStack(spacing: 8) {
                TextField("Hours", text: $customHours)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                Text("hours")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start") {
                    guard let hours = parsedCustomHours else { return }
                    controller.startManualSession(hours: hours)
                }
                .disabled(parsedCustomHours == nil || controller.isChangingSetting)
            }

            Toggle("Indefinite", isOn: indefiniteBinding)
                .disabled(controller.isChangingSetting)

            if let status = controller.manualSessionStatusText {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if controller.isTimedManualSession {
                        Button("Stop") {
                            controller.stopManualSession()
                        }
                        .font(.caption)
                        .disabled(controller.isChangingSetting)
                    }
                }
            }
        }
        .task(id: controller.isTimedManualSession) {
            controller.refreshManualSessionCountdown()
            guard controller.isTimedManualSession else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                controller.refreshManualSessionCountdown()
            }
        }
    }
}
