import Foundation

/// Übertragungsprotokoll.
enum TransferProtocol: String, Codable, CaseIterable, Identifiable {
    case smb
    case ftp
    var id: String { rawValue }
    var label: String { self == .smb ? "SMB" : "FTP" }
}

/// Verbindungs- und Zielkonfiguration für das NAS.
/// Das Passwort wird NICHT hier gespeichert, sondern im Keychain (siehe `KeychainStore`).
struct TransferConfig: Codable, Equatable {
    /// Protokoll (SMB oder FTP).
    var proto: TransferProtocol = .smb
    /// IP oder Hostname, z. B. "192.168.178.1"
    var host: String = "192.168.178.1"
    /// Freigabename (Share), z. B. "FREECOM_HDD" — nur SMB.
    var share: String = "FREECOM_HDD"
    /// Benutzername. Für Gastzugriff "guest".
    var username: String = ""
    /// Zielordner (relativ zur Freigabe bzw. zum FTP-Login-Verzeichnis), z. B. "IP13".
    var targetSubpath: String = ""
    /// SMB-Verschlüsselung erzwingen (manche FRITZ!Box-Firmwares mögen das nicht). — nur SMB.
    var encrypted: Bool = false
    /// Hängt an jeden kopierten Quell-Ordner ein Datums-/Zeit-Suffix `_JJMMTT_HHMMSS` an
    /// (eindeutiger Zielordner je Lauf — hilfreich bei häufigen Tests).
    var appendDateSuffix: Bool = false
    /// Strenger Modus: zusätzlich bei NEUERER Quelle kopieren (mtime). Standard aus, weil
    /// FAT/Zeitzonen/DST-Versatz sonst unveränderte Dateien endlos neu kopieren lässt.
    /// Default = Vergleich nur über Dateigröße (zeitzonensicher).
    var strictTimeCheck: Bool = false
    // MARK: FTP-spezifisch
    /// FTP-Port (Standard 21).
    var ftpPort: Int = 21
    /// Passiv-Modus (auf iOS praktisch immer nötig).
    var ftpPassive: Bool = true
    /// FTPS (explizite TLS) — noch experimentell.
    var ftps: Bool = false

    /// Default-Port fürs Pre-Flight-Probing je Protokoll.
    var probePort: UInt16 { proto == .smb ? 445 : UInt16(ftpPort) }

    var isComplete: Bool {
        let hostOK = !host.trimmingCharacters(in: .whitespaces).isEmpty
        switch proto {
        case .smb: return hostOK && !share.trimmingCharacters(in: .whitespaces).isEmpty
        case .ftp: return hostOK
        }
    }

    /// Schlüssel, unter dem das Passwort im Keychain abgelegt wird.
    var keychainAccount: String { "\(proto.rawValue)://\(username)@\(host)/\(share)" }
}

/// Eine vom Nutzer gewählte Quelle (Ordner aus „On My iPhone" o. ä.),
/// persistiert über ein Security-Scoped Bookmark.
struct SourceFolder: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var displayName: String
    var bookmark: Data
}

/// Wie eine vorhandene Zieldatei mit der Quelle verglichen wird.
enum SkipDecision {
    case copyMissing      // existiert am Ziel nicht
    case copyNewer        // Quelle ist neuer
    case copyDifferentSize // gleiche/ältere Zeit, aber andere Größe
    case skipUpToDate     // identisch -> überspringen

    var shouldCopy: Bool { self != .skipUpToDate }
}

/// Resultat pro Datei für das Log.
struct FileResult: Identifiable {
    enum Outcome { case copied, skipped, failed }
    let id = UUID()
    let relativePath: String
    let outcome: Outcome
    let bytes: Int64
    let message: String?
}

/// Ein eingeplanter Kopiervorgang (nach dem Scan).
struct PlannedFile {
    let sourceURL: URL
    /// Pfad relativ zur Freigabe, mit Forward-Slashes, z. B. "IP13/DL_260605/sub/foto.jpg".
    let remotePath: String
    let size: Int64
    let modificationDate: Date
}

/// Eintrag aus dem rekursiven Remote-Listing (für den Inkrementell-Abgleich).
struct RemoteEntry {
    let size: Int64
    let modificationDate: Date?
}

/// Ergebnis des rekursiven Remote-Listings: vorhandene Dateien, vorhandene Verzeichnisse
/// und ob der Basis-Zielordner überhaupt existiert.
struct RemoteSnapshot {
    var files: [String: RemoteEntry] = [:]
    var directories: Set<String> = []
    var baseExists: Bool = false
}
