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
        // Alten Manager sauber schließen, bevor ein neuer entsteht — vermeidet einen
        // verwaisten deinit→disconnect, der libsmb2 beim Teardown stören kann (Crash-Härtung;
        // behebt NICHT das eigentliche Schreibproblem, hält aber die Diagnose stabil).
        if manager != nil { await disconnect() }
        let credential = URLCredential(user: user, password: password, persistence: .forSession)
        guard let mgr = SMB2Manager(url: url, credential: credential) else { throw SMBError.managerInit }
        mgr.forceSMBSigning = config.smbForceSigning
        Log.write("smb: connectShare '\(config.share)' als '\(user)' (verschlüsselt=\(config.encrypted), signing=\(config.smbForceSigning ? "erzwungen" : "auto")) …")
        do {
            try await mgr.connectShare(name: config.share, encrypted: config.encrypted)
        } catch {
            Log.write("smb: connectShare '\(config.share)' FEHLER — \(Self.describe(error))")
            throw error
        }
        self.manager = mgr
        Log.write("smb: verbunden mit Freigabe '\(config.share)'")
    }

    /// Kompakte Fehlerbeschreibung (Domain/Code/Text + Underlying) fürs Protokoll.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts = ["\(ns.domain) \(ns.code)", ns.localizedDescription]
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("↳ \(u.domain) \(u.code): \(u.localizedDescription)")
        }
        return parts.joined(separator: " | ")
    }

    /// Einzelnes `createDirectory` OHNE Reconnect — für die SMB-Diagnose-Primitive
    /// (kein Churn der Verbindung, damit ein Fehler klar sichtbar wird statt Reconnect-Lärm).
    func createDirectoryOnce(_ path: String) async throws {
        guard let m = manager else { throw SMBError.notConnected }
        try await m.createDirectory(atPath: Self.normalize(path))
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
    func snapshot(basePath: String,
                  scope: Set<String>,
                  isCancelled: @escaping @Sendable () -> Bool) async throws -> RemoteSnapshot {
        // `scope` wird hier bewusst ignoriert: SMB listet serverseitig in EINEM Roundtrip
        // rekursiv (schnell) und braucht den vollständigen Verzeichnis-Satz, um ein Neu-Anlegen
        // existierender Ordner zu vermeiden (das würde libsmb2 stören). Siehe ISSUES.md.
        guard let manager else { throw SMBError.notConnected }
        if isCancelled() { return RemoteSnapshot() }
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
                Log.write("smb: MKD '\(current)' ok")
            } catch {
                // Sollte wider Erwarten doch eine Kollision/ein Fehler auftreten, kann die
                // Verbindung gestört sein -> neu verbinden, damit Folgeoperationen klappen.
                Log.write("smb: MKD '\(current)' — \(Self.describe(error)) (existiert evtl.; reconnect)")
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
        let p = Self.normalize(remotePath)
        Log.write("smb: STOR '\(p)' …")
        do {
            try await manager.uploadItem(at: localURL, toPath: p, progress: onProgress)
            Log.write("smb: STOR '\(p)' ok")
        } catch {
            Log.write("smb: STOR '\(p)' FEHLER — \(Self.describe(error))")
            throw error
        }
    }

    /// Setzt die Änderungszeit am Ziel, damit der Inkrementell-Abgleich über Läufe stabil bleibt.
    func setModificationDate(_ date: Date, at remotePath: String) async throws {
        guard let manager else { throw SMBError.notConnected }
        let p = Self.normalize(remotePath)
        do {
            try await manager.setAttributes(
                attributes: [.contentModificationDateKey: date],
                ofItemAtPath: p
            )
            Log.write("smb: SetInfo mtime '\(p)' ok")
        } catch {
            Log.write("smb: SetInfo mtime '\(p)' FEHLER — \(Self.describe(error))")
            throw error
        }
    }

    /// Normalisiert Pfade: Forward-Slashes, kein führender/abschließender Slash.
    static func normalize(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
