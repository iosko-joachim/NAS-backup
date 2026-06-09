import SwiftUI

/// SMB-Primitiv-Tests: pro Szenario ein nummerierter Button. Jeder Test loggt ausführlich
/// ins Protokoll; die Zuordnung Nummer → Test steht direkt unter dem Button.
struct SMBDiagnosticsView: View {
    let config: TransferConfig
    let password: String

    @State private var diag = SMBDiagnostics()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Freigabe", value: config.share.isEmpty ? "—" : config.share)
                    LabeledContent("Zielordner", value: config.targetSubpath.isEmpty ? "(Wurzel)" : config.targetSubpath)
                    LabeledContent("Benutzer", value: config.username.isEmpty ? "(guest)" : config.username)
                } header: {
                    Text("Aktuelle Einstellung")
                } footer: {
                    Text("Jeder Test schreibt Domain/Code/Status ins Protokoll. Danach im Hauptbildschirm „Protokoll teilen“. Tests 2/7/9 verwenden bewusst die Freigabe „FREECOM_HDD“.")
                }

                Section("Primitiv-Tests") {
                    ForEach(SMBDiagnostics.scenarios) { s in
                        Button {
                            Task { await diag.run(s.id, config: config, password: password) }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(s.id)")
                                    .font(.headline.monospacedDigit())
                                    .frame(width: 20, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).font(.body)
                                    Text(s.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                if diag.runningID == s.id { ProgressView() }
                            }
                        }
                        .disabled(diag.running)
                    }
                }

                Section {
                    Button {
                        Task { await diag.runAll(config: config, password: password) }
                    } label: {
                        HStack {
                            if diag.running { ProgressView().padding(.trailing, 4) }
                            Text("Alle 1–9 nacheinander")
                        }
                    }
                    .disabled(diag.running)
                } footer: {
                    Text(diag.status)
                }
            }
            .navigationTitle("SMB-Diagnose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.disabled(diag.running)
                }
            }
            .interactiveDismissDisabled(diag.running)
        }
    }
}
