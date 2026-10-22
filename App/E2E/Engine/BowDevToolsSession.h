#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for DevTools calls that fail: the protocol's own errors and browsers that close mid call.
extern NSErrorDomain const BowDevToolsErrorDomain;

/// Calls Chrome DevTools protocol methods on the browser shown in one view, for test runs.
/// It needs no DevTools window or remote debugging port. Calls made before the browser exists wait for it.
/// It lives in its own file, apart from `BowWebView`, so the engine bridge can change without touching it.
NS_SWIFT_UI_ACTOR
@interface BowDevToolsSession : NSObject

/// `view` is the view the browser is hosted in (today a `BowWebView`).
- (instancetype)initWithHostView:(NSView *)view NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Calls `method` (for example `Runtime.evaluate`) with `params` and reports the method's result object,
/// or an error in `BowDevToolsErrorDomain`. The completion runs on the main thread.
- (void)callMethod:(NSString *)method
            params:(nullable NSDictionary<NSString *, id> *)params
        completion:(void (^)(NSDictionary<NSString *, id> *_Nullable result, NSError *_Nullable error))completion
    NS_SWIFT_DISABLE_ASYNC;

@end

NS_ASSUME_NONNULL_END
