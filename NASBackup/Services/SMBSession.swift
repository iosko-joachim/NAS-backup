import Foundation
import AMSMB2

/// Fehler, die der Engine-Layer unterscheiden möchte.
enum SMBError: LocalizedError {
    case invalidServerURL
    case managerInit
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "Ungültige Server-Adresse."
        case .managerInit: return "SMB-Client konnte nicht initialisiert werden."
        case .notConnected: return "Keine Verbindung zum NAS."
        }
    }
}

/// Dünner Wrapper um AMSMB2 `SMB2Manager`.
/// Kapselt (Neu-)Verbindung, rekursives Listing, Verzeichnis-Anlage,
/// Upload mit Fortschritt und das Setzen der Änderungszeit.
///
/// Bewusst kein Aktor: Aufrufe sind `async` und AMSMB2 ist laut Doku thread-safe.
/// Bei einem Broken-Pipe baut die Engine die Verbindung über `connect()` neu auf.
final class SMBSession: RemoteTransport, @unchecked Sendable {
    private let config: TransferConfig
    private let password: String
    private var manager: SMB2Manager?

    init(config: TransferConfig, password: String) {
        self.config = config
        self.password = password
    }

    /// Baut Manager + Share-Verbindung (neu) auf. Idempotent — auch zur Reconnect-Nutzung.
    func connect() async throws {
        guard let url = URL(string: "smb://\(config.host)") else { throw SMBError.invalidServerURL }
        let user = config.username.isEmpty ? "guest" : config.username
        let credential = URLCredential(user: user, password: password, persistence: .forSession)
        guard let mgr = SMB2Manager(url: url, credential: credential) else { throw SMBError.managerInit }
        try await mgr.connectShare(name: config.share, encrypted: config.encrypted)
        self.manager = mgr
    }

    func disconnect() async {
        try? await manager?.disconnectShare(gracefully: true)
        manager = nil
    }

    /// Kurzer Verbindungstest (Connect + echo).
    func test() async throws {
        try await connect()
        try await manager?.echo()
    }

    /// Listet `basePath` (relativ zur Freigabe) rekursiv und liefert Dateien **und**
    /// bereits existierende Verzeichnisse. So können wir später nur die wirklich fehlenden
    /// Ordner anlegen — ohne fehlerträchtige stat-/mkdir-Aufrufe auf existierende Pfade,
    /// die libsmb2 aus dem Tritt bringen würden.
    func snapshot(basePath: String) async throws -> RemoteSnapshot {
        guard let manager else { throw SMBError.notConnected }
        let path = Self.normalize(basePath)
        let listingPath = path.isEmpty ? "/" : path
        let entries: [[URLResourceKey: Any]]
        do {
            entries = try await manager.contentsOfDirectory(atPath: listingPath, recursive: true)
        } catch {
            // Zielordner existiert (noch) nicht -> leer, baseExists = false.
            return RemoteSnapshot()
        }
        var snap = RemoteSnapshot()
        snap.baseExists = true
        for e in entries {
            guard let rawPath = e[.pathKey] as? String else { continue }
            let key = Self.normalize(rawPath)
            let isDir = (e[.fileResourceTypeKey] as? URLFileResourceType) == .directory
                || (e[.isDirectoryKey] as? Bool) == true
            if isDir {
                snap.directories.insert(key)
            } else {
                let size = (e[.fileSizeKey] as? NSNumber)?.int64Value
                    ?? Int64(e[.fileSizeKey] as? Int ?? 0)
                let date = e[.contentModificationDateKey] as? Date
                snap.files[key] = RemoteEntry(size: size, modificationDate: date)
            }
        }
        return snap
    }

    /// Listet die direkten Unterverzeichnisse (eine Ebene) unter `basePath` — für den Ziel-Browser.
    func listDirectories(atPath basePath: String) async throws -> [String] {
        guard let manager else { throw SMBError.notConnected }
        let path = Self.normalize(basePath)
        let entries = try await manager.contentsOfDirectory(atPath: path, recursive: false)
        var dirs: [String] = []
        for e in entries {
            let isDir = (e[.fileResourceTypeKey] as? URLFileResourceType) == .directory
                || (e[.isDirectoryKey] as? Bool) == true
            guard isDir, let name = e[.nameKey] as? String else { continue }
            if name == "." || name == ".." { continue }
            dirs.append(name)
        }
        return dirs.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Legt ein Verzeichnis (inkl. Zwischenebenen) an — für „Neuer Ordner" im Browser.
    func makeDirectory(_ path: String) async throws {
        var created = Set<String>()
        try await ensureDirectory(path, created: &created)
    }

    /// Legt nur die in `created` noch NICHT bekannten Ebenen von `directoryPath` an.
    /// `created` sollte vorab mit den bereits existierenden Verzeichnissen (aus `snapshot`)
    /// befüllt sein, damit hier ausschließlich wirklich fehlende Ordner angelegt werden —
    /// so entsteht keine Kollision, die libsmb2 stören würde.
    func ensureDirectory(_ directoryPath: String, created: inout Set<String>) async throws {
        guard manager != nil else { throw SMBError.notConnected }
        let normalized = Self.normalize(directoryPath)
        guard !normalized.isEmpty else { return }
        let parts = normalized.split(separator: "/").map(String.init)
        var current = ""
        for part in parts {
            current = current.isEmpty ? part : current + "/" + part
            if created.contains(current) { continue }
            do {
                guard let m = manager else { throw SMBError.notConnected }
                try await m.createDirectory(atPath: current)
            } catch {
                // Sollte wider Erwarten doch eine Kollision/ein Fehler auftreten, kann die
                // Verbindung gestört sein -> neu verbinden, damit Folgeoperationen klappen.
                try? await connect()
            }
            created.insert(current)
        }
    }

    /// Lädt `localURL` nach `remotePath` (relativ zur Freigabe) hoch.
    /// `onProgress` erhält die bisher geschriebenen Bytes; gibt `false` zurück, um abzubrechen.
    func upload(
        localURL: URL,
        to remotePath: String,
        onProgress: @escaping @Sendable (_ bytes: Int64) -> Bool
    ) async throws {
        guard let manager else { throw SMBError.notConnected }
        try await manager.uploadItem(at: localURL, toPath: Self.normalize(remotePath), progress: onProgress)
    }

    /// Setzt die Änderungszeit am Ziel, damit der Inkrementell-Abgleich über Läufe stabil bleibt.
    func setModificationDate(_ date: Date, at remotePath: String) async throws {
        guard let manager else { throw SMBError.notConnected }
        try await manager.setAttributes(
            attributes: [.contentModificationDateKey: date],
            ofItemAtPath: Self.normalize(remotePath)
        )
    }

    /// Normalisiert Pfade: Forward-Slashes, kein führender/abschließender Slash.
    static func normalize(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
