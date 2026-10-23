import AppKit
import BowCore

// The bridge tab's UI delegate calls: state, close, popups, fullscreen, render process exits, find and permissions.

extension CEFTab: BowTabUIDelegate {
    func tab(_ tab: BowTab, didChangeState state: BowTabState) {
        send(.stateChanged(EngineTabState(state)))
    }

    func tabDidClose(_ tab: BowTab) {
        send(.closed)
    }

    func tab(_ tab: BowTab, didRequestPopup request: BowPopupRequest) {
        send(.popupRequested(PopupRequest(request)))
    }

    func tab(_ tab: BowTab, fullscreenChanged isFullscreen: Bool) {
        send(.fullscreenChanged(isFullscreen))
    }

    func tab(_ tab: BowTab, renderProcessGone reason: BowProcessGoneReason) {
        send(.renderProcessGone(ProcessGoneReason(reason)))
    }

    func tab(_ tab: BowTab, didUpdateFindResult result: BowFindResult) {
        send(
            .findResult(
                FindResult(
                    matchCount: result.matchCount, activeMatch: result.activeMatch, isFinal: result.isFinalUpdate)))
    }

    func tab(
        _ tab: BowTab,
        requestPermission request: BowPermissionRequest,
        decisionHandler: @escaping (BowPermissionRequest.Decision) -> Void
    ) {
        let request = PermissionRequest(origin: request.requestingOrigin, kinds: Set(request.kinds))
        Task { @MainActor [weak self] in
            var decision = PermissionDecision.dismiss
            if let self, let delegate = self.delegate {
                decision = await delegate.tab(self, decidePermission: request)
            }
            switch decision {
            case .allow: decisionHandler(.allow)
            case .deny: decisionHandler(.deny)
            case .dismiss: decisionHandler(.dismiss)
            }
        }
    }
}
