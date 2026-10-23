import Foundation

/// Where one running Bow process keeps the History copies an import reads, and which leftovers it may delete.
///
/// The copies live in `<data directory>/Import Scratch/<process ID>/`, under the app's own data directory and never in
/// a temporary folder other processes share, so one Bow (the person's, or an e2e run in another checkout) can never
/// delete another's copy while it is being read. A process deletes its own folder when it quits, and at launch only
/// the folders of processes that are no longer running; a folder whose name is not a process ID is never touched.
public struct ImportScratchFolder: Sendable, Equatable {
    /// The folder inside the data directory that holds every process's scratch folder.
    public static let rootName = "Import Scratch"

    /// The `Import Scratch` folder.
    public let root: URL
    /// The process this scratch folder belongs to.
    public let processID: Int32

    public init(dataDirectory: URL, processID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        root = dataDirectory.appendingPathComponent(Self.rootName, isDirectory: true)
        self.processID = processID
    }

    /// This process's folder, where its History copies go.
    public var url: URL { root.appendingPathComponent(String(processID), isDirectory: true) }

    /// The entries of the root that are leftovers: named with a process ID that is not this process's and is not
    /// running. Anything else, including a running process's folder, stays.
    public static func staleEntries(_ names: [String], processID: Int32, isRunning: (Int32) -> Bool) -> [String] {
        names.filter { name in
            guard let pid = Int32(name), pid > 0, String(pid) == name else { return false }
            return pid != processID && !isRunning(pid)
        }
    }

    /// Deletes the folders `staleEntries` names, left behind by a Bow that quit or crashed mid-read.
    public func removeStale(isRunning: (Int32) -> Bool = Self.isProcessRunning) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in Self.staleEntries(names, processID: processID, isRunning: isRunning) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// Deletes this process's folder, and nothing else.
    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Whether a process with this ID is running (one owned by another user counts as running).
    public static func isProcessRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
