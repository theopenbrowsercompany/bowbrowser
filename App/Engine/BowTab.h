#import <Foundation/Foundation.h>

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

@end

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

- (void)loadURL:(NSURL *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stop;

/// Closes the tab after running the page's beforeunload handler. The completion runs on a later main thread task
/// with YES once the page is destroyed, or NO when the person chose to stay on the page (at the UI delegate's
/// JavaScript dialog, or at the tab's own prompt when the delegate has none).
- (void)closeWithCompletion:(void (^)(BOOL closed))completion NS_SWIFT_NAME(close(completion:));

/// Receives the tab's main frame navigations and decides their policy. Held weakly.
@property(nonatomic, weak, nullable) id<BowTabNavigationDelegate> navigationDelegate;
/// Receives the tab's state, close and requests for UI (popups, dialogs, permissions, fullscreen, context menus,
/// render process exits). Held weakly.
@property(nonatomic, weak, nullable) id<BowTabUIDelegate> uiDelegate;

@end

NS_ASSUME_NONNULL_END
