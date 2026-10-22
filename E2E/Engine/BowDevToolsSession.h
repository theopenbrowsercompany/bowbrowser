#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for DevTools calls that fail: the protocol's own errors and browsers that close mid call.
extern NSErrorDomain const BowDevToolsErrorDomain;

/// Calls Chrome DevTools protocol methods on one tab's browser, for test runs, whether or not the tab is attached
/// to a view. It needs no DevTools window or remote debugging port. Calls made while the tab is still opening wait
/// for its browser; calls fail once the tab has closed.
NS_SWIFT_UI_ACTOR
@interface BowDevToolsSession : NSObject

/// `tabID` is the tab's `tabID`.
- (instancetype)initWithTabID:(uint64_t)tabID NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Calls `method` (for example `Runtime.evaluate`) with `params` and reports the method's result object,
/// or an error in `BowDevToolsErrorDomain`. The completion runs on the main thread.
- (void)callMethod:(NSString *)method
            params:(nullable NSDictionary<NSString *, id> *)params
        completion:(void (^)(NSDictionary<NSString *, id> *_Nullable result, NSError *_Nullable error))completion
    NS_SWIFT_DISABLE_ASYNC;

/// Lets go of the browser and stops listening to it, failing calls still waiting; later calls fail at once.
/// Call when the browser closes, so no Chromium object outlives it (releasing one after the engine has shut down
/// crashes).
- (void)close;

@end

NS_ASSUME_NONNULL_END
