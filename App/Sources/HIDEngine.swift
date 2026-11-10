import Foundation
import IOKit.hid
import CoreMIDI

struct DeviceInfo: Identifiable, Hashable {
    let id: String          // clé stable : vendor:product:(n° de série ou nom)
    let name: String
    let transport: String
    let builtIn: Bool

    var label: String {
        var s = name
        if !transport.isEmpty { s += " — \(transport)" }
        if builtIn { s += " (intégré)" }
        return s
    }
}

enum ExclusiveState: Equatable {
    case off                  // partagé : les touches vont aussi aux applications
    case seized               // capture exclusive IOKit (rarement permise hors root)
    case filtered             // capture refusée → les frappes sont bloquées par KeyFilter
    case needsAccessibility   // capture refusée et KeyFilter pas encore autorisé
}

enum EngineStatus: Equatable {
    case noDevice
    case waiting
    case connected(ExclusiveState)
    case failed(String)
}

/// Lecture HID + conversion MIDI.
///
/// Tout ce qui touche au HID et à l'état de conversion vit sur UN thread dédié
/// (priorité « userInteractive ») avec sa propre run loop : le callback IOKit appelle
/// directement CoreMIDI, sans passer par le thread principal ni par aucun verrou.
/// L'interface communique avec ce thread via `perform`.
final class HIDEngine {
    // Callbacks vers l'interface (appelés sur le thread principal)
    var onDevices: (([DeviceInfo]) -> Void)?
    var onStatus: ((EngineStatus) -> Void)?
    var onKey: ((Int, Bool) -> Void)?
    var onLearned: ((Int) -> Void)?

    private let midi: MIDIOut
    private let filter = KeyFilter()
    private var filterOn = false
    private var runLoop: CFRunLoop!
    private var manager: IOHIDManager!

    // --- État du thread HID uniquement ---
    private var devices: [IOHIDDevice] = []
    private var opened: [(device: IOHIDDevice, exclusive: Bool, refused: Bool)] = []
    private var openError: String?
    private var selected: String?
    private var exclusive = true

    private var table: [Int: [RTMapping]] = [:]
    private var pressed = Set<Int>()
    private var ignoreRelease = Set<Int>()
    private var held: [Int: [UInt16]] = [:]                       // touche → notes tenues (canal<<8 | note)
    private var toggled: [UUID: (isNote: Bool, code: UInt16)] = [:]
    private var program = [Int](repeating: 0, count: 16)
    private var learning = false

    init(midi: MIDIOut) { self.midi = midi }

    func start() {
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            self.setupManager()
            ready.signal()
            let keepAlive = Timer(timeInterval: 1e9, repeats: true) { _ in }
            RunLoop.current.add(keepAlive, forMode: .default)
            while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        filter.onChange = { [unowned self] in self.perform { self.publishStatus() } }
        t.name = "HIDtoMidi.hid"
        t.qualityOfService = .userInteractive
        t.start()
        ready.wait()
    }

    // MARK: - API (depuis le thread principal)

    func select(_ key: String?, exclusive: Bool) {
        perform { self.selected = key; self.exclusive = exclusive; self.reopen() }
    }
    func setTable(_ t: [Int: [RTMapping]]) { perform { self.table = t } }
    func setLearning(_ on: Bool) { perform { self.learning = on } }
    func setDestination(_ uid: MIDIUniqueID?) { perform { self.midi.setDestination(uid) } }
    func panic() { perform { self.allOff(panic: true) } }

    /// Coupe les notes et ferme proprement (appelé à la fermeture de l'app).
    func shutdown() {
        let done = DispatchSemaphore(value: 0)
        perform { self.closeAll(); done.signal() }
        _ = done.wait(timeout: .now() + 0.5)
    }

    private func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func toMain(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }

    // MARK: - Périphériques

    private func setupManager() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer, kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, d in
            Unmanaged<HIDEngine>.fromOpaque(ctx!).takeUnretainedValue().added(d)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, d in
            Unmanaged<HIDEngine>.fromOpaque(ctx!).takeUnretainedValue().removed(d)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }

    static func prop(_ d: IOHIDDevice, _ key: String) -> Any? { IOHIDDeviceGetProperty(d, key as CFString) }

    static func key(of d: IOHIDDevice) -> String {
        let vid = prop(d, kIOHIDVendorIDKey) as? Int ?? 0
        let pid = prop(d, kIOHIDProductIDKey) as? Int ?? 0
        let serial = prop(d, kIOHIDSerialNumberKey) as? String ?? ""
        let name = prop(d, kIOHIDProductKey) as? String ?? ""
        return "\(vid):\(pid):\(serial.isEmpty ? name : serial)"
    }

    static func info(of d: IOHIDDevice) -> DeviceInfo {
        DeviceInfo(id: key(of: d),
                   name: prop(d, kIOHIDProductKey) as? String ?? "Périphérique sans nom",
                   transport: prop(d, kIOHIDTransportKey) as? String ?? "",
                   builtIn: prop(d, kIOHIDBuiltInKey) as? Bool ?? false)
    }

    private func added(_ d: IOHIDDevice) {
        guard !devices.contains(where: { $0 === d }) else { return }
        devices.append(d)
        publishDevices()
        if HIDEngine.key(of: d) == selected { open(d); publishStatus() }
    }

    private func removed(_ d: IOHIDDevice) {
        devices.removeAll { $0 === d }
        if let i = opened.firstIndex(where: { $0.device === d }) {
            opened.remove(at: i)
            if opened.isEmpty { allOff(panic: false); pressed.removeAll() }
        }
        publishDevices()
        publishStatus()
    }

    private func publishDevices() {
        var seen = Set<String>()
        var list: [DeviceInfo] = []
        for d in devices {
            let i = HIDEngine.info(of: d)
            if seen.insert(i.id).inserted { list.append(i) }
        }
        list.sort { ($0.builtIn ? 1 : 0, $0.name) < ($1.builtIn ? 1 : 0, $1.name) }
        let cb = onDevices
        toMain { cb?(list) }
    }

    private func publishStatus() {
        let s: EngineStatus
        var needFilter = false
        if selected == nil { s = .noDevice }
        else if opened.isEmpty { s = openError.map { .failed($0) } ?? .waiting }
        else if opened.contains(where: { $0.refused }) {
            needFilter = true
            s = .connected(filter.isRunning ? .filtered : .needsAccessibility)
        }
        else { s = .connected(opened.allSatisfy { $0.exclusive } ? .seized : .off) }
        filterOn = needFilter
        filter.setEnabled(needFilter)
        let cb = onStatus
        toMain { cb?(s) }
    }

    private func reopen() {
        closeAll()
        openError = nil
        if let sel = selected {
            for d in devices where HIDEngine.key(of: d) == sel { open(d) }
        }
        publishStatus()
    }

    private func open(_ d: IOHIDDevice) {
        guard !opened.contains(where: { $0.device === d }) else { return }
        // Sécurité : on ne capture jamais en exclusif le clavier intégré du Mac.
        let builtIn = HIDEngine.prop(d, kIOHIDBuiltInKey) as? Bool ?? false
        let wantSeize = exclusive && !builtIn
        var r = IOHIDDeviceOpen(d, IOOptionBits(wantSeize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone))
        var seized = wantSeize
        var refused = false
        if r != kIOReturnSuccess && wantSeize {
            seized = false
            refused = true
            r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard r == kIOReturnSuccess else {
            openError = r == kIOReturnNotPermitted
                ? "Accès refusé : autorisez HIDtoMidi dans « Surveillance de l'entrée »"
                : String(format: "Ouverture impossible (0x%08X)", UInt32(bitPattern: r))
            return
        }
        openError = nil
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(d, { ctx, _, _, value in
            Unmanaged<HIDEngine>.fromOpaque(ctx!).takeUnretainedValue().input(value)
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(d, runLoop, CFRunLoopMode.defaultMode.rawValue)
        opened.append((d, seized, refused))
    }

    private func closeAll() {
        allOff(panic: false)
        for o in opened {
            IOHIDDeviceRegisterInputValueCallback(o.device, nil, nil)
            IOHIDDeviceClose(o.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        opened.removeAll()
        pressed.removeAll()
        ignoreRelease.removeAll()
    }

    // MARK: - Chemin temps réel

    private func input(_ value: IOHIDValue) {
        let el = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(el))
        let usage = Int(IOHIDElementGetUsage(el))
        switch page {
        case kHIDPage_KeyboardOrKeypad:
            guard (0x04...0xE7).contains(usage) else { return }   // ignore ErrorRollOver & co
        case kHIDPage_Consumer:
            guard usage > 0 && usage < 0xFFFF else { return }
        default:
            return
        }
        let down = IOHIDValueGetIntegerValue(value) != 0
        let key = (page << 16) | usage
        if down {
            guard pressed.insert(key).inserted else { return }
        } else {
            guard pressed.remove(key) != nil else { return }
            if ignoreRelease.remove(key) != nil {
                if filterOn { filter.hid(key, false) }
                notifyKey(key, false)
                return
            }
        }

        if learning {
            if filterOn { filter.hid(key, down) }
            if down {
                learning = false
                ignoreRelease.insert(key)
                let cb = onLearned
                toMain { cb?(key) }
            }
            return
        }

        if let list = table[key] {
            for m in list { fire(m, key: key, down: down) }
        }
        if !down, let notes = held.removeValue(forKey: key) {
            for c in notes { midi.send(0x80 | UInt8(c >> 8), UInt8(c & 0x7F), 0) }
        }
        if filterOn { filter.hid(key, down) }   // après l'envoi MIDI : le filtre ne retarde pas le MIDI
        notifyKey(key, down)   // après l'envoi MIDI : l'interface ne retarde rien
    }

    private func notifyKey(_ key: Int, _ down: Bool) {
        let cb = onKey
        toMain { cb?(key, down) }
    }

    @inline(__always)
    private func fire(_ m: RTMapping, key: Int, down: Bool) {
        let code = UInt16(m.ch) << 8 | UInt16(m.num)
        switch m.type {
        case .note:
            guard down else { return }      // les note off des notes maintenues sont gérées via `held`
            switch m.mode {
            case .momentary:
                midi.send(0x90 | m.ch, m.num, m.on)
                held[key, default: []].append(code)
            case .trigger:
                midi.send(0x90 | m.ch, m.num, m.on)
                midi.send(0x80 | m.ch, m.num, 0)
            case .toggle:
                if let t = toggled.removeValue(forKey: m.id) {
                    midi.send(0x80 | UInt8(t.code >> 8), UInt8(t.code & 0x7F), 0)
                } else {
                    midi.send(0x90 | m.ch, m.num, m.on)
                    toggled[m.id] = (true, code)
                }
            }
        case .cc:
            switch m.mode {
            case .momentary:
                midi.send(0xB0 | m.ch, m.num, down ? m.on : m.off)
            case .trigger:
                if down { midi.send(0xB0 | m.ch, m.num, m.on) }
            case .toggle:
                guard down else { return }
                if toggled.removeValue(forKey: m.id) != nil {
                    midi.send(0xB0 | m.ch, m.num, m.off)
                } else {
                    midi.send(0xB0 | m.ch, m.num, m.on)
                    toggled[m.id] = (false, code)
                }
            }
        case .pc:
            guard down else { return }
            program[Int(m.ch)] = Int(m.num)
            midi.send(0xC0 | m.ch, m.num, 0)
        case .pcNext, .pcPrev:
            guard down else { return }
            let ch = Int(m.ch)
            program[ch] = max(0, min(127, program[ch] + (m.type == .pcNext ? 1 : -1)))
            midi.send(0xC0 | m.ch, UInt8(program[ch]), 0)
        }
    }

    /// Relâche toutes les notes tenues. `panic` : envoie aussi « All Notes Off » sur les 16 canaux.
    private func allOff(panic: Bool) {
        for (_, notes) in held {
            for c in notes { midi.send(0x80 | UInt8(c >> 8), UInt8(c & 0x7F), 0) }
        }
        held.removeAll()
        for (id, t) in toggled where t.isNote {
            midi.send(0x80 | UInt8(t.code >> 8), UInt8(t.code & 0x7F), 0)
            toggled.removeValue(forKey: id)
        }
        if panic {
            toggled.removeAll()                  // les bascules CC repartent à « off »
            for ch in 0..<16 {
                let s = 0xB0 | UInt8(ch)
                midi.send(s, 64, 0)              // pédale de sustain relâchée
                midi.send(s, 120, 0)             // All Sound Off
                midi.send(s, 123, 0)             // All Notes Off
            }
        }
    }
}
