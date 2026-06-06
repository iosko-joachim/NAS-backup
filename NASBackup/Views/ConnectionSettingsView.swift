import SwiftUI

struct ConnectionSettingsView: View {
    @Bindable var settings: SettingsStore

    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false
    @State private var showFolderPicker = false

    var body: some View {
        Form {
            Section("NAS") {
                LabeledField(label: "IP / Host", text: $settings.config.host, keyboard: .URL)
                LabeledField(label: "Freigabe", text: $settings.config.share)
                LabeledField(label: "Zielordner", text: $settings.config.targetSubpath, placeholder: "z. B. IP13 (leer = Wurzel)")
                Button {
                    showFolderPicker = true
                } label: {
                    Label("Auf dem NAS auswählen …", systemImage: "folder.badge.gearshape")
                }
                .disabled(!settings.config.isComplete)
            }

            Section("Anmeldung") {
                LabeledField(label: "Benutzer", text: $settings.config.username, placeholder: "leer = guest")
                HStack {
                    Text("Passwort").frame(width: 90, alignment: .leading)
                    SecureField("Passwort", text: $settings.password)
                }
            }

            Section("Optionen") {
                Toggle("SMB-Verschlüsselung erzwingen", isOn: $settings.config.encrypted)
                Toggle("Datum an Zielordner anhängen (_JJMMTT)", isOn: $settings.config.appendDateSuffix)
                Toggle("Strenger Zeitvergleich (auch bei neuerer Datei kopieren)", isOn: $settings.config.strictTimeCheck)
            }

            Section {
                Button {
                    runTest()
                } label: {
                    HStack {
                        if testing { ProgressView().padding(.trailing, 4) }
                        Text(testing ? "Teste Verbindung …" : "Verbindung testen")
                    }
                }
                .disabled(testing || !settings.config.isComplete)

                if let testResult {
                    Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(testOK ? .green : .red)
                        .font(.footnote)
                }
            } footer: {
                Text("Beim ersten Verbindungsversuch fragt iOS nach der Berechtigung für das lokale Netzwerk – bitte erlauben.")
            }
        }
        .navigationTitle("Verbindung")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showFolderPicker) {
            SMBFolderPickerView(
                config: settings.config,
                password: settings.password,
                selectedPath: $settings.config.targetSubpath
            )
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        LocalNetwork.requestPermission()   // Local-Network-Dialog ggf. auslösen
        let session = SMBSession(config: settings.config, password: settings.password)
        Task {
            // Pre-Flight: erst Netzweg/Berechtigung prüfen (klare Diagnose statt „Error 1").
            let pre = await Preflight.probe(host: settings.config.host)
            Log.write("Verbindungstest Pre-Flight: \(pre) — \(pre.message)")
            if !pre.isOK {
                testOK = false
                testResult = pre.message
                testing = false
                return
            }
            do {
                try await session.test()
                await session.disconnect()
                testOK = true
                testResult = "Verbindung erfolgreich."
                Log.write("Verbindungstest OK: \(settings.config.host)/\(settings.config.share) Benutzer=\(settings.config.username.isEmpty ? "(guest)" : settings.config.username)")
            } catch {
                testOK = false
                let ns = error as NSError
                var parts = ["\(ns.domain) \(ns.code)", ns.localizedDescription]
                if let d = ns.userInfo[NSLocalizedDescriptionKey] as? String, d != ns.localizedDescription {
                    parts.append(d)
                }
                if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                    parts.append("↳ \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)")
                }
                testResult = parts.joined(separator: "\n")
                Log.write("Verbindungstest FEHLER: \(parts.joined(separator: " | "))")
            }
            testing = false
        }
    }
}

/// Einheitliches Label+TextField-Paar.
private struct LabeledField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var keyboard: UIKeyboardType = .default

    var body: some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            TextField(placeholder.isEmpty ? label : placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
        }
    }
}
