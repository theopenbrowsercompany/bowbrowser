// Answers the tabs' own "leave this site?" prompts during e2e runs, so none shows on screen. Swift sees this header.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The Swift face of the engine's leave prompt hook.
@interface BowLeavePrompts : NSObject

/// From now on, a tab's own leave prompt is never shown: `handler` gets the tab's ID and whether the page is being
/// reloaded, on the main thread, and calls `answer` exactly once on the main thread, with YES to leave or NO to
/// stay. Call on the main thread, after the engine has started.
+ (void)answerWithHandler:(void (^)(uint64_t tabID, BOOL isReload, void (^answer)(BOOL leave)))handler
    NS_SWIFT_NAME(answer(with:));

@end

NS_ASSUME_NONNULL_END
