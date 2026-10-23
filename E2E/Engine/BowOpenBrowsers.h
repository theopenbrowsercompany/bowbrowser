// Counts the engine's open browsers, so the e2e runner can check that each test leaves none behind.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The Swift face of the engine's browser count.
@interface BowOpenBrowsers : NSObject

/// How many browsers are open or being created, popups included. Call on the main thread.
+ (NSInteger)count;

/// How many UI requests of `kind` (popup, dialog, download, permission, file dialog, context menu) pages of closed
/// tabs kept alive for their downloads made and were refused so far. Call on the main thread.
+ (NSInteger)refusedParkedRequestsOfKind:(NSString *)kind NS_SWIFT_NAME(refusedParkedRequests(of:));

/// How many times the tab with this ID asked to show DevTools in this run (an e2e run records the requests instead of
/// opening DevTools), and the point the last request inspected, (-1, -1) for none. Call on the main thread.
+ (NSInteger)devToolsRequestsForTab:(uint64_t)tabID NS_SWIFT_NAME(devToolsRequests(forTab:));
+ (CGPoint)devToolsInspectedPointForTab:(uint64_t)tabID NS_SWIFT_NAME(devToolsInspectedPoint(forTab:));

@end

NS_ASSUME_NONNULL_END
