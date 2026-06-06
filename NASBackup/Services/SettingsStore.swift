import Foundation
import Observation

/// Persistiert Verbindungskonfiguration (UserDefaults) und Quell-Ordner (Bookmarks).
/// Das Passwort liegt separat im Keychain.
@MainActor
@Observable
final class SettingsStore {
    var config: SMBConfig {
        didSet { persistConfig() }
    }

    var sources: [SourceFolder] {
        didSet { persistSources() }
    }

    /// Im Speicher gehaltenes Passwort (aus Keychain geladen, beim Setzen dorthin geschrieben).
    var password: String {
        didSet { KeychainStore.setPassword(password, account: config.keychainAccount) }
    }

    private let defaults = UserDefaults.standard
    private let configKey = "smbConfig"
    private let sourcesKey = "sourceFolders"

    init() {
        let cfg: SMBConfig
        if let data = defaults.data(forKey: configKey),
           let decoded = try? JSONDecoder().decode(SMBConfig.self, from: data) {
            cfg = decoded
        } else {
            cfg = SMBConfig()
        }
        self.config = cfg

        if let data = defaults.data(forKey: sourcesKey),
           let decoded = try? JSONDecoder().decode([SourceFolder].self, from: data) {
            self.sources = decoded
        } else {
            self.sources = []
        }

        self.password = KeychainStore.password(account: cfg.keychainAccount) ?? ""
    }

    private func persistConfig() {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: configKey)
        }
    }

    private func persistSources() {
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: sourcesKey)
        }
    }

    // MARK: - Quellen verwalten

    /// Fügt einen per Dokumenten-Picker gewählten Ordner als Security-Scoped Bookmark hinzu.
    func addSource(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil
            )
            // Duplikate (gleicher Name) ersetzen.
            let name = url.lastPathComponent
            sources.removeAll { $0.displayName == name }
            sources.append(SourceFolder(displayName: name, bookmark: bookmark))
        } catch {
            // Bookmark-Erstellung fehlgeschlagen -> still ignorieren; UI zeigt nur die erfolgreichen.
        }
    }

    func removeSources(at offsets: IndexSet) {
        sources.remove(atOffsets: offsets)
    }

    /// Nimmt einen Ordner aus der Übertragungsliste — löscht KEINE Daten auf dem Gerät.
    func removeSource(_ source: SourceFolder) {
        sources.removeAll { $0.id == source.id }
    }
}
