import Foundation

/// Where window sidebars live: one folder per running Bow process in the temporary directory, named after its process
/// ID. A window opened on an explicit engine profile (an e2e window, a smoke run) keeps its sidebar there, and the
/// process removes its folder when it stops; a process that crashed leaves its folder behind, so the next launch
/// clears the folders of processes that are no longer running.
public enum WindowSidebarFolders {
    /// Every window sidebar folder's name starts with this, followed by its process ID.
    public static let prefix = "bow-sidebars-"

    /// The window sidebar folder of process `processID` inside `parent`.
    public static func folder(in parent: URL, processID: Int32) -> URL {
        parent.appendingPathComponent("\(prefix)\(processID)", isDirectory: true)
    }

    /// Removes the window sidebar folders in `parent` whose process is not running, and returns them. Other files and
    /// folders, and the folders of running processes (another Bow, an e2e run in another checkout), are left alone.
    @discardableResult
    public static func removeStale(
        in parent: URL,
        isRunning: (Int32) -> Bool = processIsRunning
    ) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        var removed: [URL] = []
        for name in names.sorted() where name.hasPrefix(prefix) {
            guard let processID = Int32(name.dropFirst(prefix.count)), processID > 0, !isRunning(processID) else {
                continue
            }
            let url = parent.appendingPathComponent(name, isDirectory: true)
            if (try? FileManager.default.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }

    /// Whether a process with this ID exists. One owned by another user still counts as running.
    public static func processIsRunning(_ processID: Int32) -> Bool {
        kill(processID, 0) == 0 || errno == EPERM
    }
}
