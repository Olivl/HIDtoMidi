import SwiftUI

private enum Col {
    static let key: CGFloat = 170
    static let type: CGFloat = 150
    static let channel: CGFloat = 64
    static let number: CGFloat = 110
    static let value: CGFloat = 64
    static let off: CGFloat = 64
    static let mode: CGFloat = 110
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.accessGranted { permissionBanner }
            if model.status == .connected(.needsAccessibility) { accessibilityBanner }
            if let e = model.midiError { Label(e, systemImage: "exclamationmark.triangle").foregroundColor(.red) }

            GroupBox { deviceSection.padding(6) }
            GroupBox { midiSection.padding(6) }

            mappingHeader
            mappingList
            toolbar
            Divider()
            HStack {
                Text("Dernière touche : ").foregroundColor(.secondary) + Text(model.lastKey).bold()
                Spacer()
                Text("Noms de touches selon la position QWERTY · Notes : C3 = 60")
                    .font(.caption).foregroundColor(.secondary)
                Text("·").font(.caption).foregroundColor(.secondary)
                Text("v\(AppInfo.version)").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 520)
        .onExitCommand { model.cancelLearn() }
    }

    // MARK: Sections

    private var permissionBanner: some View {
        HStack {
            Image(systemName: "lock.shield").foregroundColor(.orange)
            Text("HIDtoMidi doit être autorisé dans Réglages Système → Confidentialité et sécurité → **Surveillance de l'entrée**. Relancez l'app après l'avoir autorisée.")
            Spacer()
            Button("Ouvrir les Réglages") { model.openPrivacySettings() }
            Button("Réessayer") { model.retry() }
        }
        .padding(10)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(8)
    }

    private var accessibilityBanner: some View {
        HStack {
            Image(systemName: "hand.raised").foregroundColor(.orange)
            Text("Pour que les touches de ce clavier ne tapent plus rien ailleurs, autorisez HIDtoMidi dans Réglages Système → Confidentialité et sécurité → **Accessibilité**. Le blocage s'active tout seul dès que c'est fait.")
            Spacer()
            Button("Ouvrir les Réglages") { model.openAccessibilitySettings() }
        }
        .padding(10)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(8)
    }

    private var deviceSection: some View {
        HStack(spacing: 12) {
            Text("Clavier :").bold()
            Picker("", selection: $model.deviceKey) {
                Text("— Choisir un appareil —").tag(String?.none)
                ForEach(model.pickerDevices) { d in Text(d.label).tag(Optional(d.id)) }
            }
            .labelsHidden()
            .frame(width: 340)

            Toggle("Mode exclusif", isOn: $model.exclusive)
                .help("Les touches de ce clavier ne sont plus envoyées aux autres applications (elles ne produisent que du MIDI).")
            Spacer()
            statusView
        }
    }

    private var statusView: some View {
        let (color, text): (Color, String) = {
            switch model.status {
            case .noDevice: return (.gray, "Aucun appareil choisi")
            case .waiting: return (.orange, "En attente de l'appareil…")
            case .failed(let msg): return (.red, msg)
            case .connected(.seized): return (.green, "Connecté (exclusif)")
            case .connected(.filtered): return (.green, "Connecté (exclusif par filtre)")
            case .connected(.needsAccessibility): return (.yellow, "Connecté — autorisation Accessibilité requise pour l'exclusif")
            case .connected(.off): return (.green, "Connecté (partagé)")
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text).lineLimit(2).frame(maxWidth: 260, alignment: .leading)
        }
    }

    private var midiSection: some View {
        HStack(spacing: 12) {
            Text("Sortie MIDI :").bold()
            Text("port virtuel « \(MIDIOut.portName) »")
            Text("+ envoyer aussi vers").foregroundColor(.secondary)
            Picker("", selection: $model.destinationUID) {
                Text("Aucune").tag(Int32?.none)
                ForEach(model.destinations) { d in Text(d.name).tag(Optional(d.id)) }
            }
            .labelsHidden()
            .frame(width: 220)
            Spacer()
            Group {
                if model.panicDone {
                    Button { model.panic() } label: { Label("Panic", systemImage: "speaker.slash") }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                } else {
                    Button { model.panic() } label: { Label("Panic", systemImage: "speaker.slash") }
                        .buttonStyle(.bordered)
                }
            }
            .help("En cas de note bloquée : relâche la pédale de sustain et coupe toutes les notes et tous les sons sur les 16 canaux.")
        }
    }

    private var mappingHeader: some View {
        HStack(spacing: 8) {
            Text("Touche").frame(width: Col.key, alignment: .leading)
            Text("Message").frame(width: Col.type, alignment: .leading)
            Text("Canal").frame(width: Col.channel, alignment: .leading)
            Text("N° / Prog.").frame(width: Col.number, alignment: .leading)
            Text("Valeur").frame(width: Col.value, alignment: .leading)
            Text("Off").frame(width: Col.off, alignment: .leading)
            Text("Mode").frame(width: Col.mode, alignment: .leading)
        }
        .font(.caption.bold())
        .foregroundColor(.secondary)
        .padding(.leading, 8)
    }

    private var mappingList: some View {
        List {
            if model.mappings.isEmpty {
                Text("Aucune touche configurée. Choisissez le clavier ci-dessus, cliquez sur « Ajouter par appui » puis appuyez sur une touche.")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach($model.mappings) { $m in
                MappingRow(m: $m,
                           learning: model.learningID == m.id,
                           active: m.isAssigned && model.activeKeys.contains(m.key),
                           onLearn: { model.learn(m.id) },
                           onDelete: { model.delete(m.id) })
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var toolbar: some View {
        HStack {
            let waitingNew = model.learningID == AppModel.newRowID
            Button {
                model.learn(AppModel.newRowID)
            } label: {
                Label(waitingNew ? "Appuyez sur une touche… (Échap pour annuler)" : "Ajouter par appui",
                      systemImage: "keyboard")
            }
            .tint(waitingNew ? .orange : nil)
            .buttonStyle(.borderedProminent)

            Button { model.addEmpty() } label: { Label("Ajouter une ligne", systemImage: "plus") }
            Spacer()
            Button("Importer…") { model.importMappings() }
            Button("Exporter…") { model.exportMappings() }
        }
    }
}

struct MappingRow: View {
    @Binding var m: Mapping
    let learning: Bool
    let active: Bool
    let onLearn: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onLearn) {
                HStack {
                    Image(systemName: learning ? "ear" : "keyboard")
                    Text(learning ? "Appuyez sur une touche…" : KeyNames.label(page: m.page, usage: m.usage))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(width: Col.key - 20)
            }
            .foregroundColor(learning ? .orange : (m.isAssigned ? .primary : .secondary))
            .help("Cliquez puis appuyez sur la touche du clavier choisi pour l'attribuer")
            .frame(width: Col.key, alignment: .leading)

            Picker("", selection: $m.type) {
                ForEach(MsgType.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: Col.type)

            Picker("", selection: $m.channel) {
                ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
            }
            .labelsHidden().frame(width: Col.channel)

            Group {
                switch m.type {
                case .note:
                    HStack(spacing: 4) {
                        field($m.number)
                        Text(NoteName.of(m.number)).font(.caption).foregroundColor(.secondary)
                    }
                case .cc, .pc:
                    field($m.number)
                case .pcNext, .pcPrev:
                    Text("—").foregroundColor(.secondary)
                }
            }
            .frame(width: Col.number, alignment: .leading)

            Group {
                if m.type == .note || m.type == .cc { field($m.value) } else { Text("—").foregroundColor(.secondary) }
            }
            .frame(width: Col.value, alignment: .leading)
            .help(m.type == .note ? "Vélocité" : "Valeur envoyée à l'appui")

            Group {
                if m.type == .cc && m.mode != .trigger { field($m.valueOff) } else { Text("—").foregroundColor(.secondary) }
            }
            .frame(width: Col.off, alignment: .leading)
            .help("Valeur CC envoyée au relâchement (ou 2ᵉ appui en mode Bascule)")

            Group {
                if m.type == .note || m.type == .cc {
                    Picker("", selection: $m.mode) {
                        ForEach(KeyMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                } else {
                    Text("à l'appui").foregroundColor(.secondary)
                }
            }
            .frame(width: Col.mode, alignment: .leading)

            Spacer()
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Supprimer")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(active ? Color.accentColor.opacity(0.35) : .clear))
    }

    private func field(_ b: Binding<Int>) -> some View {
        TextField("", value: Binding(get: { b.wrappedValue },
                                     set: { b.wrappedValue = max(0, min(127, $0)) }),
                  format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 52)
    }
}
