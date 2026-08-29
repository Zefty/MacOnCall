import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: SleepController

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

            if controller.mode == .automatic {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Enable with any external display", systemImage: "display.2")
                    Text("\(controller.externalDisplayCount) \(controller.externalDisplayCount == 1 ? "external display" : "external displays") connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Toggle("Prevent Sleep", isOn: manualPreventSleepBinding)
                    .disabled(controller.isChangingSetting)
            }

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

    private var manualPreventSleepBinding: Binding<Bool> {
        Binding(
            get: { controller.manualPreventSleep },
            set: { value in
                DispatchQueue.main.async {
                    controller.manualPreventSleep = value
                }
            }
        )
    }
}
