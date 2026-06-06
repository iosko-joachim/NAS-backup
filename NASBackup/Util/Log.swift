import Foundation

/// Einfaches, thread-sicheres Datei-Log im Documents-Ordner der App.
/// Über `UIFileSharingEnabled` ist `NASBackup.log` in der Files-App sichtbar
/// (Auf meinem iPhone → NAS Backup) und kann von dort geteilt werden.
enum Log {
    private static let lock = NSLock()
    private static let maxBytes = 2_000_000  // ~2 MB, dann wird rotiert

    static let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("NASBackup.log")
    }()

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(timestamp.string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        rotateIfNeeded()
        if let h = try? FileHandle(forWritingTo: fileURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Leert das Log (für „Protokoll löschen").
    static func clear() {
        lock.lock(); defer { lock.unlock() }
        try? Data().write(to: fileURL)
    }

    private static func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > maxBytes else { return }
        // Hälfte abschneiden: letzte ~1 MB behalten.
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let keep = data.suffix(maxBytes / 2)
        try? keep.write(to: fileURL)
    }
}
