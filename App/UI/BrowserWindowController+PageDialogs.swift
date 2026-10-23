import AppKit
import BowCore

// The window's engine hook for page dialogs, beside the others in BrowserWindowController.swift: it goes to the
// features only for the window's own tabs, and the first feature that answers decides. Kept in its own file while
// the window core is being changed elsewhere; it belongs with the core's other hooks.

extension BrowserWindowController {
    func tab(_ tab: any EngineTab, runDialog dialog: PageDialog) async -> PageDialogAnswer {
        guard modelID(of: tab) != nil else { return .cancelled }
        for feature in features {
            if let answer = await feature.runDialog(dialog, for: tab) { return answer }
        }
        return .cancelled
    }
}
