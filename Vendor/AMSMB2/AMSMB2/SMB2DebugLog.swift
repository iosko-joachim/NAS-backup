import Foundation
import SMB2

/// Diagnose-Hook: Host-Apps können hier jede libsmb2-Fehlermeldung mitlesen
/// (gesetzt via `smb2_register_error_callback` in `SMB2Client.init`).
/// So landet der ECHTE Grund (z. B. „Session setup failed (0x…)", „Signing required
/// by server") im App-Log — statt des leeren „Error code 1".
public enum SMB2DebugLog {
    nonisolated(unsafe) public static var hook: (@Sendable (String) -> Void)?
}

/// C-kompatibler Callback für `smb2_register_error_callback`.
func amsmb2_error_callback(_ smb2: UnsafeMutablePointer<smb2_context>?,
                           _ errorString: UnsafePointer<CChar>?) {
    guard let errorString else { return }
    SMB2DebugLog.hook?(String(cString: errorString))
}
