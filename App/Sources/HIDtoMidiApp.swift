import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { AppModel.shared.shutdown() }
}

@main
struct HIDtoMidiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("HIDtoMidi", id: "main") {
            ContentView().environmentObject(model)
        }
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
