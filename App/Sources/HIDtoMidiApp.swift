import AppKit
import SwiftUI

enum AppInfo {
    static let repoURL = URL(string: "https://github.com/Olivl/HIDtoMidi")!
    static let issuesURL = URL(string: "https://github.com/Olivl/HIDtoMidi/issues")!

    /// Version lue dans Info.plist (CFBundleShortVersionString) : à modifier là-bas uniquement.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    static func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Touches d'un clavier HID → Note, CC ou Program Change.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(
            string: "github.com/Olivl/HIDtoMidi",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: repoURL]))
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        credits.addAttribute(.paragraphStyle, value: center, range: NSRange(location: 0, length: credits.length))
        // .version vide : affiche « Version 1.0 » sans le n° de compilation entre parenthèses
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits,
                                                     .applicationVersion: version,
                                                     .version: ""])
        NSApp.activate(ignoringOtherApps: true)
    }
}

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
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("À propos de HIDtoMidi") { AppInfo.showAbout() }
            }
            CommandGroup(replacing: .help) {
                Button("HIDtoMidi sur GitHub") { NSWorkspace.shared.open(AppInfo.repoURL) }
                Button("Signaler un problème…") { NSWorkspace.shared.open(AppInfo.issuesURL) }
            }
        }
    }
}
