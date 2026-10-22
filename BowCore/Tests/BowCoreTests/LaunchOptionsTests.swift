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
}
