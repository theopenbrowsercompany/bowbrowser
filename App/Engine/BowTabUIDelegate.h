// How a tab asks the app for UI: popups, JavaScript dialogs, permission prompts, fullscreen, context menus and
// render process exits. Swift visible: plain Objective-C only, never C++ or CEF.
#import <Foundation/Foundation.h>

#import "BowTabUIRequests.h"

@class BowTab;

NS_ASSUME_NONNULL_BEGIN

/// Receives one tab's requests for UI, always on the main thread. A tab holds its UI delegate weakly.
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

/// The page asked to open a new tab or window (mirrors `TabEvent.popupRequested`). When the delegate has this
/// method the engine does not open anything itself: the app decides where `request.targetURL` opens.
- (void)tab:(BowTab *)tab didRequestPopup:(BowPopupRequest *)request NS_SWIFT_NAME(tab(_:didRequestPopup:));

/// The page asked for an alert, confirm, prompt or beforeunload dialog. Answer with whether the person accepted
/// (OK or "Leave"), and for a prompt the text they entered (nil otherwise).
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

@end

NS_ASSUME_NONNULL_END
