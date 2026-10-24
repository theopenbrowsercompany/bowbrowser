import AppKit
import BowCore
import WebKit

// A page's request for a new page in Bow's terms. Nothing here switches over a BowCore enum.

extension PopupRequest {
    /// The request WebKit asks about in `createWebViewWith`: the address, where the page asked it to open and the
    /// window features it passed. WebKit asks only for a request with a user gesture (the profile's configuration
    /// leaves `javaScriptCanOpenWindowsAutomatically` off, see `WebKitProfile.makeConfiguration()`), so every request
    /// reports one.
    @MainActor init(_ action: WKNavigationAction, features: WKWindowFeatures) {
        self.init(
            targetURL: action.request.url, features: PopupWindowFeatures(features), isUserGesture: true,
            modifierFlags: action.modifierFlags, buttonNumber: action.buttonNumber)
    }

    /// The request for `targetURL` with `features`, from the click's modifier keys and mouse button (NSEvent's
    /// numbering, 2 for the middle button). Without a user gesture no click opened it, so it has no modifiers.
    init(
        targetURL: URL?, features: PopupWindowFeatures, isUserGesture: Bool, modifierFlags: NSEvent.ModifierFlags,
        buttonNumber: Int
    ) {
        let modifiers =
            isUserGesture
            ? PopupClickModifiers(
                command: modifierFlags.contains(.command) || buttonNumber == 2, shift: modifierFlags.contains(.shift))
            : .none
        let size = features.width.flatMap { width in features.height.map { PopupSize(width: width, height: $0) } }
        self.init(
            targetURL: targetURL, disposition: PopupDisposition(isPopup: features.isPopup, modifiers: modifiers),
            isUserGesture: isUserGesture, requestedSize: size, windowFeatures: features, clickModifiers: modifiers)
    }
}

extension PopupDisposition {
    /// Where the page asked the new page to open, as Chromium reads it (CEF's disposition): a modified click decides
    /// first (Command or the middle button a background tab, Command Shift a foreground tab, Shift a window), then
    /// features that ask for a popup make one, and anything else is a foreground tab.
    init(isPopup: Bool, modifiers: PopupClickModifiers) {
        if modifiers.command {
            self = modifiers.shift ? .foregroundTab : .backgroundTab
        } else if modifiers.shift {
            self = .window
        } else {
            self = isPopup ? .popup : .foregroundTab
        }
    }
}

extension PopupWindowFeatures {
    /// The features the page passed to `window.open`, as WebKit parsed them.
    @MainActor init(_ features: WKWindowFeatures) {
        self.init(
            x: features.x?.intValue, y: features.y?.intValue, width: features.width?.intValue,
            height: features.height?.intValue,
            isPopup: Self.isPopup(
                hasGeometry: [features.x, features.y, features.width, features.height].contains { $0 != nil },
                menuBar: features.menuBarVisibility?.boolValue, statusBar: features.statusBarVisibility?.boolValue,
                toolbars: features.toolbarsVisibility?.boolValue, resizable: features.allowsResizing?.boolValue))
    }

    /// Whether the features ask for a popup window, as the HTML standard's "is popup" check reads them (and Chromium
    /// does): no features at all is a tab; otherwise a bar or resizing the page left out counts as off, and any bar or
    /// resizing off makes a popup. So a size alone (`width=480,height=560`) is a popup, and only features that turn
    /// every bar and resizing on are a tab. WebKit gives nil for each feature the page did not pass.
    static func isPopup(hasGeometry: Bool, menuBar: Bool?, statusBar: Bool?, toolbars: Bool?, resizable: Bool?) -> Bool
    {
        let bars = [menuBar, statusBar, toolbars, resizable]
        guard hasGeometry || bars.contains(where: { $0 != nil }) else { return false }
        return bars.contains { $0 != true }
    }
}
