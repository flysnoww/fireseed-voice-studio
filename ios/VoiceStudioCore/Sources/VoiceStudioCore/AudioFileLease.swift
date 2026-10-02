import Foundation

/// An operation-owned snapshot. Removing the library/cache entry cannot invalidate it.
/// Call close only when its reader has finished; deinit is a final cleanup safeguard.
public final class AudioFileLease: @unchecked Sendable {
    public let url: URL
    private let directory: URL
    private let lock = NSLock()
    private var closed = false

    public init(source: URL, root: URL = FileManager.default.temporaryDirectory) throws {
        let directory = root.appendingPathComponent("voice-work-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        self.url = directory.appendingPathComponent("audio").appendingPathExtension(source.pathExtension)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: source, to: url) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { close() }
}
