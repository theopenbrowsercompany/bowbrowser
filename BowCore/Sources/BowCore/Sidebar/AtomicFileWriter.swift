import Darwin
import Foundation

/// Writes a file so that a crash at any moment leaves either the old contents or the new ones, never a mix: the data
/// goes to a temporary file in the same folder, is flushed to disk, and then replaces the target in one rename.
struct AtomicFileWriter {
    /// Points in a write where tests can simulate a crash.
    enum Stage: Equatable {
        /// The temporary file is complete and flushed, but the target still has its old contents.
        case temporaryFileWritten
        /// The rename finished; the target has the new contents.
        case renamed
    }

    /// Called at each stage. An error thrown here acts like a crash at that point: the write stops and nothing is
    /// cleaned up, exactly as a killed process would leave things.
    var crashPoint: ((Stage) throws -> Void)?

    struct WriteError: Error, CustomStringConvertible {
        var operation: String
        var code: Int32
        var description: String { "\(operation) failed: \(String(cString: strerror(code)))" }
    }

    func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(
            Self.temporaryPrefix(for: url) + UUID().uuidString + Self.temporarySuffix)

        try writeAndFlush(data, to: temporary)
        try crashPoint?(.temporaryFileWritten)

        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw WriteError(operation: "rename", code: code)
        }
        Self.flushFolder(folder)
        try crashPoint?(.renamed)
    }

    /// Removes temporary files an interrupted write left beside `url`. They are never read: the target is either
    /// still the old file or already the new one.
    static func removeLeftovers(for url: URL) {
        let folder = url.deletingLastPathComponent()
        let prefix = temporaryPrefix(for: url)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(temporarySuffix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    static func temporaryPrefix(for url: URL) -> String { "." + url.lastPathComponent + "." }
    static let temporarySuffix = ".tmp"

    private func writeAndFlush(_ data: Data, to temporary: URL) throws {
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw WriteError(operation: "open", code: errno) }
        var failure: WriteError?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count, let base = buffer.baseAddress {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = WriteError(operation: "write", code: errno)
                    return
                }
                offset += written
            }
        }
        // F_FULLFSYNC asks the drive itself to flush; plain fsync is the fallback where it is unsupported.
        if failure == nil, fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            failure = WriteError(operation: "fsync", code: errno)
        }
        if close(descriptor) != 0, failure == nil { failure = WriteError(operation: "close", code: errno) }
        if let failure {
            unlink(temporary.path)
            throw failure
        }
    }

    /// Flushes the folder entry so the rename itself survives a power loss. Best effort: some file systems refuse it.
    private static func flushFolder(_ folder: URL) {
        let descriptor = open(folder.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }
}
