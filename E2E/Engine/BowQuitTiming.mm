#import "BowQuitTiming.h"

#include "BowE2EHooks.h"

@implementation BowQuitTiming

+ (NSTimeInterval)closeDuration {
  return BowEngineQuitCloseDuration();
}

@end
