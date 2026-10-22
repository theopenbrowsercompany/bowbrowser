import Foundation

/// The command line switches the app understands. Every switch is parsed here, so test harnesses extend this
/// one type instead of reading `ProcessInfo` in several places.
public struct LaunchOptions: Equatable, Sendable {
    /// How a smoke run quits once the page has loaded, so each way a person quits can be checked on its own.
    public enum QuitMethod: String, CaseIterable, Sendable {
        /// Calls `NSApp.terminate`, as other code in the app does.
        case terminate
        /// Sends Cmd+Q through the main menu, as a person pressing the shortcut does.
        case menu
        /// Closes the only window, as a person clicking its close button does.
        case closeWindow = "close-window"
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingValue(String)
        case invalidValue(String, String)
        /// The first switch only works together with the second.
        case missingSwitch(String, requiredBy: String)
        /// The two switches cannot be used together.
        case conflictingSwitches(String, String)

        public var description: String {
            switch self {
            case .missingValue(let name): return "\(name) needs a value"
            case .invalidValue(let name, let value): return "\(name)=\(value) is not a valid value"
            case .missingSwitch(let name, let other): return "\(other) needs \(name)"
            case .conflictingSwitches(let first, let second): return "\(first) and \(second) cannot be used together"
            }
        }
    }

    /// What to load for a smoke run (`--smoke-test=<input>`), as typed into the address bar. Nil outside smoke runs.
    public var smokeInput: String?
    /// How the smoke run quits (`--smoke-quit=terminate|menu|close-window`). Defaults to `terminate`.
    public var smokeQuit: QuitMethod = .terminate

    /// The e2e scenario to run (`--e2e=<scenario>`, or `all`). Nil outside e2e runs.
    public var e2eScenario: String?
    /// The folder an e2e run writes its report and temporary profile to (`--e2e-out=<path>`).
    /// Required with `--e2e`; a relative path is relative to the working directory.
    public var e2eOutput: String?

    public var isSmokeTest: Bool { smokeInput != nil }
    public var isE2E: Bool { e2eScenario != nil }

    public init(
        smokeInput: String? = nil,
        smokeQuit: QuitMethod = .terminate,
        e2eScenario: String? = nil,
        e2eOutput: String? = nil
    ) {
        self.smokeInput = smokeInput
        self.smokeQuit = smokeQuit
        self.e2eScenario = e2eScenario
        self.e2eOutput = e2eOutput
    }

    /// Parses `arguments` (the first one is the program path). Switches it does not know are ignored, because
    /// macOS and Chromium pass their own.
    public static func parse(_ arguments: [String]) throws(ParseError) -> LaunchOptions {
        var options = LaunchOptions()
        for argument in arguments.dropFirst() {
            if let value = try value(of: "--smoke-test", in: argument) {
                options.smokeInput = value
            } else if let value = try value(of: "--smoke-quit", in: argument) {
                guard let method = QuitMethod(rawValue: value) else {
                    throw .invalidValue("--smoke-quit", value)
                }
                options.smokeQuit = method
            } else if let value = try value(of: "--e2e-out", in: argument) {
                options.e2eOutput = value
            } else if let value = try value(of: "--e2e", in: argument) {
                options.e2eScenario = value
            }
        }
        if options.isE2E && options.e2eOutput == nil { throw .missingSwitch("--e2e-out", requiredBy: "--e2e") }
        if !options.isE2E && options.e2eOutput != nil { throw .missingSwitch("--e2e", requiredBy: "--e2e-out") }
        if options.isE2E && options.isSmokeTest { throw .conflictingSwitches("--smoke-test", "--e2e") }
        return options
    }

    /// Returns the value of `argument` when it is `name=value`, nil when it is another switch.
    private static func value(of name: String, in argument: String) throws(ParseError) -> String? {
        if argument == name { throw .missingValue(name) }
        guard argument.hasPrefix(name + "=") else { return nil }
        let value = String(argument.dropFirst(name.count + 1))
        if value.isEmpty { throw .missingValue(name) }
        return value
    }
}
