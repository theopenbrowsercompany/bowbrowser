// How a tab reports what its UI shows (state, close) and asks the app for UI: popups, JavaScript dialogs,
// permission prompts, fullscreen, context menus and render process exits. Swift visible: plain Objective-C only,
// never C++ or CEF.
#import <Foundation/Foundation.h>

#import "BowTabUIRequests.h"

@class BowTab;
@class BowTabState;
@class BowFindResult;

NS_ASSUME_NONNULL_BEGIN

/// Receives one tab's requests for UI, always on the main thread. State, fullscreen and find result changes come inside the
/// engine callback that produced them; close, popups, dialogs, permissions, context menus and render process exits
/// come on a later main thread task, so the app may show modal UI from them. A tab holds its UI
/// delegate weakly.
///
/// Every method is optional: when the delegate is nil or lacks a method, the engine does what it does by default
/// (for example it opens a popup in a window of its own, shows its own dialog, or shows its own context menu).
///
/// Every completion handler must be called exactly once, on the main thread, and may be called later, after the
/// method returns. If the handler is released without being called, the tab answers as if the person cancelled:
/// the dialog is dismissed, the permission is dismissed, or the menu closes with no command.
NS_SWIFT_UI_ACTOR
@protocol BowTabUIDelegate <NSObject>
@optional

/// The tab pushed a new snapshot: its URL, title, favicon, loading or back and forward state changed (mirrors
/// `TabEvent.stateChanged`). The same value is now `tab.state`.
- (void)tab:(BowTab *)tab didChangeState:(BowTabState *)state NS_SWIFT_NAME(tab(_:didChangeState:));

/// The page was destroyed, whoever closed it (the app, quitting, or the page itself). Called once, on a later main
/// thread task than the engine callback that closed it.
- (void)tabDidClose:(BowTab *)tab;

/// The page asked to open a new tab or window (mirrors `TabEvent.popupRequested`). This only informs the app: the
/// engine opens the page itself, in a popup window of its own, so the new page keeps its `window.opener` (sign in
/// popups report back through it). The engine cannot tell a plain link to a new tab from a page's
/// `window.open(url)`, so it never turns one into a tab, and the app must not open `request.targetURL` again.
/// Called as the engine starts opening it; if the engine then fails to create it, nothing more is reported.
/// Saving a link to disk, ignored actions and popups opened by popups are not reported.
- (void)tab:(BowTab *)tab didRequestPopup:(BowPopupRequest *)request NS_SWIFT_NAME(tab(_:didRequestPopup:));

/// The page asked for an alert, confirm, prompt or beforeunload dialog. Answer with whether the person accepted
/// (OK or "Leave"), and for a prompt the text they entered (nil otherwise). Answering a beforeunload dialog
/// with NO keeps the page, and cancels the close or quit that asked. Without this method the tab asks
/// "leave this site?" itself (a sheet on its window, or a free-floating alert while it is detached), and other
/// dialogs are the engine's own.
- (void)tab:(BowTab *)tab
    runJavaScriptDialog:(BowJSDialogRequest *)request
      completionHandler:(void (^)(BOOL accepted, NSString *_Nullable userInput))completionHandler
    NS_SWIFT_NAME(tab(_:runJavaScriptDialog:completionHandler:));

/// The page asked to use something that needs the person's permission.
- (void)tab:(BowTab *)tab
    requestPermission:(BowPermissionRequest *)request
      decisionHandler:(void (^)(BowPermissionDecision decision))decisionHandler
    NS_SWIFT_NAME(tab(_:requestPermission:decisionHandler:));

/// The page entered or left fullscreen, for example a video's fullscreen button (mirrors
/// `TabEvent.fullscreenChanged`). The app should resize the view showing the tab to match.
- (void)tab:(BowTab *)tab fullscreenDidChange:(BOOL)isFullscreen NS_SWIFT_NAME(tab(_:fullscreenChanged:));

/// The person asked for a context menu. Show a menu, then answer with the command ID of the default item they
/// chose for the engine to run, or `BowContextMenuNoCommand` when they chose nothing or the app ran its own
/// action.
- (void)tab:(BowTab *)tab
    runContextMenu:(BowContextMenuRequest *)request
    completionHandler:(void (^)(NSInteger commandID))completionHandler
    NS_SWIFT_NAME(tab(_:runContextMenu:completionHandler:));

/// The tab's render process ended; the page is gone until the tab is reloaded (mirrors
/// `TabEvent.renderProcessGone`).
- (void)tab:(BowTab *)tab renderProcessDidTerminate:(BowProcessGoneReason)reason
    NS_SWIFT_NAME(tab(_:renderProcessGone:));

/// A search started by `findText:forward:matchCase:` found matches or moved the active one (mirrors
/// `TabEvent.findResult`). One search can report several times as the engine counts; the last has `finalUpdate`.
- (void)tab:(BowTab *)tab didUpdateFindResult:(BowFindResult *)result NS_SWIFT_NAME(tab(_:didUpdateFindResult:));

@end

NS_ASSUME_NONNULL_END
