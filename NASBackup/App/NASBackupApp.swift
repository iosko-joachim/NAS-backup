import SwiftUI
import AMSMB2

@main
struct NASBackupApp: App {
    init() {
        // libsmb2-Fehlermeldungen (echter Grund) ins App-Log umleiten.
        SMB2DebugLog.hook = { message in
            Log.write("smb2: \(message)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
