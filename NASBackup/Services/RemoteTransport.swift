import Foundation

/// Abstraktion über das Übertragungsprotokoll (aktuell SMB; FTP folgt als zweite
/// Implementierung). `BackupEngine` und die Views sprechen nur noch dieses Protokoll an,
/// damit ein weiterer Transport rein additiv hinzukommt.
protocol RemoteTransport: AnyObject {
    /// Baut die Verbindung (neu) auf — auch zur Reconnect-Nutzung.
    func connect() async throws

    /// Kurzer Verbindungstest (Connect + Echo/NOOP).
    func test() async throws

    /// Erfasst den Remote-Bestand für den Inkrementell-Abgleich.
    /// `scope` = die Verzeichnisse, in denen geplante Dateien liegen (deren Eltern). Transporte
    /// ohne serverseitige Rekursion (FTP) listen NUR diese Ordner statt den ganzen Zielbaum.
    /// `isCancelled` wird zwischen Teilschritten geprüft, damit ein Abbruch sofort greift.
    func snapshot(basePath: String,
                  scope: Set<String>,
                  isCancelled: @escaping @Sendable () -> Bool) async throws -> RemoteSnapshot

    /// Direkte Unterverzeichnisse (eine Ebene) — für den Ziel-Browser.
    func listDirectories(atPath basePath: String) async throws -> [String]

    /// Legt ein Verzeichnis inkl. Zwischenebenen an.
    func makeDirectory(_ path: String) async throws

    /// Legt nur die in `created` noch unbekannten Ebenen an (Cache bereits existierender Pfade).
    func ensureDirectory(_ directoryPath: String, created: inout Set<String>) async throws

    /// Lädt `localURL` nach `remotePath`. `onProgress(bytes)` -> `false` bricht ab.
    func upload(localURL: URL, to remotePath: String,
                onProgress: @escaping @Sendable (_ bytes: Int64) -> Bool) async throws

    /// Setzt die Änderungszeit am Ziel (optional/no-op, wenn der Transport es nicht kann).
    func setModificationDate(_ date: Date, at remotePath: String) async throws

    func disconnect() async
}

/// Erzeugt den passenden Transport zur Konfiguration. Aktuell immer SMB;
/// hier kommt später die FTP-Verzweigung (z. B. `switch config.proto`) hinein.
enum TransportFactory {
    static func make(config: TransferConfig, password: String) -> RemoteTransport {
        switch config.proto {
        case .smb: return SMBSession(config: config, password: password)
        case .ftp: return FTPSession(config: config, password: password)
        }
    }
}
