import AppKit
import BowCore

// Key events the app may claim before the page sees them.

extension CEFTab {
    func tab(_ tab: BowTab, handleKeyBeforePage event: BowKeyEvent) -> Bool {
        delegate?.tab(self, handleKeyBeforePage: EngineKeyEvent(event)) ?? false
    }
}
