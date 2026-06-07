import Foundation
import Network

enum FTPError: LocalizedError {
    case connectFailed(String)
    case connectionClosed
    case unexpectedReply(Int, String)
    case notConnected
    case tlsNotSupported
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connectFailed(let m): return "FTP-Verbindung fehlgeschlagen: \(m)"
        case .connectionClosed: return "FTP-Verbindung geschlossen."
        case .unexpectedReply(let c, let t): return "FTP-Fehler \(c): \(t)"
        case .notConnected: return "Keine FTP-Verbindung."
        case .tlsNotSupported: return "FTPS ist noch nicht implementiert — bitte FTP (ohne TLS) nutzen."
        case .cancelled: return "Abgebrochen."
        }
    }
}

/// Minimaler FTP-Client über Network.framework (NWConnection).
/// Bewusst NICHT libcurl/rohe Sockets: NWConnection ist der Apple-Privacy-integrierte Pfad,
/// dadurch greift die „Lokales Netzwerk"-Erlaubnis sauber (kein EPERM wie bei rohen Sockets).
/// Implementiert plain FTP (passiv). FTPS folgt später.
final class FTPSession: RemoteTransport, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let user: String
    private let password: String
    private let useTLS: Bool

    private let queue = DispatchQueue(label: "ftp.session")
    private var control: NWConnection?
    private var lineBuffer = ""
    private var preferList = false        // FRITZ!Box & Co. können kein MLSD -> LIST
    private var mfmtUnsupported = false    // FRITZ!Box kann kein MFMT -> mtime nicht setzbar

    init(config: TransferConfig, password: String) {
        // evtl. ":port" aus host entfernen (FTP nutzt eigenes Portfeld)
        var h = config.host.trimmingCharacters(in: .whitespaces)
        if let idx = h.lastIndex(of: ":"), Int(h[h.index(after: idx)...]) != nil {
            h = String(h[..<idx])
        }
        self.host = h
        self.port = UInt16(config.ftpPort)
        self.user = config.username.isEmpty ? "anonymous" : config.username
        self.password = password
        self.useTLS = config.ftps
    }

    // MARK: - RemoteTransport

    func connect() async throws {
        if useTLS { throw FTPError.tlsNotSupported }
        await disconnect()
        lineBuffer = ""
        control = try await openConnection(host: host, port: port)
        _ = try await readReply()                       // 220 Greeting
        let u = try await command("USER \(user)")
        if u.code == 331 {                              // Passwort erwartet
            let p = try await command("PASS \(password)", sensitive: true)
            try expect(p, 230)
        } else if u.code != 230 {
            throw FTPError.unexpectedReply(u.code, u.text)
        }
        try expect(try await command("TYPE I"), 200)    // Binärmodus
    }

    func test() async throws {
        try await connect()
        _ = try await command("NOOP")
        // Diagnose: Wo startet FTP wirklich (kann sich vom Web-/SMB-Pfad unterscheiden!),
        // und was liegt an der FTP-Wurzel? Beantwortet „taucht die USB-Platte hier auf?".
        if let pwd = try? await command("PWD") {
            Log.write("ftp: Login-Verzeichnis (PWD) ⇐ \(pwd.text)")
        }
        if let root = try? await listing(path: "") {
            let names = root.map { $0.isDir ? "[\($0.name)]" : $0.name }
            Log.write("ftp: Inhalt der FTP-Wurzel: \(names.isEmpty ? "(leer)" : names.joined(separator: ", "))")
        }
    }

    func disconnect() async {
        if let control {
            try? await send(control, Data("QUIT\r\n".utf8))
            control.cancel()
        }
        control = nil
    }

    func snapshot(basePath: String) async throws -> RemoteSnapshot {
        var snap = RemoteSnapshot()
        let base = SMBSession.normalize(basePath)
        do {
            try await mlsdRecursive(path: base, into: &snap)
            snap.baseExists = true
        } catch {
            // Basisordner existiert evtl. nicht -> leer behandeln.
            return RemoteSnapshot()
        }
        return snap
    }

    func listDirectories(atPath basePath: String) async throws -> [String] {
        let entries = try await listing(path: SMBSession.normalize(basePath))
        return entries.filter { $0.isDir }.map { $0.name }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func makeDirectory(_ path: String) async throws {
        var created = Set<String>()
        try await ensureDirectory(path, created: &created)
    }

    func ensureDirectory(_ directoryPath: String, created: inout Set<String>) async throws {
        let normalized = SMBSession.normalize(directoryPath)
        guard !normalized.isEmpty else { return }
        var current = ""
        for part in normalized.split(separator: "/").map(String.init) {
            current = current.isEmpty ? part : current + "/" + part
            if created.contains(current) { continue }
            let r = try await command("MKD \(current)")
            // 257 = angelegt; 5xx = existiert vermutlich schon -> ignorieren.
            _ = r
            created.insert(current)
        }
    }

    func upload(localURL: URL, to remotePath: String,
                onProgress: @escaping @Sendable (_ bytes: Int64) -> Bool) async throws {
        guard control != nil else { throw FTPError.notConnected }
        let path = SMBSession.normalize(remotePath)
        let data = try await openDataConnection()
        defer { data.cancel() }
        try expect1xx(try await command("STOR \(path)", quiet: true))

        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        var sent: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            if !onProgress(sent) { throw FTPError.cancelled }
            try await send(data, chunk)
            sent += Int64(chunk.count)
        }
        _ = onProgress(sent)
        // Datenkanal halb schließen (EOF signalisieren), dann Abschluss-Reply lesen.
        try await sendEOF(data)
        try expect2xx(try await readReply())            // 226 Transfer complete
    }

    func setModificationDate(_ date: Date, at remotePath: String) async throws {
        // Best effort. Viele FTP-Server (FRITZ!Box) können MFMT nicht — nach dem ersten
        // 5xx dauerhaft abschalten (spart Round-Trips + Log-Lärm). Kriterium ist ohnehin Größe.
        guard !mfmtUnsupported else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        if let r = try? await command("MFMT \(f.string(from: date)) \(SMBSession.normalize(remotePath))"),
           (500..<600).contains(r.code) {
            mfmtUnsupported = true
            Log.write("ftp: MFMT nicht unterstützt → Zeitstempel werden nicht gesetzt (Größen-Abgleich bleibt korrekt)")
        }
    }

    // MARK: - MLSD

    private struct MLSDEntry { let name: String; let isDir: Bool; let size: Int64; let modify: Date? }

    private func mlsdRecursive(path: String, into snap: inout RemoteSnapshot) async throws {
        let entries = try await listing(path: path)
        for e in entries {
            let full = path.isEmpty ? e.name : path + "/" + e.name
            if e.isDir {
                snap.directories.insert(full)
                try await mlsdRecursive(path: full, into: &snap)
            } else {
                snap.files[full] = RemoteEntry(size: e.size, modificationDate: e.modify)
            }
        }
    }

    /// Verzeichnis-Listing mit MLSD; fällt automatisch auf LIST zurück, wenn der Server
    /// MLSD nicht kann (FRITZ!Box → 500). Danach wird dauerhaft LIST genutzt.
    private func listing(path: String) async throws -> [MLSDEntry] {
        if !preferList {
            if let entries = try await tryListing(cmd: path.isEmpty ? "MLSD" : "MLSD \(path)",
                                                  parser: parseMLSD) {
                return entries
            }
            preferList = true
            Log.write("ftp: MLSD nicht unterstützt → nutze LIST")
        }
        if let entries = try await tryListing(cmd: path.isEmpty ? "LIST" : "LIST \(path)",
                                              parser: parseLIST) {
            return entries
        }
        throw FTPError.unexpectedReply(500, "Verzeichnis-Listing fehlgeschlagen")
    }

    /// Führt ein datenkanal-basiertes Listing aus. Liefert `nil`, wenn der Befehl mit 5xx
    /// (nicht unterstützt) abgelehnt wird — dann probiert der Aufrufer eine Alternative.
    private func tryListing(cmd: String, parser: (String) -> [MLSDEntry]) async throws -> [MLSDEntry]? {
        let data = try await openDataConnection()
        defer { data.cancel() }
        let reply = try await command(cmd)
        if (500..<600).contains(reply.code) { return nil }
        try expect1xx(reply)
        var raw = Data()
        while true {
            let (chunk, done) = try await receive(data)
            if let chunk { raw.append(chunk) }
            if done { break }
        }
        try expect2xx(try await readReply())            // 226
        return parser(String(decoding: raw, as: UTF8.self))
    }

    private func parseMLSD(_ text: String) -> [MLSDEntry] {
        var result: [MLSDEntry] = []
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        for rawLine in text.components(separatedBy: "\r\n") where !rawLine.isEmpty {
            // Format: "fact1=val1;fact2=val2; filename"
            guard let sp = rawLine.firstIndex(of: " ") else { continue }
            let factsPart = String(rawLine[..<sp])
            let name = String(rawLine[rawLine.index(after: sp)...])
            if name == "." || name == ".." || name.isEmpty { continue }
            var type = "", size: Int64 = 0, modify: Date?
            for fact in factsPart.split(separator: ";") {
                let kv = fact.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let key = kv[0].lowercased(); let val = String(kv[1])
                switch key {
                case "type": type = val.lowercased()
                case "size": size = Int64(val) ?? 0
                case "modify": modify = f.date(from: String(val.prefix(14)))
                default: break
                }
            }
            if type == "cdir" || type == "pdir" { continue }
            result.append(MLSDEntry(name: name, isDir: type == "dir", size: size, modify: modify))
        }
        return result
    }

    /// Parser für klassisches LIST (Unix `ls -l`-Format), z. B.:
    /// `-rw-r--r--  1 owner group   12345 May 23 21:44 Datei mit Leerzeichen.pdf`
    /// `drwxr-xr-x  2 owner group    4096 Jan 02 17:35 Ordner`
    /// Größe wird zuverlässig gelesen; mtime bleibt offen (Kriterium ist die Größe).
    private func parseLIST(_ text: String) -> [MLSDEntry] {
        var result: [MLSDEntry] = []
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let first = line.first, first == "d" || first == "-" else { continue } // nur Datei/Ordner
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 9 else { continue }
            let size = Int64(cols[4]) ?? 0
            // Name = alles nach den 8 Feldern (behält Leerzeichen im Dateinamen).
            let name = Self.remainderAfterFields(line, fields: 8)
            if name.isEmpty || name == "." || name == ".." { continue }
            result.append(MLSDEntry(name: name, isDir: first == "d", size: size, modify: nil))
        }
        return result
    }

    /// Liefert den Rest einer Zeile nach `fields` whitespace-getrennten Feldern.
    private static func remainderAfterFields(_ line: String, fields: Int) -> String {
        var idx = line.startIndex
        var seen = 0
        var inField = false
        while idx < line.endIndex {
            let c = line[idx]
            if c == " " || c == "\t" {
                if inField { inField = false; if seen == fields { return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces) } }
            } else {
                if !inField { inField = true; seen += 1 }
            }
            idx = line.index(after: idx)
        }
        return ""
    }

    // MARK: - Passiver Datenkanal

    private func openDataConnection() async throws -> NWConnection {
        let r = try await command("PASV")
        guard r.code == 227, let p = parsePASVPort(r.text) else {
            throw FTPError.unexpectedReply(r.code, r.text)
        }
        // Host der PASV-Antwort ignorieren (NAT/Heim-NAS) — Steuer-Host wiederverwenden.
        return try await openConnection(host: host, port: p)
    }

    private func parsePASVPort(_ reply: String) -> UInt16? {
        guard let open = reply.firstIndex(of: "("), let close = reply.firstIndex(of: ")") else { return nil }
        let nums = reply[reply.index(after: open)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 6 else { return nil }
        return UInt16(nums[4] * 256 + nums[5])
    }

    // MARK: - NWConnection-Primitiven

    private func openConnection(host: String, port: UInt16) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw FTPError.connectFailed("Port") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let lock = NSLock(); var done = false
            func finish(_ r: Result<Void, Error>) {
                lock.lock(); let already = done; done = true; lock.unlock()
                if already { return }
                cont.resume(with: r)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let e): finish(.failure(FTPError.connectFailed("\(e)")))
                case .waiting(let e): finish(.failure(FTPError.connectFailed("\(e)")))
                default: break
                }
            }
            conn.start(queue: queue)
        }
        return conn
    }

    private func send(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    private func sendEOF(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    private func receive(_ conn: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data?, Bool), Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: (data, isComplete))
            }
        }
    }

    @discardableResult
    private func command(_ cmd: String, sensitive: Bool = false, quiet: Bool = false) async throws -> (code: Int, text: String) {
        guard let control else { throw FTPError.notConnected }
        try await send(control, Data((cmd + "\r\n").utf8))
        let reply = try await readReply()
        if !quiet {
            let shown = sensitive ? "PASS ****" : cmd
            Log.write("ftp> \(shown)  ⇐ \(reply.code)")
        }
        return reply
    }

    private func readReply() async throws -> (code: Int, text: String) {
        let first = try await nextLine()
        guard first.count >= 4, let code = Int(first.prefix(3)) else {
            throw FTPError.unexpectedReply(0, first)
        }
        let sepIndex = first.index(first.startIndex, offsetBy: 3)
        if first[sepIndex] == " " { return (code, first) }
        // Mehrzeilige Antwort bis "<code> ..."
        var acc = [first]
        while true {
            let line = try await nextLine()
            acc.append(line)
            if line.count >= 4, Int(line.prefix(3)) == code,
               line[line.index(line.startIndex, offsetBy: 3)] == " " {
                return (code, acc.joined(separator: "\n"))
            }
        }
    }

    private func nextLine() async throws -> String {
        while !lineBuffer.contains("\r\n") {
            guard let control else { throw FTPError.notConnected }
            let (data, isComplete) = try await receive(control)
            if let data, !data.isEmpty { lineBuffer += String(decoding: data, as: UTF8.self) }
            if isComplete && !lineBuffer.contains("\r\n") {
                if lineBuffer.isEmpty { throw FTPError.connectionClosed }
                let rest = lineBuffer; lineBuffer = ""; return rest
            }
        }
        let range = lineBuffer.range(of: "\r\n")!
        let line = String(lineBuffer[..<range.lowerBound])
        lineBuffer.removeSubrange(lineBuffer.startIndex..<range.upperBound)
        return line
    }

    // MARK: - Reply-Erwartungen

    private func expect(_ reply: (code: Int, text: String), _ code: Int) throws {
        if reply.code != code { throw FTPError.unexpectedReply(reply.code, reply.text) }
    }
    private func expect1xx(_ reply: (code: Int, text: String)) throws {
        if !(100..<200).contains(reply.code) { throw FTPError.unexpectedReply(reply.code, reply.text) }
    }
    private func expect2xx(_ reply: (code: Int, text: String)) throws {
        if !(200..<300).contains(reply.code) { throw FTPError.unexpectedReply(reply.code, reply.text) }
    }
}
