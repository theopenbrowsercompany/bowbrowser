#import <AppKit/AppKit.h>

#import "BowTabNavigationDelegate.h"
#import "BowTabUIDelegate.h"

NS_ASSUME_NONNULL_BEGIN

/// An immutable snapshot of a tab, as last pushed by the engine. Never computed on demand.
NS_SWIFT_SENDABLE
@interface BowTabState : NSObject

- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) uint64_t tabID;
/// The committed URL, or nil before anything has committed.
@property(nonatomic, readonly, copy, nullable) NSURL *url;
/// The page title, empty when the page has none yet.
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly, copy, nullable) NSURL *faviconURL;
@property(nonatomic, readonly, getter=isLoading) BOOL loading;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
/// Always NO for now: CEF 156 reports no audible state.
@property(nonatomic, readonly, getter=isAudible) BOOL audible;
/// YES while the page uses a camera (or captures the screen's video).
@property(nonatomic, readonly, getter=isCapturingVideo) BOOL capturingVideo;
/// YES while the page uses a microphone (or captures the screen's audio).
@property(nonatomic, readonly, getter=isCapturingAudio) BOOL capturingAudio;

@end

/// What a find in page search has found so far, as the engine reported it (mirrors `FindResult`).
NS_SWIFT_SENDABLE
@interface BowFindResult : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// How many matches the page holds, as counted so far.
@property(nonatomic, readonly) NSInteger matchCount;
/// The position of the active match, from 1 to `matchCount`, or 0 when there is none.
@property(nonatomic, readonly) NSInteger activeMatch;
/// YES once the engine has finished counting; earlier results of the same search may count fewer matches.
@property(nonatomic, readonly, getter=isFinalUpdate) BOOL finalUpdate;

@end

/// Why a tab closed (mirrors `TabCloseReason`).
typedef NS_ENUM(NSInteger, BowTabCloseReason) {
  /// Still open, or unloaded rather than closed.
  BowTabCloseReasonNone,
  /// The app closed it with `closeWithCompletion:`.
  BowTabCloseReasonApp,
  /// The engine closed it unasked: the page called `window.close()`, or its page could not be created.
  BowTabCloseReasonPage,
  /// Quitting the engine closed it.
  BowTabCloseReasonQuit,
};

/// One web page for its whole life, independent of any view that shows it. Created by `BowProfile`; shown by
/// attaching it to a `BowWebView`. The engine keeps the tab alive until it closes, so letting go of it does not
/// close the page: call `closeWithCompletion:`.
NS_SWIFT_UI_ACTOR
@interface BowTab : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// Assigned at creation and unique for the life of the engine.
@property(nonatomic, readonly) uint64_t tabID;
@property(nonatomic, readonly, copy) NSString *profileID;

/// The snapshot pushed last, also delivered to the UI delegate's `tab(_:didChangeState:)`.
@property(nonatomic, readonly) BowTabState *state;

/// YES once the page has been destroyed. Navigation calls then do nothing.
@property(nonatomic, readonly, getter=isClosed) BOOL closed;
/// Why the tab closed: set once it has, before the UI delegate's `tabDidClose:`; `BowTabCloseReasonNone` while it
/// is open or after an unload.
@property(nonatomic, readonly) BowTabCloseReason closeReason;

- (void)loadURL:(NSURL *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stop;

/// Finds `text` in the page, highlighting every match and selecting the active one. Asking again with the same
/// text and case steps to the next match (or the previous one when `forward` is NO); other text starts a new
/// search. Empty text stops finding. Results arrive through the UI delegate's `tab(_:didUpdateFindResult:)`.
- (void)findText:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase
    NS_SWIFT_NAME(find(_:forward:matchCase:));
/// Stops finding and clears the highlights. The active match stays selected, as in other browsers. Results of the
/// stopped search that arrive later are dropped.
- (void)stopFind;

/// Closes the tab after running the page's beforeunload handler. The completion runs on a later main thread task
/// with YES once the page is destroyed, or NO when the person chose to stay on the page (at the UI delegate's
/// JavaScript dialog, or at the tab's own prompt when the delegate has none).
- (void)closeWithCompletion:(void (^)(BOOL closed))completion NS_SWIFT_NAME(close(completion:));

/// Destroys the page's browser to free its memory; the app keeps its own model of the tab. The page's beforeunload
/// handler runs but never prompts: a page that would ask to stay keeps the tab, and the completion gets NO. On
/// YES the tab is closed and its UI delegate gets `tabDidUnload:` instead of `tabDidClose:`. A tab that is closed or
/// closing (the app's close, the page's `window.close()`) answers NO, and so does every tab while the engine quits.
/// A close asked for while the unload is pending takes it over and answers the unload NO.
- (void)unloadWithCompletion:(void (^)(BOOL unloaded))completion NS_SWIFT_NAME(unload(completion:));

/// The page's zoom level (0 is 100%). Chromium keeps zoom per site in the profile, so setting it changes every tab
/// on the page's site. 0 while the tab has no browser, and setting it then does nothing.
@property(nonatomic) double zoomLevel;

/// Asks the page to leave fullscreen (Alloy style leaves Escape and tab switches to the app); the UI delegate's
/// `tab:fullscreenDidChange:` follows once it has. Does nothing while the tab has no browser or is closing.
- (void)exitFullscreen;

/// Downloads the site icon at `url` (usually the state's `faviconURL`) through the tab's own profile, at most
/// `maxPixelSize` pixels on a side, and calls `completion` on a later main thread task with the image, or nil when
/// the download failed or the tab has no browser.
- (void)loadFaviconAtURL:(NSURL*)url
            maxPixelSize:(NSUInteger)maxPixelSize
              completion:(void (^)(NSImage* _Nullable image))completion
    NS_SWIFT_NAME(loadFavicon(at:maxPixelSize:completion:));

/// Receives the tab's main frame navigations and decides their policy. Held weakly.
@property(nonatomic, weak, nullable) id<BowTabNavigationDelegate> navigationDelegate;
/// Receives the tab's state, close and requests for UI (popups, dialogs, permissions, fullscreen, context menus,
/// render process exits). Held weakly.
@property(nonatomic, weak, nullable) id<BowTabUIDelegate> uiDelegate;

@end

/// DevTools for a tab's page (BowTabDevTools.mm).
@interface BowTab (DevTools)

/// Opens DevTools for the page in a window of its own and inspects the element at `point`, in points from the top
/// left of the view showing the tab. When DevTools is open already it is only focused. DevTools closes when the tab
/// does, and quitting closes it. Does nothing while the tab has no browser.
- (void)showDevToolsInspectingPoint:(CGPoint)point NS_SWIFT_NAME(showDevTools(inspectingAt:));
/// Opens DevTools for the page as `showDevToolsInspectingPoint:` does, inspecting nothing.
- (void)showDevTools;
/// Closes the page's DevTools, if open.
- (void)closeDevTools;
/// YES while the page's DevTools is open.
@property(nonatomic, readonly) BOOL hasDevTools;

@end

NS_ASSUME_NONNULL_END
