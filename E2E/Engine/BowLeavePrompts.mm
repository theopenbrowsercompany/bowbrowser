#import "BowLeavePrompts.h"

#include "BowE2EHooks.h"

@implementation BowLeavePrompts

+ (void)answerWithHandler:(void (^)(uint64_t, BOOL, void (^)(BOOL)))handler {
  void (^copied)(uint64_t, BOOL, void (^)(BOOL)) = [handler copy];
  BowEngineAnswerLeavePrompts([copied](uint64_t tabID, bool isReload, std::function<void(bool)> answer) {
    copied(tabID, isReload, ^(BOOL leave) {
      answer(leave);
    });
  });
}

@end
