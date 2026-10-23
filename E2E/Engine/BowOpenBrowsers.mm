#import "BowOpenBrowsers.h"

#include "BowE2EHooks.h"

@implementation BowOpenBrowsers

+ (NSInteger)count {
  return static_cast<NSInteger>(BowEngineOpenBrowserCount());
}

+ (NSInteger)refusedParkedRequestsOfKind:(NSString *)kind {
  return static_cast<NSInteger>(BowEngineParkedRequestsRefused(kind.UTF8String));
}

+ (NSInteger)devToolsRequestsForTab:(uint64_t)tabID {
  return static_cast<NSInteger>(BowEngineDevToolsRequests(tabID, nullptr));
}

+ (CGPoint)devToolsInspectedPointForTab:(uint64_t)tabID {
  CGPoint point;
  BowEngineDevToolsRequests(tabID, &point);
  return point;
}

@end
