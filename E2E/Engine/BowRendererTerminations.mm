#import "BowRendererTerminations.h"

#include "BowE2EHooks.h"

@implementation BowRendererTerminations

+ (void)observeWithHandler:(void (^)(uint64_t, NSString *, NSInteger))handler {
  void (^copied)(uint64_t, NSString *, NSInteger) = [handler copy];
  BowEngineObserveRenderProcessTerminations([copied](uint64_t tabID, const char *status, int errorCode) {
    copied(tabID, @(status), errorCode);
  });
}

@end
