#import "BowOpenBrowsers.h"

#include "BowE2EHooks.h"

@implementation BowOpenBrowsers

+ (NSInteger)count {
  return static_cast<NSInteger>(BowEngineOpenBrowserCount());
}

@end
