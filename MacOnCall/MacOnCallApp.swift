import SwiftUI

@main
struct MacOnCallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sleepController = SleepController()

    var body: some Scene {
        MenuBarExtra("MacOnCall", systemImage: sleepController.iconName) {
            MenuBarView(controller: sleepController)
        }
        .menuBarExtraStyle(.window)
    }
}
