import AppKit
import CoreMIDI
import IOKit.hid
import SwiftUI
import UniformTypeIdentifiers

struct SavedSettings: Codable {
    var deviceKey: String?
    var deviceName: String?
    var exclusive: Bool = true
    var destinationUID: Int32?
    var mappings: [Mapping] = []
}

final class AppModel: ObservableObject {
    static let shared = AppModel()
    /// Identifiant spécial : « créer une nouvelle ligne avec la prochaine touche pressée ».
    static let newRowID = UUID()
    private static let defaultsKey = "settings.v1"

    @Published var devices: [DeviceInfo] = []
    @Published var deviceKey: String? {
        didSet {
            guard oldValue != deviceKey else { return }
            if let d = devices.first(where: { $0.id == deviceKey }) { deviceName = d.label }
            applySelection(); save()
        }
    }
    @Published private(set) var deviceName: String?
    @Published var exclusive: Bool { didSet { applySelection(); save() } }
    @Published var destinations: [MIDIDest] = []
    @Published var destinationUID: Int32? { didSet { engine.setDestination(destinationUID); save() } }
    @Published var mappings: [Mapping] { didSet { pushTable(); save() } }

    @Published var status: EngineStatus = .noDevice
    @Published var learningID: UUID?
    @Published var activeKeys = Set<Int>()
    @Published var lastKey = "—"
    @Published var accessGranted = true
    let midiError: String?

    private let midi: MIDIOut
    private let engine: HIDEngine
    private var activity: NSObjectProtocol?

    private init() {
        let saved = (UserDefaults.standard.data(forKey: AppModel.defaultsKey))
            .flatMap { try? JSONDecoder().decode(SavedSettings.self, from: $0) } ?? SavedSettings()
        deviceKey = saved.deviceKey
        deviceName = saved.deviceName
        exclusive = saved.exclusive
        destinationUID = saved.destinationUID
        mappings = saved.mappings

        var refresh: () -> Void = {}
        midi = MIDIOut(onSetupChanged: { refresh() })
        midiError = midi.error
        engine = HIDEngine(midi: midi)
        refresh = { [weak self] in self?.refreshDestinations() }

        engine.onDevices = { [weak self] list in self?.devices = list }
        engine.onStatus = { [weak self] s in self?.status = s }
        engine.onKey = { [weak self] key, down in self?.keyEvent(key, down) }
        engine.onLearned = { [weak self] key in self?.learned(key) }

        // Empêche macOS (App Nap) de ralentir l'app quand elle est en arrière-plan.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Conversion HID → MIDI en temps réel")

        checkAccess(request: true)
        engine.start()
        refreshDestinations()
        pushTable()
        engine.setDestination(destinationUID)
        applySelection()
    }

    // MARK: - Périphérique / autorisations

    /// Liste pour le menu : inclut l'appareil mémorisé même s'il est absent (Bluetooth en veille).
    var pickerDevices: [DeviceInfo] {
        var list = devices
        if let k = deviceKey, !list.contains(where: { $0.id == k }) {
            list.insert(DeviceInfo(id: k, name: (deviceName ?? "Appareil mémorisé") + " (absent)",
                                   transport: "", builtIn: false), at: 0)
        }
        return list
    }

    func checkAccess(request: Bool) {
        accessGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if !accessGranted && request { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    }

    func retry() {
        checkAccess(request: false)
        applySelection()
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func applySelection() { engine.select(deviceKey, exclusive: exclusive) }

    private func refreshDestinations() {
        destinations = MIDIOut.destinations()
        engine.setDestination(destinationUID)   // l'interface a peut-être été rebranchée
    }

    // MARK: - Mappings

    private func pushTable() {
        var t: [Int: [RTMapping]] = [:]
        for m in mappings where m.isAssigned { t[m.key, default: []].append(m.realtime) }
        engine.setTable(t)
    }

    func addEmpty() {
        var m = Mapping()
        m.number = suggestedNote()
        mappings.append(m)
    }

    func delete(_ id: UUID) {
        if learningID == id { cancelLearn() }
        mappings.removeAll { $0.id == id }
    }

    func learn(_ id: UUID) {
        if learningID == id { cancelLearn(); return }
        learningID = id
        engine.setLearning(true)
    }

    func cancelLearn() {
        learningID = nil
        engine.setLearning(false)
    }

    private func learned(_ key: Int) {
        guard let id = learningID else { return }
        learningID = nil
        if id == AppModel.newRowID {
            var m = Mapping(page: key >> 16, usage: key & 0xFFFF)
            m.number = suggestedNote()
            mappings.append(m)
        } else if let i = mappings.firstIndex(where: { $0.id == id }) {
            mappings[i].page = key >> 16
            mappings[i].usage = key & 0xFFFF
        }
    }

    private func suggestedNote() -> Int {
        let notes = mappings.filter { $0.type == .note }.map(\.number)
        return min(127, (notes.max() ?? 59) + 1)
    }

    private func keyEvent(_ key: Int, _ down: Bool) {
        if down {
            activeKeys.insert(key)
            let mapped = mappings.contains { $0.isAssigned && $0.key == key }
            lastKey = KeyNames.label(key: key) + (mapped ? "" : "  (non assignée)")
        } else {
            activeKeys.remove(key)
        }
    }

    @Published var panicDone = false

    func panic() {
        engine.panic()
        panicDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.panicDone = false }
    }
    func shutdown() { engine.shutdown() }

    // MARK: - Sauvegarde / import / export

    private func save() {
        let s = SavedSettings(deviceKey: deviceKey, deviceName: deviceName, exclusive: exclusive,
                              destinationUID: destinationUID, mappings: mappings)
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: AppModel.defaultsKey)
        }
    }

    func exportMappings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "HIDtoMidi-mappings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(mappings).write(to: url) }
        catch { alert("Export impossible", error.localizedDescription) }
    }

    func importMappings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { mappings = try JSONDecoder().decode([Mapping].self, from: Data(contentsOf: url)) }
        catch { alert("Import impossible", "Fichier non reconnu : \(error.localizedDescription)") }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
