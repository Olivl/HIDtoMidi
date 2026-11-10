import AppKit
import ApplicationServices
import os

/// Mode exclusif « logiciel », utilisé quand macOS refuse de capturer le clavier
/// (la capture exclusive d'un clavier est réservée aux processus root).
///
/// Principe : chaque touche du clavier choisi arrive d'abord à HIDtoMidi en HID brut
/// (`hid(_:_:)`, appelé par le thread HID APRÈS l'envoi MIDI). La frappe correspondante
/// passe ensuite par le système d'événements de macOS, où un « event tap » la supprime.
/// Les frappes des autres claviers passent normalement.
///
/// Nécessite l'autorisation « Accessibilité ».
final class KeyFilter {
    /// Appelé (sur le thread du filtre) quand le filtre devient actif ou inactif.
    var onChange: (() -> Void)?

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    // --- Protégé par `lock` ---
    private var enabled = false
    private var running = false
    private var downUntil = [UInt64](repeating: 0, count: 512)
    private var upUntil = [UInt64](repeating: 0, count: 512)
    private var held = [Bool](repeating: false, count: 512)

    // --- Thread du filtre uniquement ---
    private var runLoop: CFRunLoop!
    private var tap: CFMachPort?
    private var prompted = false

    /// Durée pendant laquelle une touche HID « réserve » la frappe système correspondante.
    private static let window: UInt64 = 300_000_000          // 300 ms
    /// Attente max d'une frappe système arrivée avant son événement HID (cas rare).
    private static let maxWait: UInt64 = 3_000_000           // 3 ms

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            // Réessaie régulièrement de créer le filtre (autorisation donnée entre-temps).
            let retry = Timer(timeInterval: 2, repeats: true) { [unowned self] _ in self.tryCreateTap() }
            RunLoop.current.add(retry, forMode: .default)
            while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        t.name = "HIDtoMidi.filter"
        t.qualityOfService = .userInteractive
        t.start()
        ready.wait()
    }

    var isRunning: Bool {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return running
    }

    func setEnabled(_ on: Bool) {
        os_unfair_lock_lock(lock)
        let changed = enabled != on
        enabled = on
        if !on {
            for i in 0..<512 { downUntil[i] = 0; upUntil[i] = 0; held[i] = false }
        }
        let needTap = on && !running
        os_unfair_lock_unlock(lock)
        if changed && needTap {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { self.tryCreateTap() }
            CFRunLoopWakeUp(runLoop)
        }
    }

    /// Appelé par le thread HID pour chaque touche du clavier choisi.
    @inline(__always)
    func hid(_ key: Int, _ down: Bool) {
        guard let slot = KeyFilter.slot(forHID: key) else { return }
        let until = KeyFilter.now() + KeyFilter.window
        os_unfair_lock_lock(lock)
        if enabled {
            if down { downUntil[slot] = until; held[slot] = true }
            else { upUntil[slot] = until; held[slot] = false }
        }
        os_unfair_lock_unlock(lock)
    }

    // MARK: - Event tap

    private func tryCreateTap() {
        os_unfair_lock_lock(lock)
        let wanted = enabled
        os_unfair_lock_unlock(lock)
        guard wanted, tap == nil else { return }

        guard AXIsProcessTrusted() else {
            if !prompted {
                prompted = true
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
            }
            return
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue) | (1 << 14 /* NX_SYSDEFINED : touches multimédia */)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, ctx in
                                            Unmanaged<KeyFilter>.fromOpaque(ctx!).takeUnretainedValue().handle(type, event)
                                        }, userInfo: ctx)
        else { return }
        tap = t
        CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        os_unfair_lock_lock(lock); running = true; os_unfair_lock_unlock(lock)
        onChange?()
    }

    private enum Kind { case down, up, flags }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        let slot: Int
        let kind: Kind
        var isRepeat = false
        switch type {
        case .keyDown, .keyUp:
            slot = KeyFilter.normalize(Int(event.getIntegerValueField(.keyboardEventKeycode)))
            kind = type == .keyDown ? .down : .up
            isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        case .flagsChanged:
            slot = KeyFilter.normalize(Int(event.getIntegerValueField(.keyboardEventKeycode)))
            kind = .flags
        default:
            guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return pass }
            let d = ns.data1
            let state = (d & 0xFF00) >> 8
            guard state == 0x0A || state == 0x0B else { return pass }
            slot = 0x100 + ((d & 0xFFFF0000) >> 16)
            kind = state == 0x0A ? .down : .up
            isRepeat = d & 1 != 0
        }
        guard slot >= 0 && slot < 512 else { return pass }

        let deadline = KeyFilter.now() + KeyFilter.maxWait
        while true {
            os_unfair_lock_lock(lock)
            guard enabled else { os_unfair_lock_unlock(lock); return pass }
            let t = KeyFilter.now()
            var consume = false
            switch kind {
            case .down:
                if isRepeat && held[slot] { consume = true }
                else if downUntil[slot] >= t { downUntil[slot] = 0; consume = true }
            case .up:
                if upUntil[slot] >= t { upUntil[slot] = 0; consume = true }
            case .flags:
                if downUntil[slot] >= t { downUntil[slot] = 0; consume = true }
                else if upUntil[slot] >= t { upUntil[slot] = 0; consume = true }
            }
            os_unfair_lock_unlock(lock)
            if consume { return nil }
            if isRepeat || KeyFilter.now() >= deadline { return pass }
            usleep(200)
        }
    }

    @inline(__always)
    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    // MARK: - Correspondance HID → code de touche macOS

    /// Les touches ISO « < > » et « ` » sont permutées selon le type de clavier : on les confond.
    private static func normalize(_ kc: Int) -> Int { kc == 0x0A ? 0x32 : kc }

    static func slot(forHID key: Int) -> Int? {
        let page = key >> 16, usage = key & 0xFFFF
        switch page {
        case 7: return keyboard[usage]
        case 12: return consumer[usage].map { 0x100 + $0 }
        default: return nil
        }
    }

    /// Usage HID (page 7) → code virtuel macOS (kVK_*).
    private static let keyboard: [Int: Int] = {
        var t: [Int: Int] = [:]
        let letters = [0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                       0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06]
        for (i, kc) in letters.enumerated() { t[0x04 + i] = kc }
        let digits = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]   // 1…9, 0
        for (i, kc) in digits.enumerated() { t[0x1E + i] = kc }
        let fkeys = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]  // F1…F12
        for (i, kc) in fkeys.enumerated() { t[0x3A + i] = kc }
        let pad = [0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C]     // pavé 1…9
        for (i, kc) in pad.enumerated() { t[0x59 + i] = kc }
        let others: [(Int, Int)] = [
            (0x28, 0x24), (0x29, 0x35), (0x2A, 0x33), (0x2B, 0x30), (0x2C, 0x31), (0x2D, 0x1B),
            (0x2E, 0x18), (0x2F, 0x21), (0x30, 0x1E), (0x31, 0x2A), (0x32, 0x2A), (0x33, 0x29),
            (0x34, 0x27), (0x35, 0x32), (0x36, 0x2B), (0x37, 0x2F), (0x38, 0x2C), (0x39, 0x39),
            (0x46, 0x69), (0x47, 0x6B), (0x48, 0x71), (0x49, 0x72), (0x4A, 0x73), (0x4B, 0x74),
            (0x4C, 0x75), (0x4D, 0x77), (0x4E, 0x79), (0x4F, 0x7C), (0x50, 0x7B), (0x51, 0x7D),
            (0x52, 0x7E), (0x53, 0x47), (0x54, 0x4B), (0x55, 0x43), (0x56, 0x4E), (0x57, 0x45),
            (0x58, 0x4C), (0x62, 0x52), (0x63, 0x41), (0x64, 0x32), (0x65, 0x6E), (0x67, 0x51),
            (0x68, 0x69), (0x69, 0x6B), (0x6A, 0x71), (0x6B, 0x6A), (0x6C, 0x40), (0x6D, 0x4F),
            (0x6E, 0x50), (0x6F, 0x5A),
            (0xE0, 0x3B), (0xE1, 0x38), (0xE2, 0x3A), (0xE3, 0x37),
            (0xE4, 0x3E), (0xE5, 0x3C), (0xE6, 0x3D), (0xE7, 0x36),
        ]
        for (u, kc) in others { t[u] = kc }
        return t
    }()

    /// Usage HID Consumer (page 12) → code NX_KEYTYPE_* des touches multimédia.
    private static let consumer: [Int: Int] = [
        0xE9: 0, 0xEA: 1, 0x6F: 2, 0x70: 3, 0xE2: 7, 0xB8: 14,
        0xCD: 16, 0xB0: 16, 0xB5: 17, 0xB6: 18, 0xB3: 19, 0xB4: 20,
    ]
}
