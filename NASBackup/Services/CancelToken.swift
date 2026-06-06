import Foundation

/// Thread-sicheres Abbruch-Flag, das gefahrlos aus den `@Sendable`
/// Fortschritts-Closures von AMSMB2 gelesen werden kann.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    var isCancelled: Bool { lock.withLock { _cancelled } }
    func cancel() { lock.withLock { _cancelled = true } }
    func reset() { lock.withLock { _cancelled = false } }
}
