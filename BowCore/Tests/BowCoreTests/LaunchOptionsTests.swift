import Testing

@testable import BowCore

@Suite struct LaunchOptionsTests {
    @Test func defaultsToANormalLaunch() throws {
        let options = try LaunchOptions.parse(["/Bow"])
        #expect(options == LaunchOptions())
        #expect(!options.isSmokeTest)
        #expect(options.smokeQuit == .terminate)
    }

    @Test func readsTheSmokeTestInput() throws {
        let options = try LaunchOptions.parse(["/Bow", "--smoke-test=https://example.com"])
        #expect(options.smokeInput == "https://example.com")
        #expect(options.isSmokeTest)
    }

    @Test func readsEveryQuitMethod() throws {
        for method in LaunchOptions.QuitMethod.allCases {
            let options = try LaunchOptions.parse(["/Bow", "--smoke-quit=\(method.rawValue)"])
            #expect(options.smokeQuit == method)
        }
        let closing = try LaunchOptions.parse(["/Bow", "--smoke-quit=close-window"])
        #expect(closing.smokeQuit == .closeWindow)
    }

    @Test func ignoresSwitchesItDoesNotKnow() throws {
        let options = try LaunchOptions.parse(["/Bow", "-NSDocumentRevisionsDebugMode", "YES", "--smoke-testing=x"])
        #expect(options == LaunchOptions())
    }

    @Test func rejectsBadValues() {
        #expect(throws: LaunchOptions.ParseError.invalidValue("--smoke-quit", "later")) {
            try LaunchOptions.parse(["/Bow", "--smoke-quit=later"])
        }
        #expect(throws: LaunchOptions.ParseError.missingValue("--smoke-test")) {
            try LaunchOptions.parse(["/Bow", "--smoke-test="])
        }
        #expect(throws: LaunchOptions.ParseError.missingValue("--smoke-quit")) {
            try LaunchOptions.parse(["/Bow", "--smoke-quit"])
        }
    }

    @Test func readsAnE2ERun() throws {
        let options = try LaunchOptions.parse(["/Bow", "--e2e=all", "--e2e-out=build/e2e/run"])
        #expect(options.e2eTest == "all")
        #expect(options.e2eOutput == "build/e2e/run")
        #expect(options.isE2E)
        #expect(!options.isSmokeTest)
        let reversed = try LaunchOptions.parse(["/Bow", "--e2e-out=/tmp/run", "--e2e=app.quit"])
        #expect(reversed == LaunchOptions(e2eTest: "app.quit", e2eOutput: "/tmp/run"))
    }

    @Test func rejectsIncompleteOrMixedE2ERuns() {
        #expect(throws: LaunchOptions.ParseError.missingSwitch("--e2e-out", requiredBy: "--e2e")) {
            try LaunchOptions.parse(["/Bow", "--e2e=all"])
        }
        #expect(throws: LaunchOptions.ParseError.missingSwitch("--e2e", requiredBy: "--e2e-out")) {
            try LaunchOptions.parse(["/Bow", "--e2e-out=/tmp/run"])
        }
        #expect(throws: LaunchOptions.ParseError.missingValue("--e2e")) {
            try LaunchOptions.parse(["/Bow", "--e2e=", "--e2e-out=/tmp/run"])
        }
        #expect(throws: LaunchOptions.ParseError.conflictingSwitches("--smoke-test", "--e2e")) {
            try LaunchOptions.parse(["/Bow", "--e2e=all", "--e2e-out=/tmp/run", "--smoke-test=example.com"])
        }
    }
}
