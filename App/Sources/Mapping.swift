import Foundation

// MARK: - Modèle d'une correspondance touche → message MIDI

enum MsgType: String, Codable, CaseIterable, Identifiable {
    case note, cc, pc, pcNext, pcPrev
    var id: String { rawValue }
    var label: String {
        switch self {
        case .note: return "Note"
        case .cc: return "Control Change"
        case .pc: return "Program Change"
        case .pcNext: return "Program +1"
        case .pcPrev: return "Program −1"
        }
    }
}

enum KeyMode: String, Codable, CaseIterable, Identifiable {
    case momentary   // appui = on, relâchement = off
    case toggle      // chaque appui alterne on / off
    case trigger     // appui seulement
    var id: String { rawValue }
    var label: String {
        switch self {
        case .momentary: return "Maintenu"
        case .toggle: return "Bascule"
        case .trigger: return "Impulsion"
        }
    }
}

struct Mapping: Identifiable, Codable, Equatable {
    var id = UUID()
    var page: Int = 0          // page d'usage HID (7 = clavier, 12 = multimédia). 0 = touche non assignée
    var usage: Int = 0
    var type: MsgType = .note
    var channel: Int = 1       // 1…16
    var number: Int = 60       // note, n° de CC ou n° de programme
    var value: Int = 100       // vélocité ou valeur CC « on »
    var valueOff: Int = 0      // valeur CC « off »
    var mode: KeyMode = .momentary

    var key: Int { (page << 16) | usage }
    var isAssigned: Bool { page != 0 }

    var realtime: RTMapping {
        func c(_ v: Int, _ lo: Int = 0) -> UInt8 { UInt8(max(lo, min(127, v))) }
        return RTMapping(id: id, type: type,
                         ch: UInt8(max(1, min(16, channel)) - 1),
                         num: c(number),
                         on: type == .note ? c(value, 1) : c(value),   // vélocité 0 = note off
                         off: c(valueOff),
                         mode: mode)
    }
}

/// Version figée et pré-calculée d'un mapping, utilisée sur le thread temps réel.
struct RTMapping {
    let id: UUID
    let type: MsgType
    let ch: UInt8
    let num: UInt8
    let on: UInt8
    let off: UInt8
    let mode: KeyMode
}

enum NoteName {
    private static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    /// Convention C3 = 60 (Logic, Ableton, Cubase).
    static func of(_ n: Int) -> String {
        guard (0...127).contains(n) else { return "" }
        return "\(names[n % 12])\(n / 12 - 2)"
    }
}

// MARK: - Noms des touches

enum KeyNames {
    /// Page 7 (clavier). Les noms correspondent à la POSITION sur un clavier QWERTY US.
    private static let keyboard: [Int: String] = {
        var t: [Int: String] = [:]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { t[0x04 + i] = String(c) }
        for (i, c) in "1234567890".enumerated() { t[0x1E + i] = String(c) }
        let named: [(Int, String)] = [
            (0x28, "Entrée"), (0x29, "Échap"), (0x2A, "Retour arrière"), (0x2B, "Tab"), (0x2C, "Espace"),
            (0x2D, "-"), (0x2E, "="), (0x2F, "["), (0x30, "]"), (0x31, "\\"), (0x32, "# (non-US)"),
            (0x33, ";"), (0x34, "'"), (0x35, "`"), (0x36, ","), (0x37, "."), (0x38, "/"),
            (0x39, "Verr. Maj"), (0x46, "Impr. écran"), (0x47, "Arrêt défil."), (0x48, "Pause"),
            (0x49, "Insert"), (0x4A, "Début"), (0x4B, "Page ↑"), (0x4C, "Suppr ⌦"), (0x4D, "Fin"),
            (0x4E, "Page ↓"), (0x4F, "→"), (0x50, "←"), (0x51, "↓"), (0x52, "↑"),
            (0x53, "Verr. Num"), (0x54, "Pavé /"), (0x55, "Pavé *"), (0x56, "Pavé -"), (0x57, "Pavé +"),
            (0x58, "Pavé Entrée"), (0x63, "Pavé ."), (0x64, "< > (ISO)"), (0x65, "Menu"), (0x67, "Pavé ="),
            (0xE0, "Ctrl gauche"), (0xE1, "Maj gauche"), (0xE2, "Alt gauche"), (0xE3, "⌘ gauche"),
            (0xE4, "Ctrl droit"), (0xE5, "Maj droit"), (0xE6, "Alt droit"), (0xE7, "⌘ droit"),
        ]
        for (u, n) in named { t[u] = n }
        for i in 1...12 { t[0x3A + i - 1] = "F\(i)" }
        for i in 13...24 { t[0x68 + i - 13] = "F\(i)" }
        for i in 1...9 { t[0x59 + i - 1] = "Pavé \(i)" }
        t[0x62] = "Pavé 0"
        return t
    }()

    /// Page 12 (Consumer : touches multimédia, télécommandes).
    private static let consumer: [Int: String] = [
        0xB0: "▶ Lecture", 0xB1: "Pause", 0xB5: "⏭ Suivant", 0xB6: "⏮ Précédent", 0xB7: "⏹ Stop",
        0xB3: "Avance rapide", 0xB4: "Retour rapide", 0xCD: "⏯ Lecture/Pause", 0xE2: "Muet",
        0xE9: "Volume +", 0xEA: "Volume −", 0x6F: "Luminosité +", 0x70: "Luminosité −",
        0x40: "Menu", 0x223: "Accueil", 0x224: "Retour", 0x221: "Recherche", 0xB8: "Éjecter",
    ]

    static func label(page: Int, usage: Int) -> String {
        switch page {
        case 0: return "— non assignée —"
        case 7: return keyboard[usage] ?? String(format: "Touche 0x%02X", usage)
        case 12: return consumer[usage] ?? String(format: "Multimédia 0x%02X", usage)
        default: return String(format: "Page %d / 0x%02X", page, usage)
        }
    }

    static func label(key: Int) -> String { label(page: key >> 16, usage: key & 0xFFFF) }
}
