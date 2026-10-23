import Foundation

/// The engine calls of the opt-in hidden tab measurement (E2E/Tests/S3.swift) on one page's tab, beyond what the app
/// does. E2E/Harness/E2EAppAdapter+S3.swift implements it over E2E/Engine/BowS3Probe; every action that changes a
/// tab is refused once the test has ended.
@MainActor
protocol E2ES3App: E2EApp {
    /// Calls WasHidden on the page's browser host (documented as windowless only). Returns false without a browser.
    func s3SetWasHidden(_ hidden: Bool, _ page: any E2EPage) throws -> Bool
    /// Calls SetAudioMuted on the page's browser host. Returns false without a browser.
    func s3SetAudioMuted(_ muted: Bool, _ page: any E2EPage) throws -> Bool
    /// Whether the page's browser host reports its audio muted.
    func s3IsAudioMuted(_ page: any E2EPage) throws -> Bool
    /// Calls SetWindowlessFrameRate on the page's browser host (documented as windowless only). Returns false
    /// without a browser.
    func s3SetWindowlessFrameRate(_ rate: Int, _ page: any E2EPage) throws -> Bool
    /// Chromium's task manager reading for the page's main task, nil when it has none.
    func s3TaskSample(_ page: any E2EPage) throws -> E2ES3TaskSample?
}

/// One task manager reading: CPU (0 to processors × 100) and memory in bytes (-1 for no value yet).
struct E2ES3TaskSample {
    var cpu: Double
    var memory: Int64
    var gpuMemory: Int64
}
