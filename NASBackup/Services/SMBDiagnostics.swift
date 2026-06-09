import Foundation
import Observation

/// Isolierte SMB-Primitiv-Tests gegen das NAS. Jeder Test führt **eine** Operation aus und
/// loggt ausführlich ins `NASBackup.log` (Domain/Code/Status). Ziel: sehen, WELCHE Operation
/// an der FRITZ!Box scheitert — und unter welcher Freigabe — getrennt von einem vollen
/// Backup-Lauf. Reihenfolge/Nummerierung = die Buttons in `SMBDiagnosticsView`.
@MainActor
@Observable
final class SMBDiagnostics {
    struct Scenario: Identifiable {
        let id: Int
        let title: String
        let detail: String
    }

    /// Zuordnung Button-Nummer → Primitiv (wird 1:1 in der UI angezeigt).
    static let scenarios: [Scenario] = [
        .init(id: 1, title: "Verbinden (konfig. Freigabe)",
              detail: "connectShare auf die eingestellte Freigabe + echo."),
        .init(id: 2, title: "Verbinden Freigabe „FREECOM_HDD“",
              detail: "connectShare direkt auf den Platten-Share + echo — existiert er überhaupt?"),
        .init(id: 3, title: "Wurzel auflisten (konfig. Freigabe)",
              detail: "Verzeichnisse im Wurzelverzeichnis der eingestellten Freigabe (Lesetest)."),
        .init(id: 4, title: "Zielpfad lesen",
              detail: "Verzeichnisse unter dem eingestellten Zielordner (Lesetest)."),
        .init(id: 5, title: "Ordner anlegen (konfig.)",
              detail: "MKD Zielordner/__diag__ auf der eingestellten Freigabe."),
        .init(id: 6, title: "Datei schreiben (konfig.)",
              detail: "STOR Zielordner/__diag__/probe.txt auf der eingestellten Freigabe."),
        .init(id: 7, title: "Anlegen + Schreiben über „FREECOM_HDD“",
              detail: "Schlüsseltest: Freigabe=FREECOM_HDD, MKD+STOR in <Ziel ohne FREECOM_HDD>/__diag__."),
        .init(id: 8, title: "In Freigabe-Wurzel schreiben (konfig.)",
              detail: "STOR __diag_probe.txt direkt in die Wurzel der eingestellten Freigabe."),
        .init(id: 9, title: "Änderungsdatum setzen (FREECOM_HDD)",
              detail: "Nach STOR ein SetInfo (mtime) — kann SMB an der FRITZ!Box das Datum setzen?"),
    ]

    private(set) var running = false
    private(set) var runningID: Int?
    private(set) var status = "Bereit. Jeder Test schreibt Details ins Protokoll."

    func runAll(config: TransferConfig, password: String) async {
        guard !running else { return }
        for s in Self.scenarios {
            await run(s.id, config: config, password: password)
        }
        status = "Alle Tests durch — Details im Protokoll („Protokoll teilen“)."
    }

    func run(_ id: Int, config: TransferConfig, password: String) async {
        guard !running else { return }
        running = true; runningID = id
        defer { running = false; runningID = nil }
        let title = Self.scenarios.first { $0.id == id }?.title ?? "#\(id)"
        status = "Läuft: \(id) — \(title) …"
        Log.write("──────── SMB-DIAG \(id): \(title) ────────")
        do {
            try await body(id, config: config, password: password)
            Log.write("SMB-DIAG \(id): OK ✓")
            status = "\(id) — OK ✓ (Details im Protokoll)"
        } catch {
            Log.write("SMB-DIAG \(id): FEHLER ✗ — \(SMBSession.describe(error))")
            status = "\(id) — FEHLER ✗ (Details im Protokoll)"
        }
    }

    // MARK: - Helfer

    private func makeSession(_ base: TransferConfig, share: String, password: String) -> SMBSession {
        var c = base
        c.proto = .smb
        c.share = share
        return SMBSession(config: c, password: password)
    }

    /// Zielpfad ohne führendes „FREECOM_HDD/“ — für Tests direkt auf dem FREECOM_HDD-Share.
    private func volumeRelative(_ targetSubpath: String) -> String {
        let parts = SMBSession.normalize(targetSubpath).split(separator: "/").map(String.init)
        if let first = parts.first, first.caseInsensitiveCompare("FREECOM_HDD") == .orderedSame {
            return parts.dropFirst().joined(separator: "/")
        }
        return SMBSession.normalize(targetSubpath)
    }

    private func tempProbeFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nasbackup_diag_probe.txt")
        try Data("NAS Backup SMB-Diagnose-Probe\n".utf8).write(to: url)
        return url
    }

    // MARK: - Primitive

    private func body(_ id: Int, config: TransferConfig, password: String) async throws {
        let share = config.share
        let target = SMBSession.normalize(config.targetSubpath)
        switch id {
        case 1:
            let s = makeSession(config, share: share, password: password)
            try await s.test()
            await s.disconnect()
        case 2:
            let s = makeSession(config, share: "FREECOM_HDD", password: password)
            try await s.test()
            await s.disconnect()
        case 3:
            let s = makeSession(config, share: share, password: password)
            try await s.connect()
            let d = try await s.listDirectories(atPath: "")
            Log.write("smb: Wurzel von '\(share)': [\(d.joined(separator: ", "))]")
            await s.disconnect()
        case 4:
            let s = makeSession(config, share: share, password: password)
            try await s.connect()
            let d = try await s.listDirectories(atPath: target)
            Log.write("smb: Inhalt von '\(target.isEmpty ? "(Wurzel)" : target)': [\(d.joined(separator: ", "))]")
            await s.disconnect()
        case 5:
            let s = makeSession(config, share: share, password: password)
            try await s.connect()
            let dir = (target.isEmpty ? "" : target + "/") + "__diag__"
            Log.write("smb: lege an '\(dir)' (Freigabe '\(share)')")
            try await s.createDirectoryOnce(dir)
            await s.disconnect()
        case 6:
            let s = makeSession(config, share: share, password: password)
            try await s.connect()
            let dir = (target.isEmpty ? "" : target + "/") + "__diag__"
            try? await s.createDirectoryOnce(dir)   // Ordner sicherstellen (Fehler hier nicht fatal)
            let local = try tempProbeFile()
            try await s.upload(localURL: local, to: dir + "/probe.txt", onProgress: { _ in true })
            await s.disconnect()
        case 7:
            let s = makeSession(config, share: "FREECOM_HDD", password: password)
            try await s.connect()
            let rel = volumeRelative(target)
            let dir = (rel.isEmpty ? "" : rel + "/") + "__diag__"
            Log.write("smb: Schlüsseltest — Freigabe 'FREECOM_HDD', Ordner '\(dir)'")
            try? await s.createDirectoryOnce(dir)
            let local = try tempProbeFile()
            try await s.upload(localURL: local, to: dir + "/probe.txt", onProgress: { _ in true })
            await s.disconnect()
        case 8:
            let s = makeSession(config, share: share, password: password)
            try await s.connect()
            let local = try tempProbeFile()
            try await s.upload(localURL: local, to: "__diag_probe.txt", onProgress: { _ in true })
            await s.disconnect()
        case 9:
            let s = makeSession(config, share: "FREECOM_HDD", password: password)
            try await s.connect()
            let rel = volumeRelative(target)
            let dir = (rel.isEmpty ? "" : rel + "/") + "__diag__"
            try? await s.createDirectoryOnce(dir)
            let file = dir + "/probe_mtime.txt"
            let local = try tempProbeFile()
            try await s.upload(localURL: local, to: file, onProgress: { _ in true })
            let past = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01 00:00 UTC
            try await s.setModificationDate(past, at: file)
            await s.disconnect()
        default:
            Log.write("smb: unbekanntes Szenario \(id)")
        }
    }
}
