import Foundation

/// Tests of the certificate trust data Chromium keeps current between engine updates through its component updater:
/// the certificate revocation list (CRLSet) and the PKI metadata (the Chrome Root Store and the Certificate
/// Transparency log list). They read the updater through CEF (`BowComponentUpdaterProbe`) and never reach the network:
/// every run resolves no host but the fixtures' own, so an update check fails before it leaves the machine.
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

/// With the updater on, as the app runs it, the trust data components are registered with Chromium's updater, and
/// an update check of the CRLSet goes to the update server (which this run cannot resolve, so it fails as an update
/// check error rather than a service or registration error). Selected by name only, since it needs the updater
/// switch the other tests leave on: `make e2e E2E=certs.components`.
struct CertsComponentsTest: E2ETest {
    let name = "certs.components"
    var selectedByNameOnly: Bool { true }
    var switchOverride: E2ESwitchOverride? { E2ESwitchOverride(removing: ["disable-component-update"]) }
    let checks = ["certs.components.registered", "certs.components.update-check"]

    func run(_ run: E2ERun) async throws {
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

        let result = try await run.step("check the CRLSet for an update", timeout: E2ETimeouts.firstLoad) {
            await withCheckedContinuation { continuation in
                BowComponentUpdaterProbe.checkForUpdate(of: E2ECertComponent.crlSet.rawValue) {
                    continuation.resume(returning: $0)
                }
            }
        }
        let after = BowComponentUpdaterProbe.registeredComponents().filter { wanted.contains($0.componentID) }
        run.check(
            "certs.components.update-check", passed: result == "update check error",
            "result=\(result), after=\(after.map(\.e2eSummary))")
    }
}
