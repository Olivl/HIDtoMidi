import CoreMIDI
import Foundation

struct MIDIDest: Identifiable, Hashable {
    let id: MIDIUniqueID
    let name: String
}

/// Sortie MIDI : un port virtuel « HIDtoMidi » (visible par toutes les applis),
/// plus, en option, un envoi direct vers une destination existante (IAC, interface USB…).
///
/// `send` et `setDestination` ne doivent être appelés QUE depuis le thread HID.
final class MIDIOut {
    static let portName = "HIDtoMidi"

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var outPort = MIDIPortRef()
    private var destination = MIDIEndpointRef()
    private(set) var error: String?

    /// `onSetupChanged` est appelé sur le thread principal quand la liste des ports MIDI change.
    init(onSetupChanged: @escaping () -> Void) {
        var st = MIDIClientCreateWithBlock("HIDtoMidi" as CFString, &client) { notif in
            if notif.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async(execute: onSetupChanged)
            }
        }
        guard st == noErr else { error = "Client MIDI impossible à créer (\(st))"; return }

        st = MIDISourceCreateWithProtocol(client, MIDIOut.portName as CFString, ._1_0, &source)
        guard st == noErr else { error = "Port MIDI virtuel impossible à créer (\(st))"; return }
        // Identifiant fixe : les logiciels (DAW…) retrouvent le port d'une session à l'autre.
        MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, 0x4849_4D31)

        st = MIDIOutputPortCreate(client, "HIDtoMidi out" as CFString, &outPort)
        if st != noErr { error = "Port de sortie MIDI impossible à créer (\(st))" }
    }

    /// Envoie un message MIDI 1.0 (status, data1, data2). Chemin critique : aucune allocation.
    @inline(__always)
    func send(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
        // Paquet UMP « MIDI 1.0 Channel Voice » (type 2, groupe 0), horodatage 0 = immédiat
        var word: UInt32 = (0x2 << 28) | (UInt32(status) << 16) | (UInt32(d1 & 0x7F) << 8) | UInt32(d2 & 0x7F)
        var list = MIDIEventList()
        withUnsafeMutablePointer(to: &list) { lp in
            let pkt = MIDIEventListInit(lp, ._1_0)
            _ = MIDIEventListAdd(lp, MemoryLayout<MIDIEventList>.size, pkt, 0, 1, &word)
            MIDIReceivedEventList(source, lp)
            if destination != 0 { MIDISendEventList(outPort, destination, lp) }
        }
    }

    func setDestination(_ uid: MIDIUniqueID?) {
        destination = 0
        guard let uid else { return }
        var obj = MIDIObjectRef()
        var type = MIDIObjectType.other
        if MIDIObjectFindByUniqueID(uid, &obj, &type) == noErr, type == .destination {
            destination = obj
        }
    }

    static func destinations() -> [MIDIDest] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { i in
            let e = MIDIGetDestination(i)
            var uid: Int32 = 0
            guard MIDIObjectGetIntegerProperty(e, kMIDIPropertyUniqueID, &uid) == noErr else { return nil }
            return MIDIDest(id: uid, name: displayName(e))
        }
    }

    static func displayName(_ obj: MIDIObjectRef) -> String {
        var s: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(obj, kMIDIPropertyDisplayName, &s) == noErr, let v = s?.takeRetainedValue() {
            return v as String
        }
        return "?"
    }
}
