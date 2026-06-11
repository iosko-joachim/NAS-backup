import SwiftUI
import UniformTypeIdentifiers

struct ConnectionSettingsView: View {
    @Bindable var settings: SettingsStore

    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false
    @State private var showFolderPicker = false
    @State private var showDiagnostics = false
    @State private var showSysImporter = false
    @State private var sysResult: String?
    @State private var sysOK = false

    var body: some View {
        Form {
            Section {
                Picker("Protokoll", selection: $settings.config.proto) {
                    ForEach(TransferProtocol.allCases) { p in Text(p.label).tag(p) }
                }
                .pickerStyle(.segmented)

                LabeledField(label: "IP / Host", text: $settings.config.host, keyboard: .URL)

                if settings.config.proto == .smb {
                    LabeledField(label: "Freigabe", text: $settings.config.share)
                } else {
                    HStack {
                        Text("Port").frame(width: 90, alignment: .leading)
                        TextField("21", value: $settings.config.ftpPort, format: .number)
                            .keyboardType(.numberPad)
                    }
                }

                LabeledField(label: "Zielordner", text: $settings.config.targetSubpath, placeholder: "z. B. IP13 (leer = Wurzel)")
                Button {
                    showFolderPicker = true
                } label: {
                    Label("Auf dem NAS auswählen …", systemImage: "folder.badge.gearshape")
                }
                .disabled(!settings.config.isComplete)
            } header: {
                Text("NAS")
            } footer: {
                if settings.config.proto == .ftp {
                    Text("FTP hat kein „Freigabe“-Feld. Der Zielordner ist der VOLLE Pfad ab dem FTP-Wurzelverzeichnis (z. B. FREECOM_HDD/IP13). Am besten „Auf dem NAS auswählen“ und bis zur USB-Platte navigieren. Der FRITZ!Box-Benutzer braucht Schreibrechte auf dem NAS.")
                }
            }

            Section("Anmeldung") {
                LabeledField(label: "Benutzer", text: $settings.config.username, placeholder: "leer = guest")
                HStack {
                    Text("Passwort").frame(width: 90, alignment: .leading)
                    SecureField("Passwort", text: $settings.password)
                }
            }

            Section("Optionen") {
                if settings.config.proto == .smb {
                    Toggle("SMB-Verschlüsselung erzwingen", isOn: $settings.config.encrypted)
                    Toggle("SMB-Signing erzwingen", isOn: $settings.config.smbForceSigning)
                    Button {
                        showDiagnostics = true
                    } label: {
                        Label("SMB-Diagnose (Primitiv-Tests) …", systemImage: "stethoscope")
                    }
                    .disabled(!settings.config.isComplete)
                } else {
                    Toggle("Passiv-Modus (empfohlen)", isOn: $settings.config.ftpPassive)
                    Toggle("FTPS / TLS (experimentell)", isOn: $settings.config.ftps)
                }
                Toggle("Datum + Uhrzeit an Zielordner anhängen (_JJMMTT_HHMMSS)", isOn: $settings.config.appendDateSuffix)
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

            Section {
                Button {
                    sysResult = nil
                    showSysImporter = true
                } label: {
                    Label("iOS-Schreibtest in Dateien-Ordner …", systemImage: "externaldrive.badge.plus")
                }
                if let sysResult {
                    Label(sysResult, systemImage: sysOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(sysOK ? .green : .red)
                        .font(.footnote)
                }
            } header: {
                Text("Beweis: System-SMB über die Dateien-App")
            } footer: {
                Text("Vorher in der Dateien-App das NAS mounten („Mit Server verbinden“ → smb://…, mit schreibfähigem Benutzer). Hier dann diesen Ordner auf dem NAS wählen — die App legt darin einen Ordner an und schreibt eine Testdatei über iOS’ eigenen SMB-Stack (kein libsmb2). Ergebnis steht im Protokoll.")
            }
        }
        .navigationTitle("Verbindung")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showSysImporter, allowedContentTypes: [.folder]) { result in
            runSysWriteTest(result)
        }
        .sheet(isPresented: $showFolderPicker) {
            SMBFolderPickerView(
                config: settings.config,
                password: settings.password,
                selectedPath: $settings.config.targetSubpath
            )
        }
        .sheet(isPresented: $showDiagnostics) {
            SMBDiagnosticsView(config: settings.config, password: settings.password)
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        LocalNetwork.requestPermission()   // Local-Network-Dialog ggf. auslösen
        let session: RemoteTransport = TransportFactory.make(config: settings.config, password: settings.password)
        Task {
            // Pre-Flight: erst Netzweg/Berechtigung prüfen (klare Diagnose statt „Error 1").
            let pre = await Preflight.probe(host: settings.config.host, defaultPort: settings.config.probePort)
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

    /// Beweis: schreibt über iOS’ eigenen Datei-/SMB-Stack (Dokumenten-Picker + `FileManager`,
    /// KEIN libsmb2) in einen vom Nutzer gewählten Ordner — z. B. ein in der Dateien-App
    /// gemountetes SMB-NAS. Legt darin `nasbackup_systest/probe.txt` an und liest sie zurück.
    private func runSysWriteTest(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            if case .failure(let e) = result {
                Log.write("SYS-SMB Schreibtest: Picker-Fehler — \(e.localizedDescription)")
            }
            return
        }
        Task {
            let outcome = await Task.detached { () -> (ok: Bool, msg: String) in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                Log.write("SYS-SMB Schreibtest: Ziel = \(url.path) (scoped=\(scoped))")
                let fm = FileManager.default
                let dir = url.appendingPathComponent("nasbackup_systest", isDirectory: true)
                let file = dir.appendingPathComponent("probe.txt")
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    Log.write("SYS-SMB: Ordner 'nasbackup_systest' angelegt ✓")
                    try Data("NAS Backup System-SMB Schreibtest\n".utf8).write(to: file)
                    let back = try Data(contentsOf: file)
                    Log.write("SYS-SMB: geschrieben + zurückgelesen (\(back.count) B) ✓ — SCHREIBEN GEHT")
                    return (true, "Schreiben erfolgreich (\(url.lastPathComponent)).")
                } catch {
                    let ns = error as NSError
                    Log.write("SYS-SMB Schreibtest FEHLER — \(ns.domain) \(ns.code): \(ns.localizedDescription)")
                    return (false, "Schreiben verweigert: \(ns.localizedDescription)")
                }
            }.value
            sysOK = outcome.ok
            sysResult = outcome.msg
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
