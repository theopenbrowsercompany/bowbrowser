import Foundation

/// Tests of the certificate trust data Chromium keeps current between engine updates through its component updater:
/// the certificate revocation list (CRLSet) and the PKI metadata (the Chrome Root Store and the Certificate
/// Transparency log list). They read the updater through CEF (`BowComponentUpdaterProbe`) and never reach the network:
/// every run resolves no host but the fixtures' own, and `certs.components` sends the update host to a stand-in
/// server on 127.0.0.1, so an update check never leaves the machine.
@MainActor
enum CertsTests {
    static let all: [any E2ETest] = [CertsUpdaterOffTest(), CertsComponentsTest()]
}

/// Chromium's component IDs for the trust data (components/component_updater/installer_policies and
/// chrome/browser/component_updater in Chromium).
enum E2ECertComponent: String, CaseIterable {
    case crlSet = "hfnkpimlhhgieaddgfemjhofmfblmnib"
    case pkiMetadata = "efniojlnjndmcbiieegkicadnoecjjef"

    var label: String {
        switch self {
        case .crlSet: return "CRLSet"
        case .pkiMetadata: return "PKI Metadata (Chrome Root Store and CT log list)"
        }
    }

    /// The folder the component installs into, under Chromium's root data folder.
    var folder: String {
        switch self {
        case .crlSet: return "CertificateRevocation"
        case .pkiMetadata: return "PKIMetadata"
        }
    }
}

extension BowE2EComponent {
    /// `id name version (state)`, with dashes for what is not known yet.
    var e2eSummary: String {
        "\(componentID) \(name.isEmpty ? "-" : name) \(version.isEmpty ? "-" : version) (\(state))"
    }
}

/// Every normal run keeps the updater's regular components off (the harness's `disable-component-update`), so no
/// run asks for trust data: the updater is there, holds no trust data component, and the profile has no folder for
/// one. A feature may still register a component of its own later in a long run (the optimization guide's model
/// manifest does), so the check names the trust data components rather than requiring an empty updater.
struct CertsUpdaterOffTest: E2ETest {
    let name = "certs.updater-off"

    func run(_ run: E2ERun) async throws {
        try await run.step("read the component updater", timeout: E2ETimeouts.step) {
            let available = BowComponentUpdaterProbe.isAvailable()
            let components = BowComponentUpdaterProbe.registeredComponents()
            let trustData = Set(E2ECertComponent.allCases.map(\.rawValue))
            let registered = components.filter { trustData.contains($0.componentID) }
            let folders = E2ECertComponent.allCases.map(\.folder).filter {
                FileManager.default.fileExists(atPath: run.dataDirectory.appendingPathComponent($0).path)
            }
            run.check(
                name, passed: available && registered.isEmpty && folders.isEmpty,
                "updater available=\(available), trust data registered=\(registered.map(\.e2eSummary)), "
                    + "trust data folders=\(folders), all registered=\(components.map(\.e2eSummary))")
        }
    }
}

/// The stand-in for Chromium's update server (`BowE2EUpdateServer`): Chromium's host resolver rules send the update
/// host to it on 127.0.0.1, every other host still resolves to nothing, and it records each request and answers 500.
/// It starts the first time `certs.components` hands the runner its switches, before the engine starts, since the
/// rules need its port then, and listens until the app quits, so repeats in one app all reach it.
@MainActor
enum E2EUpdateServerStandIn {
    /// Where Chromium's component updater sends update checks (components/component_updater's configurator).
    static let host = "update.googleapis.com"
    static let path = "/service/update2/json"
    static let expectedURL = "https://\(host)\(path)"

    static let started: Result<BowE2EUpdateServer, any Error> = Result { try BowE2EUpdateServer.start() }

    /// The running server, or an error saying why it is not running.
    static func running() throws -> BowE2EUpdateServer {
        do {
            return try started.get()
        } catch {
            throw E2EError("the stand-in update server is not running: \(error.localizedDescription)")
        }
    }
}

extension BowE2EUpdateRequest {
    /// The URL the updater asked for, from its Host header and target without the query (CUP's keys change on every
    /// request). `https`, since the stand-in only speaks TLS.
    var e2eURL: String {
        "https://\(host)\(target.prefix { $0 != "?" })"
    }
}

/// With the updater on, as the app runs it, the trust data components are registered with Chromium's updater, and
/// an update check of each one sends a request naming it to the update server, which a stand-in on 127.0.0.1
/// answers with 500, so the check ends as an update check error after the request was made. The check names the URL
/// the updater used, so an engine upgrade that moves it shows up, and fails when no request names a component (an
/// updater without an update URL, or one that never asks). Selected by name only, since it needs the updater switch
/// the other tests leave on: `make e2e E2E=certs.components`.
/// The engine runs with `ignore-certificate-errors` here, since the stand-in serves the loopback fixtures'
/// self-signed certificate and the request is only seen past the handshake; no page loads in this run.
/// The name is a computed property rather than a stored string literal, the form `make done` reads to repeat changed
/// tests in one run, since its switches cannot share a run with `certs.updater-off`; repeat it on its own with
/// `E2E_REPEAT=5 make e2e-run E2E=certs.components`.
struct CertsComponentsTest: E2ETest {
    var name: String { "certs.components" }
    var selectedByNameOnly: Bool { true }
    var switchOverride: E2ESwitchOverride? {
        var adding = ["ignore-certificate-errors": ""]
        // Only the update host goes to the stand-in; the loopback fixtures' hosts are left out, as this test runs
        // alone. Without the stand-in the harness's rule stays, and the test fails saying why.
        if case .success(let server) = E2EUpdateServerStandIn.started {
            adding["host-resolver-rules"] =
                "MAP \(E2EUpdateServerStandIn.host) 127.0.0.1:\(server.port), MAP * ~NOTFOUND"
        }
        return E2ESwitchOverride(removing: ["disable-component-update"], adding: adding)
    }
    let checks = ["certs.components.registered", "certs.components.update-check"]

    func run(_ run: E2ERun) async throws {
        let server = try E2EUpdateServerStandIn.running()
        let wanted = E2ECertComponent.allCases.map(\.rawValue)
        let components = try await run.step("wait for the trust data components", timeout: E2ETimeouts.firstLoad) {
            try await E2EWaits.value(
                { BowComponentUpdaterProbe.registeredComponents() },
                until: { components in wanted.allSatisfy { id in components.contains { $0.componentID == id } } })
        }
        let registered = Set(components.map(\.componentID))
        let missing = E2ECertComponent.allCases.filter { !registered.contains($0.rawValue) }.map(\.label)
        run.check(
            "certs.components.registered", passed: missing.isEmpty,
            "missing=\(missing), registered=\(components.map(\.e2eSummary))")

        // One after another: a second check while the first runs would end as "update in progress".
        var problems: [String] = []
        var seen: [String] = []
        for component in E2ECertComponent.allCases {
            // Only requests that arrive during this component's own check count, so an earlier request that named
            // it (a background check, or the other component's) cannot stand in for one this check never sent.
            let before = server.requests.count
            let result = try await run.step(
                "check the \(component.label) for an update", timeout: E2ETimeouts.firstLoad
            ) {
                await withCheckedContinuation { continuation in
                    BowComponentUpdaterProbe.checkForUpdate(of: component.rawValue) {
                        continuation.resume(returning: $0)
                    }
                }
            }
            // The stand-in records a request before it answers, and the check completes after the answer.
            let requests = server.requests.dropFirst(before).filter { $0.body.contains(component.rawValue) }
            let urls = Array(Set(requests.map { "\($0.method) \($0.e2eURL)" })).sorted()
            seen.append(
                "\(component.label): \(urls.isEmpty ? "no request" : urls.joined(separator: " and ")) (\(result))")
            if requests.isEmpty {
                problems.append("the updater sent no update request naming the \(component.label)")
            } else if !requests.contains(where: {
                $0.method == "POST" && $0.e2eURL == E2EUpdateServerStandIn.expectedURL
            }) {
                problems.append(
                    "the \(component.label) request went to \(urls), not POST \(E2EUpdateServerStandIn.expectedURL)")
            }
            switch result {
            case "update check error": break
            case "update in progress": problems.append("the \(component.label) check overlapped another update")
            default: problems.append("the \(component.label) check ended as \(result), not update check error")
            }
        }
        let after = BowComponentUpdaterProbe.registeredComponents().filter { wanted.contains($0.componentID) }
        run.check(
            "certs.components.update-check", passed: problems.isEmpty,
            (problems.isEmpty ? "" : "\(problems.joined(separator: "; ")); ")
                + "requests: \(seen.joined(separator: ", ")); all requests=\(server.requests.count), "
                + "after=\(after.map(\.e2eSummary))")
    }
}
