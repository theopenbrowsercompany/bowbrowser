// How a tab reports its main frame navigations. Swift visible: plain Objective-C only, never C++ or CEF.
// Mirrors BowCore's `EngineTabDelegate` and the navigation cases of `TabEvent`: in Swift the methods read
// tab(_:didStartNavigation:), tab(_:didRedirect:), tab(_:didCommit:), tab(_:didFinish:httpStatus:),
// tab(_:didFail:error:) and tab(_:decidePolicyFor:).
#import <Foundation/Foundation.h>

#import "BowNavigation.h"

@class BowTab;

NS_ASSUME_NONNULL_BEGIN

/// Receives one tab's main frame navigations, always on the main thread and in the order the engine produced
/// them: start, then any redirects, then commit, then finish or fail. A navigation the policy cancels gets no
/// further calls. A tab holds its navigation delegate weakly. Every method is optional.
NS_SWIFT_UI_ACTOR
@protocol BowTabNavigationDelegate <NSObject>
@optional

/// Asked before every main frame navigation, including redirects, and answered synchronously because the engine
/// asks synchronously. A delegate without this method allows every navigation.
- (BowNavigationPolicy)tab:(BowTab *)tab
    decidePolicyForNavigation:(BowNavigation *)navigation NS_SWIFT_NAME(tab(_:decidePolicyFor:));

/// A main frame navigation started (mirrors `TabEvent.didStartNavigation`).
- (void)tab:(BowTab *)tab didStartNavigation:(BowNavigation *)navigation NS_SWIFT_NAME(tab(_:didStartNavigation:));

/// The server redirected the navigation; `navigation.url` is the new URL (mirrors `TabEvent.didRedirect`).
- (void)tab:(BowTab *)tab didRedirectNavigation:(BowNavigation *)navigation NS_SWIFT_NAME(tab(_:didRedirect:));

/// The new page committed: the address the tab shows is now `navigation.url` (mirrors `TabEvent.didCommit`).
- (void)tab:(BowTab *)tab didCommitNavigation:(BowNavigation *)navigation NS_SWIFT_NAME(tab(_:didCommit:));

/// The main frame finished loading, with its HTTP status code, or 0 when the scheme has none
/// (mirrors `TabEvent.didFinish`).
- (void)tab:(BowTab *)tab
    didFinishNavigation:(BowNavigation *)navigation
         httpStatusCode:(NSInteger)httpStatusCode NS_SWIFT_NAME(tab(_:didFinish:httpStatus:));

/// The navigation failed before or after committing (mirrors `TabEvent.didFail`).
- (void)tab:(BowTab *)tab
    didFailNavigation:(BowNavigation *)navigation
                error:(BowNavigationError *)error NS_SWIFT_NAME(tab(_:didFail:error:));

@end

NS_ASSUME_NONNULL_END
