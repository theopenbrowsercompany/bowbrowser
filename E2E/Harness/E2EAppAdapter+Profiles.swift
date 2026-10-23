import AppKit
import BowCore

// The profiles area of the adapter: E2EProfilesApp over the window's shown tab, the app's ProfileRegistryStore and
// the app's child processes.

extension E2EAppAdapter {
    func shownPage(besides page: any E2EPage, token: Int) throws -> (any E2EPage)? {
        let given = try Self.tabPage(page)
        let controller = given.controller
        guard let tab = controller.selectedTab else { return nil }
        if tab === given.tab { return given }
        return track(tab, in: controller, token: token)
    }

    func registeredProfiles() -> [String] {
        let profiles = delegate.appFeatures.require(ProfileRegistryStore.self).registry?.profiles ?? []
        return profiles.map { "\($0.id.rawValue):\($0.name)" }
    }

    /// Counts the app's child processes started as Chromium renderers, read from `ps`.
    func rendererProcessCount() throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let own = ProcessInfo.processInfo.processIdentifier
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            return parts.count == 2 && Int32(parts[0]) == own && parts[1].contains("--type=renderer")
        }.count
    }
}

extension E2ETestApp: E2EProfilesApp {
    func shownPage(besides page: any E2EPage) throws -> (any E2EPage)? {
        try adapter.requireActive(token, "read the shown page")
        return try adapter.shownPage(besides: page, token: token)
    }

    func registeredProfiles() throws -> [String] {
        try adapter.requireActive(token, "read the registered profiles")
        return adapter.registeredProfiles()
    }

    func rendererProcessCount() throws -> Int {
        try adapter.requireActive(token, "count renderer processes")
        return try adapter.rendererProcessCount()
    }
}
