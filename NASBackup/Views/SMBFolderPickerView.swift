import SwiftUI

/// Interaktiver Ziel-Browser: verbindet sich mit dem NAS, zeigt die Ordnerstruktur,
/// erlaubt Navigieren, „Neuer Ordner" und „Hier sichern".
struct SMBFolderPickerView: View {
    let config: TransferConfig
    let password: String
    @Binding var selectedPath: String
    @Environment(\.dismiss) private var dismiss

    @State private var session: RemoteTransport?
    @State private var components: [String] = []
    @State private var dirs: [String] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    private var currentPath: String { components.joined(separator: "/") }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "externaldrive.connected.to.line.below")
                        Text(config.share + (currentPath.isEmpty ? "" : "/" + currentPath))
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }

                if loading {
                    HStack { ProgressView(); Text("Lädt …").foregroundStyle(.secondary) }
                } else if let error {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red).font(.footnote)
                    Button("Erneut versuchen") { Task { await load() } }
                } else {
                    if !components.isEmpty {
                        Button {
                            components.removeLast()
                            Task { await load() }
                        } label: { Label("..", systemImage: "arrow.up.left") }
                    }
                    if dirs.isEmpty {
                        Text("Keine Unterordner").foregroundStyle(.secondary).font(.footnote)
                    } else {
                        ForEach(dirs, id: \.self) { dir in
                            Button {
                                components.append(dir)
                                Task { await load() }
                            } label: {
                                Label(dir, systemImage: "folder").foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Zielordner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                        .disabled(loading || error != nil)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        selectedPath = currentPath
                        dismiss()
                    } label: {
                        Text(currentPath.isEmpty ? "Wurzel als Ziel wählen" : "„\(currentPath)“ als Ziel wählen")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading)
                }
            }
            .alert("Neuer Ordner", isPresented: $showNewFolder) {
                TextField("Name", text: $newFolderName)
                    .textInputAutocapitalization(.never)
                Button("Anlegen") { Task { await createFolder() } }
                Button("Abbrechen", role: .cancel) { newFolderName = "" }
            }
        }
        .task { await initialLoad() }
    }

    private func initialLoad() async {
        components = selectedPath.split(separator: "/").map(String.init)
        await load()
    }

    private func load() async {
        loading = true; error = nil
        do {
            if session == nil {
                let s = TransportFactory.make(config: config, password: password)
                try await s.connect()
                session = s
            }
            dirs = try await session!.listDirectories(atPath: currentPath)
        } catch {
            self.error = error.localizedDescription
            dirs = []
        }
        loading = false
    }

    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        newFolderName = ""
        guard !name.isEmpty, let session else { return }
        loading = true; error = nil
        let path = currentPath.isEmpty ? name : currentPath + "/" + name
        do {
            try await session.makeDirectory(path)
            dirs = try await session.listDirectories(atPath: currentPath)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
