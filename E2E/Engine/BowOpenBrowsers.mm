#import "BowOpenBrowsers.h"

#include "BowE2EHooks.h"

@implementation BowOpenBrowsers

+ (NSInteger)count {
  return static_cast<NSInteger>(BowEngineOpenBrowserCount());
}

+ (NSInteger)refusedParkedRequestsOfKind:(NSString *)kind {
  return static_cast<NSInteger>(BowEngineParkedRequestsRefused(kind.UTF8String));
}

@end
