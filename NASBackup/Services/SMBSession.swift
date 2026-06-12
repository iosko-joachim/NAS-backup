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

    /// Kurzer Verbindungstest (Connect + echo). Vorher werden — best-effort — die vom Server
    /// tatsächlich angebotenen Freigaben abgefragt und geloggt. So sieht man bei einem falschen
    /// Freigabenamen (TREE_CONNECT → STATUS_BAD_NETWORK_NAME) sofort die gültigen Namen.
    func test() async throws {
        await logAvailableShares()
        try await connect()
        try await manager?.echo()
    }

    /// Fragt die Freigaben des Servers per srvsvc (über IPC$) ab und schreibt sie ins Protokoll.
    /// Best-effort: eigener, kurzlebiger Manager; Fehler werden nur geloggt, nie geworfen — der
    /// Verbindungstest selbst soll dadurch nicht scheitern.
    func logAvailableShares() async {
        guard let url = URL(string: "smb://\(config.host)") else { return }
        let user = config.username.isEmpty ? "guest" : config.username
        let credential = URLCredential(user: user, password: password, persistence: .forSession)
        guard let mgr = SMB2Manager(url: url, credential: credential) else { return }
        mgr.forceSMBSigning = config.smbForceSigning
        Log.write("smb: frage Freigaben am Server '\(config.host)' ab (IPC$/srvsvc) …")
        do {
            let shares = try await mgr.listShares(enumerateHidden: false)
            if shares.isEmpty {
                Log.write("smb: Freigaben-Abfrage ok, aber Server meldet keine sichtbaren Freigaben")
            } else {
                let names = shares
                    .map { $0.comment.isEmpty ? "'\($0.name)'" : "'\($0.name)' (\($0.comment))" }
                    .joined(separator: ", ")
                Log.write("smb: verfügbare Freigaben: \(names)")
            }
        } catch {
            Log.write("smb: Freigaben-Abfrage fehlgeschlagen — \(Self.describe(error))")
        }
        try? await mgr.disconnectShare(gracefully: true)
    }

    /// Liefert die bereits am Ziel vorhandenen Dateien (für den Inkrementell-Abgleich) und
    /// die existierenden Verzeichnisse (damit `ensureDirectory` sie nicht neu anzulegen
    /// versucht — das würde libsmb2 stören).
    ///
    /// WICHTIG: NICHT den ganzen Zielbaum rekursiv listen. Das `recursive: true`-Listing
    /// kann bei einem gefüllten/„zyklischen" Ziel an der FB6490 in eine Endlosschleife von
    /// `QUERY_DIRECTORY` laufen (NO_MORE_FILES ohne Ende). Stattdessen — wie bei FTP — nur die
    /// `scope`-Ordner (die Eltern der geplanten Dateien) **flach** listen. Das ist durch die
    /// Quellstruktur begrenzt, betritt keine unbeteiligten/zyklischen Teile der Platte und
    /// reicht für den Abgleich (jede geplante Datei wird über ihren vollen Pfad nachgeschlagen).
    func snapshot(basePath: String,
                  scope: Set<String>,
                  isCancelled: @escaping @Sendable () -> Bool) async throws -> RemoteSnapshot {
        guard let manager else { throw SMBError.notConnected }
        var snap = RemoteSnapshot()
        if isCancelled() { return snap }

        for dir in scope.sorted() {
            if isCancelled() { return snap }
            let d = Self.normalize(dir)
            let listingPath = d.isEmpty ? "/" : d
            let entries: [[URLResourceKey: Any]]
            do {
                entries = try await manager.contentsOfDirectory(atPath: listingPath, recursive: false)
            } catch {
                // Ordner existiert (noch) nicht -> dort gibt es nichts zu vergleichen.
                continue
            }
            // Ordner existiert -> ihn und alle Eltern (bis inkl. Basis) als vorhanden vormerken,
            // damit ensureDirectory sie nicht neu anzulegen versucht.
            snap.baseExists = true
            markExisting(d, into: &snap.directories)
            for e in entries {
                guard let name = e[.nameKey] as? String, name != ".", name != ".." else { continue }
                let full = Self.normalize(d.isEmpty ? name : d + "/" + name)
                let isDir = (e[.fileResourceTypeKey] as? URLFileResourceType) == .directory
                    || (e[.isDirectoryKey] as? Bool) == true
                if isDir {
                    snap.directories.insert(full)
                } else {
                    let size = (e[.fileSizeKey] as? NSNumber)?.int64Value
                        ?? Int64(e[.fileSizeKey] as? Int ?? 0)
                    let date = e[.contentModificationDateKey] as? Date
                    snap.files[full] = RemoteEntry(size: size, modificationDate: date)
                }
            }
        }
        return snap
    }

    /// Trägt `path` und alle seine Elternpfade in `set` ein (für den „existiert bereits"-Satz).
    private func markExisting(_ path: String, into set: inout Set<String>) {
        let p = Self.normalize(path)
        guard !p.isEmpty else { return }
        var cur = ""
        for part in p.split(separator: "/") {
            cur = cur.isEmpty ? String(part) : cur + "/" + String(part)
            set.insert(cur)
        }
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

    /// Normalisiert Pfade: Forward-Slashes, keine führenden/abschließenden UND keine
    /// inneren Doppel-Slashes. Letzteres ist wichtig für den Inkrementell-Abgleich:
    /// rekursive Listings können `Ordner//datei` liefern; ohne Kollabieren würde der
    /// Schlüssel nie zum geplanten `Ordner/datei` passen → alles würde neu kopiert.
    static func normalize(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
