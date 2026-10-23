// Reports every renderer that ends during an e2e run, so the runner can fail a test that did not expect it.
// Swift sees this header.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The Swift face of the engine's renderer termination hook.
@interface BowRendererTerminations : NSObject

/// From now on, calls `handler` on the main thread each time a renderer serving a browser ends, with the ID of the
/// tab whose own browser it served (0 for any other browser, such as a popup), the termination status's name
/// (`crashed`, `killed`, `abnormal`, `oom`, `launch-failed`, `integrity-failure`) and Chromium's error code, as
/// BowEngineObserveRenderProcessTerminations says. Call once, on the main thread.
+ (void)observeWithHandler:(void (^)(uint64_t tabID, NSString *status, NSInteger errorCode))handler
    NS_SWIFT_NAME(observe(with:));

@end

NS_ASSUME_NONNULL_END
