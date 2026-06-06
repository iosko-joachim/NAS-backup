import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// Ergebnis der aktiven Vorab-Prüfung (Probe-Connect).
enum PreflightResult: Equatable {
    case ok
    case blockedLocalNetwork   // iOS blockt den Socket (Local-Network-Berechtigung / VPN / Filter)
    case noRoute               // falsches Netz / Host nicht im Subnetz
    case refused               // Port zu / Dienst nicht aktiv
    case timeout
    case failed(String)

    var isOK: Bool { self == .ok }

    /// Handlungsleitende Klartext-Meldung.
    var message: String {
        switch self {
        case .ok:
            return "Netzwerkweg frei."
        case .blockedLocalNetwork:
            return "iOS blockiert den lokalen Netzwerkzugriff. Falls „Lokales Netzwerk“ in den "
                + "Einstellungen für NAS Backup auf AN steht, hängt der Status: App löschen, "
                + "iPhone neu starten, neu installieren und beim Start „Erlauben“. (Auch VPN / "
                + "Sperrmodus / Inhaltsblocker können das auslösen.)"
        case .noRoute:
            return "Kein Netzwerkweg zum NAS. Ist das iPhone im SELBEN WLAN wie das NAS "
                + "(gleiches 192.168.x-Netz)?"
        case .refused:
            return "Verbindung abgelehnt — auf dem Host ist der Dienst/Port nicht aktiv "
                + "(SMB aktiviert? richtiger Port?)."
        case .timeout:
            return "Zeitüberschreitung — Host antwortet nicht (erreichbar? eingeschaltet?)."
        case .failed(let m):
            return "Netzwerkproblem: \(m)"
        }
    }
}

enum Preflight {
    /// Testet aktiv TCP-Erreichbarkeit zu `host[:port]`. Der Versuch löst zugleich den
    /// iOS-Local-Network-Dialog aus und verrät über den Fehlercode, ob iOS blockt.
    static func probe(host rawHost: String, defaultPort: UInt16 = 445,
                      timeout: TimeInterval = 6) async -> PreflightResult {
        var host = rawHost.trimmingCharacters(in: .whitespaces)
        var port = defaultPort
        if let idx = host.lastIndex(of: ":"),
           let p = UInt16(host[host.index(after: idx)...]) {
            port = p
            host = String(host[..<idx])
        }
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            return .failed("Ungültige Adresse")
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { (cont: CheckedContinuation<PreflightResult, Never>) in
            let lock = NSLock()
            var finished = false
            func finish(_ result: PreflightResult) {
                lock.lock(); let already = finished; finished = true; lock.unlock()
                if already { return }
                conn.cancel()
                cont.resume(returning: result)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.ok)
                case .waiting(let error):
                    // Nur bei eindeutigen Ursachen abbrechen; sonst weiter warten (transient).
                    if let r = classifyDefinitive(error) { finish(r) }
                case .failed(let error):
                    finish(classify(error))
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.timeout) }
        }
    }

    private static func classifyDefinitive(_ err: NWError) -> PreflightResult? {
        if case let .posix(code) = err {
            switch code {
            case .EPERM, .EACCES: return .blockedLocalNetwork
            case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN: return .noRoute
            case .ECONNREFUSED: return .refused
            default: return nil
            }
        }
        return nil
    }

    private static func classify(_ err: NWError) -> PreflightResult {
        classifyDefinitive(err) ?? {
            if case let .posix(code) = err, code == .ETIMEDOUT { return .timeout }
            return .failed("\(err)")
        }()
    }

    /// Umgebungs-Report für den Log-Kopf eines Laufs.
    static func environmentReport(host: String, share: String, user: String, proto: String) -> String {
        var os = "?"
        #if canImport(UIKit)
        os = "iOS " + UIDevice.current.systemVersion
        #endif
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let ip = wifiIPv4() ?? "?"
        let u = user.isEmpty ? "(guest)" : user
        return "Pre-Flight-Umgebung: App \(v) (\(b)), \(os), iPhone-IP \(ip), "
            + "Protokoll \(proto), Ziel \(host)/\(share), Benutzer \(u)"
    }

    /// IPv4-Adresse des WLAN-Interfaces (en0) — für die „falsches Netz"-Diagnose.
    static func wifiIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            let family = p.pointee.ifa_addr.pointee.sa_family
            if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
               family == UInt8(AF_INET),
               let name = p.pointee.ifa_name, String(cString: name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(p.pointee.ifa_addr, socklen_t(p.pointee.ifa_addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: host)
                }
            }
            ptr = p.pointee.ifa_next
        }
        return address
    }
}
