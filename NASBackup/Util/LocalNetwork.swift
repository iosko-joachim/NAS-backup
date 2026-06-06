import Foundation
import Network

/// Löst den iOS-Systemdialog „Lokales Netzwerk" zuverlässig aus.
///
/// Hintergrund: libsmb2 verbindet sich über rohe BSD-Sockets. Diese triggern den
/// Local-Network-Privacy-Dialog von iOS NICHT zuverlässig — ohne erteilte Erlaubnis
/// blockt iOS die Verbindung und libsmb2 meldet EPERM (= „Error 1"). Ein kurzer
/// Bonjour-Browse über Network.framework provoziert den Dialog zuverlässig; nach der
/// Zustimmung funktionieren auch die Socket-Verbindungen der App.
enum LocalNetwork {
    private static var browser: NWBrowser?

    /// Startet einen kurzen Bonjour-Browse (SMB-Dienst), um die Berechtigungsabfrage auszulösen.
    static func requestPermission() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: NWParameters())
        b.stateUpdateHandler = { _ in }
        b.browseResultsChangedHandler = { _, _ in }
        browser = b
        b.start(queue: .main)
        // Nach ein paar Sekunden wieder beenden — der Dialog ist dann längst erschienen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            b.cancel()
            browser = nil
        }
    }
}
