#import "BowUnloadProbe.h"

#include "BowE2EHooks.h"

@implementation BowUnloadProbe

+ (BOOL)setAudible:(BOOL)audible forTab:(uint64_t)tabID {
  return BowEngineSetTabAudible(tabID, audible);
}

@end
