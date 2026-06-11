import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Orchestriert den gesamten Backup-Lauf: Quellen scannen, Remote-Bestand abgleichen,
/// fehlende/neuere Dateien kopieren — robust gegen „broken pipe" durch Reconnect + Retry,
/// und mit Weiterlaufen bei Einzeldatei-Fehlern.
@MainActor
@Observable
final class BackupEngine {
    enum Phase: Equatable {
        case idle, scanning, copying, finished, cancelled, failed
    }

    // MARK: - Veröffentlichter Zustand (für die UI)
    private(set) var phase: Phase = .idle
    private(set) var statusMessage = "Bereit."
    private(set) var totalFilesToCopy = 0
    private(set) var processedFiles = 0
    private(set) var copiedCount = 0
    private(set) var skippedCount = 0
    private(set) var failedCount = 0
    private(set) var totalBytesToCopy: Int64 = 0
    private(set) var bytesTransferred: Int64 = 0
    private(set) var currentFileName = ""
    private(set) var currentFileSize: Int64 = 0
    private(set) var currentFileBytes: Int64 = 0
    private(set) var errors: [FileResult] = []
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?

    var isRunning: Bool { phase == .scanning || phase == .copying }

    /// Gesamtfortschritt 0…1 über die zu kopierenden Bytes.
    var fractionComplete: Double {
        guard totalBytesToCopy > 0 else { return phase == .finished ? 1 : 0 }
        return min(1, Double(bytesTransferred + currentFileBytes) / Double(totalBytesToCopy))
    }

    /// Durchsatz in Bytes/Sekunde (über die bisherige Laufzeit).
    var throughput: Double {
        guard let startedAt, isRunning else { return 0 }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0 else { return 0 }
        return Double(bytesTransferred + currentFileBytes) / elapsed
    }

    private let cancelToken = CancelToken()
    private var task: Task<Void, Never>?
    #if canImport(UIKit)
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    private let maxAttempts = 4
    private var strictTimeCheck = false
    private var timeAnomalyCount = 0
    private var writeDeniedHintShown = false

    /// Dauerhafte Fehler (FTP 5xx) — Wiederholen sinnlos.
    static func isPermanent(_ error: Error) -> Bool {
        if let ftp = error as? FTPError, case let .unexpectedReply(code, _) = ftp {
            return (500..<600).contains(code)
        }
        return false
    }

    private func maybeShowWriteDeniedHint(_ error: Error) {
        guard !writeDeniedHintShown,
              let ftp = error as? FTPError, case let .unexpectedReply(code, _) = ftp,
              [530, 550, 552, 553].contains(code) else { return }
        writeDeniedHintShown = true
        let hint = "Schreiben verweigert (\(code)). Der Zielordner liegt vermutlich NICHT auf der "
            + "USB-Platte (sondern im internen FRITZ!Box-Speicher) ODER der FRITZ!Box-Benutzer hat "
            + "dort keine Schreibrechte. → Per „Auf dem NAS auswählen“ in die USB-Platte "
            + "(z. B. FREECOM_HDD) navigieren und die NAS-Schreibrechte des Benutzers prüfen."
        Log.write("Hinweis: \(hint)")
        statusMessage = hint
    }

    // MARK: - Steuerung

    func start(config: TransferConfig, password: String, sources: [SourceFolder]) {
        guard !isRunning else { return }
        cancelToken.reset()
        resetCounters()
        phase = .scanning
        statusMessage = "Quellen werden gescannt …"
        startedAt = Date()
        finishedAt = nil
        keepScreenAwake(true)
        beginBackgroundGrace()

        task = Task { [weak self] in
            await self?.run(config: config, password: password, sources: sources)
        }
    }

    func cancel() {
        guard isRunning else { return }
        cancelToken.cancel()
        statusMessage = "Abbruch wird angefordert …"
    }

    private func resetCounters() {
        totalFilesToCopy = 0; processedFiles = 0
        copiedCount = 0; skippedCount = 0; failedCount = 0
        totalBytesToCopy = 0; bytesTransferred = 0
        currentFileName = ""; currentFileSize = 0; currentFileBytes = 0
        errors = []
        timeAnomalyCount = 0
        writeDeniedHintShown = false
    }

    // MARK: - Hauptablauf

    private func run(config: TransferConfig, password: String, sources: [SourceFolder]) async {
        Log.write("=== Backup-Start: \(config.host)/\(config.share) Ziel=\(config.targetSubpath.isEmpty ? "(Wurzel)" : config.targetSubpath) Benutzer=\(config.username.isEmpty ? "(guest)" : config.username) Quellen=\(sources.count)")
        var accessedRoots: [URL] = []
        defer {
            for url in accessedRoots { url.stopAccessingSecurityScopedResource() }
            keepScreenAwake(false)
            endBackgroundGrace()
        }

        // 1) Quell-Bookmarks auflösen und Zugriff öffnen.
        var roots: [(url: URL, name: String)] = []
        for source in sources {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: source.bookmark, options: [],
                relativeTo: nil, bookmarkDataIsStale: &stale
            ) else { continue }
            if url.startAccessingSecurityScopedResource() { accessedRoots.append(url) }
            roots.append((url, source.displayName))
        }
        guard !roots.isEmpty else {
            finish(.failed, "Keine gültige Quelle. Bitte Ordner neu auswählen.")
            return
        }

        // 1b) Overlap-Dedup: verschachtelte/doppelte Quellen zusammenführen, damit keine
        // Datei doppelt kopiert wird (z. B. wenn ein Ordner in einem anderen ausgewählten liegt).
        let mergedRoots = dedupeRoots(roots)
        let mergedAway = roots.count - mergedRoots.count
        roots = mergedRoots

        // 2) Quellen rekursiv scannen -> geplante Dateien.
        // Datums-/Zeit-Suffix (falls aktiv) kommt an den ZIELordner dieses Laufs — NICHT an die
        // kopierten Quellordner. So landet jeder Lauf in einem eigenen Zeitstempel-Ordner
        // (z. B. „STEFAN_OTT_260611_143022/Downloads/…"); die Quellordner behalten ihren Namen.
        let datedTarget = makeDatedTarget(base: config.targetSubpath, enabled: config.appendDateSuffix)
        var planned: [PlannedFile] = []
        for root in roots {
            if cancelToken.isCancelled { finish(.cancelled, "Abgebrochen."); return }
            planned.append(contentsOf: scan(root: root.url, targetSubpath: datedTarget, folderName: root.name))
        }

        // 3) Pre-Flight: aktiver Probe-Connect + Klartext-Diagnose (Netz / Berechtigung).
        strictTimeCheck = config.strictTimeCheck
        Log.write(Preflight.environmentReport(host: config.host, share: config.share,
                                              user: config.username, proto: config.proto.label))
        statusMessage = "Prüfe Netzwerkweg …"
        let pre = await Preflight.probe(host: config.host, defaultPort: config.probePort)
        Log.write("Pre-Flight: \(pre) — \(pre.message)")
        if !pre.isOK {
            finish(.failed, pre.message)
            return
        }

        // 4) Verbinden und Remote-Bestand einmalig erfassen.
        statusMessage = "Verbinde mit \(config.host) …"
        let session: RemoteTransport = TransportFactory.make(config: config, password: password)
        do {
            try await session.connect()
        } catch {
            finish(.failed, "Verbindung fehlgeschlagen: \(error.localizedDescription)")
            return
        }
        statusMessage = "Vergleiche mit Ziel …"
        // Nur die Ziel-Ordner erfassen, in denen geplante Dateien landen (deren Eltern) —
        // nicht den ganzen Bestand. Spart bei FTP tausende Listing-Roundtrips.
        let scope: Set<String> = Set(planned.map {
            SMBSession.normalize(($0.remotePath as NSString).deletingLastPathComponent)
        })
        let token = cancelToken
        let snapshot: RemoteSnapshot
        do {
            snapshot = try await session.snapshot(basePath: datedTarget,
                                                  scope: scope,
                                                  isCancelled: { token.isCancelled })
        } catch {
            await session.disconnect()
            if cancelToken.isCancelled { finish(.cancelled, "Abgebrochen."); return }
            finish(.failed, "Ziel konnte nicht gelesen werden: \(error.localizedDescription)")
            return
        }
        let remoteMap = snapshot.files

        // Bereits existierende Verzeichnisse vormerken, damit wir sie NICHT neu anzulegen
        // versuchen (Kollision würde libsmb2 stören). Inkl. des Basis-Zielordners selbst.
        var createdDirs = snapshot.directories
        if snapshot.baseExists {
            let base = SMBSession.normalize(datedTarget)
            if !base.isEmpty {
                var cur = ""
                for p in base.split(separator: "/") {
                    cur = cur.isEmpty ? String(p) : cur + "/" + String(p)
                    createdDirs.insert(cur)
                }
            }
        }

        // 4) Abgleich: was muss kopiert werden?
        var queue: [PlannedFile] = []
        for file in planned {
            let decision = decide(file: file, remote: remoteMap)
            if decision.shouldCopy {
                queue.append(file)
            } else {
                skippedCount += 1
            }
        }
        totalFilesToCopy = queue.count
        totalBytesToCopy = queue.reduce(0) { $0 + $1.size }
        Log.write("Abgleich: \(queue.count) zu kopieren, \(skippedCount) übersprungen "
            + "(Kriterium: Größe\(strictTimeCheck ? " + Zeit (streng)" : ""))")
        if timeAnomalyCount > 0 {
            Log.write("Hinweis: \(timeAnomalyCount) Datei(en) mit Stunden-Zeitversatz "
                + "(Zeitzone/DST/FAT) — werden über die Größe korrekt übersprungen, nicht neu kopiert.")
        }

        if queue.isEmpty {
            await session.disconnect()
            finish(.finished, "Alles aktuell – nichts zu kopieren.")
            return
        }

        // 5) Kopieren – Datei für Datei, mit Reconnect + Retry.
        phase = .copying
        for file in queue {
            if cancelToken.isCancelled { break }
            currentFileName = file.remotePath
            currentFileSize = file.size
            currentFileBytes = 0

            let parent = (file.remotePath as NSString).deletingLastPathComponent
            do {
                try await session.ensureDirectory(parent, created: &createdDirs)
            } catch {
                // Verzeichnis ließ sich nicht anlegen -> Reconnect versuchen und weiter.
                try? await session.connect()
            }

            let outcome = await copyWithRetry(file: file, session: session)
            processedFiles += 1
            switch outcome {
            case .success:
                copiedCount += 1
                bytesTransferred += file.size
            case .cancelled:
                break
            case .failure(let message):
                failedCount += 1
                errors.append(FileResult(relativePath: file.remotePath, outcome: .failed, bytes: file.size, message: message))
                Log.write("FEHLER \(file.remotePath): \(message)")
            }
            currentFileBytes = 0
        }

        await session.disconnect()

        let mergeNote = mergedAway > 0 ? " (\(mergedAway) überlappende Quelle(n) zusammengeführt)" : ""
        if cancelToken.isCancelled {
            finish(.cancelled, "Abgebrochen. \(copiedCount) kopiert, \(failedCount) fehlgeschlagen.\(mergeNote)")
        } else {
            finish(.finished, "Fertig. \(copiedCount) kopiert, \(skippedCount) übersprungen, \(failedCount) fehlgeschlagen.\(mergeNote)")
        }
    }

    private enum CopyOutcome {
        case success
        case cancelled
        case failure(String)
    }

    /// Kopiert eine Datei mit bis zu `maxAttempts` Versuchen. Vor jedem Wiederholversuch
    /// wird die SMB-Verbindung neu aufgebaut (heilt „broken pipe"). Danach wird die
    /// Änderungszeit am Ziel gesetzt.
    private func copyWithRetry(
        file: PlannedFile, session: RemoteTransport
    ) async -> CopyOutcome {
        let token = cancelToken
        // Fortschritt an MainActor bridgen, Abbruch über den Token prüfen.
        let progress: @Sendable (Int64) -> Bool = { [weak self] bytes in
            Task { @MainActor in self?.currentFileBytes = bytes }
            return !token.isCancelled
        }

        var lastError = "Unbekannter Fehler"
        for attempt in 1...maxAttempts {
            if token.isCancelled { return .cancelled }
            do {
                try await session.upload(localURL: file.sourceURL, to: file.remotePath, onProgress: progress)
                // Zeitstempel setzen, damit der nächste Lauf korrekt überspringt (best effort).
                try? await session.setModificationDate(file.modificationDate, at: file.remotePath)
                return .success
            } catch {
                if token.isCancelled { return .cancelled }
                lastError = error.localizedDescription
                // Dauerhafte Fehler (z. B. FTP 5xx „Permission denied"/„No such file") nicht
                // wiederholen — Reconnect/Retry hilft nicht und produziert nur Lärm.
                if Self.isPermanent(error) {
                    maybeShowWriteDeniedHint(error)
                    return .failure(lastError)
                }
                if attempt < maxAttempts {
                    statusMessage = "Fehler bei \(file.remotePath) – neuer Versuch (\(attempt)/\(maxAttempts - 1)) …"
                    // Verbindung neu aufbauen. Den Verzeichnis-Cache NICHT verwerfen — die
                    // Ordner bleiben auf dem Server bestehen; ein Neu-Anlegen würde kollidieren.
                    try? await session.connect()
                    let backoff = UInt64(500_000_000) * UInt64(attempt) // 0,5s * Versuch
                    try? await Task.sleep(nanoseconds: backoff)
                }
            }
        }
        return .failure(lastError)
    }

    // MARK: - Scan & Vergleich

    /// Entfernt Quellen, die identisch mit einer anderen sind oder in einer anderen
    /// ausgewählten Quelle liegen (verschachtelt). Behält die obersten Vorfahren.
    private func dedupeRoots(_ roots: [(url: URL, name: String)]) -> [(url: URL, name: String)] {
        // Nach Pfadlänge aufsteigend -> Vorfahren werden zuerst geprüft/behalten.
        let sorted = roots.sorted { $0.url.standardizedFileURL.path.count < $1.url.standardizedFileURL.path.count }
        var kept: [(url: URL, name: String)] = []
        for r in sorted {
            let rPath = r.url.standardizedFileURL.path
            let rPathSlash = rPath.hasSuffix("/") ? rPath : rPath + "/"
            let containedInKept = kept.contains { k in
                let kPath = k.url.standardizedFileURL.path
                let kPathSlash = kPath.hasSuffix("/") ? kPath : kPath + "/"
                return rPath == kPath || rPathSlash.hasPrefix(kPathSlash)
            }
            if !containedInKept { kept.append(r) }
        }
        return kept
    }

    private func scan(root: URL, targetSubpath: String, folderName: String) -> [PlannedFile] {
        var files: [PlannedFile] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: []
        ) else { return files }

        for case let fileURL as URL in enumerator {
            if cancelToken.isCancelled { break }
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let size = Int64(values?.fileSize ?? 0)
            let mdate = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)

            let filePath = fileURL.standardizedFileURL.path
            var rel = filePath.hasPrefix(rootPath) ? String(filePath.dropFirst(rootPath.count)) : fileURL.lastPathComponent
            while rel.hasPrefix("/") { rel.removeFirst() }

            let remotePath = [targetSubpath, folderName, rel]
                .map { SMBSession.normalize($0) }
                .filter { !$0.isEmpty }
                .joined(separator: "/")

            files.append(PlannedFile(sourceURL: fileURL, remotePath: remotePath, size: size, modificationDate: mdate))
        }
        return files
    }

    private func decide(file: PlannedFile, remote: [String: RemoteEntry]) -> SkipDecision {
        guard let entry = remote[SMBSession.normalize(file.remotePath)] else { return .copyMissing }
        if entry.size != file.size { return .copyDifferentSize }
        // Größe gleich. Default: überspringen (zeitzonensicher). mtime nur für Diagnose /
        // optionalen strengen Modus — FAT/DST/Zeitzonen-Versatz darf NICHT zum Neu-Kopieren führen.
        if let rdate = entry.modificationDate {
            let diff = file.modificationDate.timeIntervalSince(rdate)
            if Self.looksLikeTimezoneOffset(diff) { timeAnomalyCount += 1 }
            if strictTimeCheck, diff > 2, !Self.looksLikeTimezoneOffset(diff) {
                return .copyNewer
            }
        }
        return .skipUpToDate
    }

    /// Erkennt einen Versatz, der nach Zeitzone/DST/FAT aussieht (nahe einem ganzen
    /// Stundenvielfachen, ≥ 30 min) — solche Differenzen NICHT als „neuer" werten.
    static func looksLikeTimezoneOffset(_ diff: TimeInterval) -> Bool {
        let a = abs(diff)
        guard a >= 1800 else { return false }
        let hours = (a / 3600).rounded()
        return hours >= 1 && abs(a - hours * 3600) < 120
    }

    private func makeDateSuffix(enabled: Bool) -> String {
        guard enabled else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMdd_HHmmss"
        return "_" + f.string(from: Date())
    }

    /// Hängt (falls aktiv) das Datums-/Zeit-Suffix an den ZIELordner-Pfad dieses Laufs an.
    /// Bei leerem Ziel (Freigabe-Wurzel) entsteht ein eigener Lauf-Ordner ohne führenden „_".
    private func makeDatedTarget(base: String, enabled: Bool) -> String {
        let suffix = makeDateSuffix(enabled: enabled)   // "" oder "_yyMMdd_HHmmss"
        guard !suffix.isEmpty else { return base }
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? String(suffix.dropFirst()) : trimmed + suffix
    }

    private func finish(_ phase: Phase, _ message: String) {
        self.phase = phase
        self.statusMessage = message
        Log.write("ENDE [\(phase)] \(message)")
        self.finishedAt = Date()
        self.currentFileName = ""
        self.currentFileBytes = 0
    }

    // MARK: - Gerät wachhalten / Hintergrund-Schonfrist

    private func keepScreenAwake(_ on: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    private func beginBackgroundGrace() {
        #if canImport(UIKit)
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "NASBackupTransfer") { [weak self] in
            self?.endBackgroundGrace()
        }
        #endif
    }

    private func endBackgroundGrace() {
        #if canImport(UIKit)
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        #endif
    }
}
