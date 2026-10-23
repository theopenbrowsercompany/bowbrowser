import AppKit
import BowCore

// The popup decision: where a page's new page goes, and the tab it arrives as when the app wants a tab.

extension CEFTab {
    func tab(_ tab: BowTab, decidePopup request: BowPopupRequest) -> BowPopupRequest.Decision {
        BowPopupRequest.Decision(delegate?.tab(self, decidePopup: PopupRequest(request)) ?? .window)
    }

    func tab(_ tab: BowTab, didOpenPopup newTab: BowTab, request: BowPopupRequest) {
        let popupTab = CEFTab(newTab)
        guard let delegate else {
            newTab.close { _ in }
            return
        }
        delegate.tab(self, didOpenPopup: popupTab, request: PopupRequest(request))
    }
}
