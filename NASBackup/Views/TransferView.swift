import SwiftUI

/// Live-Fortschritt eines laufenden Backups sowie das Ergebnis inkl. Fehlerprotokoll.
struct TransferView: View {
    var engine: BackupEngine

    var body: some View {
        Form {
            Section {
                ProgressView(value: engine.fractionComplete) {
                    Text(engine.statusMessage).font(.subheadline)
                } currentValueLabel: {
                    Text("\(Int(engine.fractionComplete * 100)) %")
                }

                if engine.isRunning {
                    LabeledContent("Durchsatz", value: Format.rate(engine.throughput))
                }
            }

            Section("Aktuelle Datei") {
                if engine.currentFileName.isEmpty {
                    Text("–").foregroundStyle(.secondary)
                } else {
                    Text(engine.currentFileName).font(.footnote).lineLimit(2)
                    if engine.currentFileSize > 0 {
                        ProgressView(value: Double(engine.currentFileBytes), total: Double(engine.currentFileSize))
                        Text("\(Format.bytes(engine.currentFileBytes)) / \(Format.bytes(engine.currentFileSize))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Zähler") {
                LabeledContent("Kopiert", value: "\(engine.copiedCount)")
                LabeledContent("Übersprungen", value: "\(engine.skippedCount)")
                LabeledContent("Fehlgeschlagen", value: "\(engine.failedCount)")
                LabeledContent("Geplant", value: "\(engine.totalFilesToCopy)")
                LabeledContent("Volumen", value: "\(Format.bytes(engine.bytesTransferred)) / \(Format.bytes(engine.totalBytesToCopy))")
            }

            if !engine.errors.isEmpty {
                Section("Fehler (\(engine.errors.count))") {
                    ForEach(engine.errors) { err in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(err.relativePath).font(.footnote).lineLimit(2)
                            Text(err.message ?? "Unbekannter Fehler")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle("Übertragung")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if engine.isRunning {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Abbrechen", role: .destructive) { engine.cancel() }
                }
            }
        }
    }
}
