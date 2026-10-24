import AppKit
import BowCore

// The S3 area of the adapter: E2ES3App over E2E/Engine/BowS3Probe, addressing each page's tab by its ID.

extension E2ETestApp: E2ES3App {
    func s3SetWasHidden(_ hidden: Bool, _ page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "call WasHidden")
        return BowS3Probe.setWasHidden(hidden, forTab: try Self.s3TabID(page))
    }

    func s3SetAudioMuted(_ muted: Bool, _ page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "call SetAudioMuted")
        return BowS3Probe.setAudioMuted(muted, forTab: try Self.s3TabID(page))
    }

    func s3IsAudioMuted(_ page: any E2EPage) throws -> Bool {
        BowS3Probe.isAudioMuted(forTab: try Self.s3TabID(page))
    }

    func s3SetWindowlessFrameRate(_ rate: Int, _ page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "call SetWindowlessFrameRate")
        return BowS3Probe.setWindowlessFrameRate(Int32(rate), forTab: try Self.s3TabID(page))
    }

    func s3TaskSample(_ page: any E2EPage) throws -> E2ES3TaskSample? {
        guard let sample = BowS3Probe.taskSample(forTab: try Self.s3TabID(page)) else { return nil }
        // JSON has no NaN, which the task manager can report before its first CPU refresh.
        let cpu = sample.cpuUsage.isFinite ? sample.cpuUsage : 0
        return E2ES3TaskSample(cpu: cpu, memory: sample.memory, gpuMemory: sample.gpuMemory)
    }

    func s3SetFrozen(_ frozen: Bool, _ page: any E2EPage) async throws {
        let state = frozen ? "frozen" : "active"
        _ = try await E2EAppAdapter.tabPage(page).devTools("Page.setWebLifecycleState", ["state": state])
    }

    private static func s3TabID(_ page: any E2EPage) throws -> UInt64 {
        try E2EAppAdapter.tabPage(page).tab.tabID.rawValue
    }
}
