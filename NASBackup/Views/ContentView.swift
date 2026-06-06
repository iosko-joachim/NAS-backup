import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var settings = SettingsStore()
    @State private var engine = BackupEngine()

    @State private var importingFolder = false
    @State private var navigateToTransfer = false

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                sourcesSection
                runSection
                logSection
            }
            .navigationTitle("NAS Backup")
            .navigationDestination(isPresented: $navigateToTransfer) {
                TransferView(engine: engine)
            }
            .fileImporter(
                isPresented: $importingFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls { settings.addSource(url: url) }
                }
            }
            .task {
                // Local-Network-Dialog früh auslösen, damit die SMB-Verbindung später erlaubt ist.
                LocalNetwork.requestPermission()
                Log.write("App geöffnet — \(appVersionString)")
            }
        }
    }

    // MARK: - Verbindung

    private var connectionSection: some View {
        Section("Verbindung") {
            NavigationLink {
                ConnectionSettingsView(settings: settings)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.config.host.isEmpty ? "NAS einrichten" : "\(settings.config.host) › \(settings.config.share)")
                        .font(.body)
                    let target = settings.config.targetSubpath.isEmpty ? "(Wurzel)" : settings.config.targetSubpath
                    Text("Ziel: \(target)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Quellen

    private var sourcesSection: some View {
        Section {
            ForEach(settings.sources) { source in
                Label(source.displayName, systemImage: "folder")
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            settings.removeSource(source)
                        } label: {
                            Label("Entfernen", systemImage: "minus.circle")
                        }
                        .tint(.gray)
                    }
            }

            Button {
                importingFolder = true
            } label: {
                Label("Ordner hinzufügen", systemImage: "plus.circle")
            }
        } header: {
            Text("Quellordner")
        } footer: {
            Text("Ordner aus „Auf meinem iPhone“ oder einem anderen Files-Speicherort, wird rekursiv kopiert. Zum Abwählen nach links wischen → „Entfernen“ nimmt den Ordner nur aus dieser Liste, es wird nichts auf dem iPhone gelöscht.")
        }
    }

    // MARK: - Lauf

    private var runSection: some View {
        Section {
            if engine.isRunning {
                NavigationLink {
                    TransferView(engine: engine)
                } label: {
                    HStack {
                        ProgressView()
                        VStack(alignment: .leading) {
                            Text("Läuft … \(Int(engine.fractionComplete * 100)) %")
                            Text(engine.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Button("Abbrechen", role: .destructive) { engine.cancel() }
            } else {
                Button {
                    engine.start(
                        config: settings.config,
                        password: settings.password,
                        sources: settings.sources
                    )
                    navigateToTransfer = true
                } label: {
                    Label("Backup starten", systemImage: "arrow.up.circle.fill")
                }
                .disabled(!canStart)

                if engine.phase == .finished || engine.phase == .cancelled || engine.phase == .failed {
                    NavigationLink {
                        TransferView(engine: engine)
                    } label: {
                        Label(engine.statusMessage, systemImage: statusIcon)
                            .font(.footnote)
                    }
                }
            }
        } header: {
            Text("Sicherung")
        } footer: {
            VStack(alignment: .leading, spacing: 10) {
                Text("Der Bildschirm bleibt während der Übertragung an. Gerät am besten ans Ladegerät anschließen.")
                Text(appVersionString)
            }
        }
    }

    private var logSection: some View {
        Section {
            ShareLink(item: Log.fileURL) {
                Label("Protokoll teilen", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                Log.clear()
            } label: {
                Label("Protokoll löschen", systemImage: "trash")
            }
        } header: {
            Text("Protokoll")
        } footer: {
            Text("Aufzeichnung von Verbindungen, Fehlern und Läufen. Liegt als „NASBackup.log“ in der Files-App unter „Auf meinem iPhone → NAS Backup“ und kann hier geteilt werden.")
        }
    }

    private var canStart: Bool {
        settings.config.isComplete && !settings.sources.isEmpty
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "NAS Backup \(version) (Build \(build))"
    }

    private var statusIcon: String {
        switch engine.phase {
        case .finished: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "info.circle"
        }
    }
}

#Preview {
    ContentView()
}
