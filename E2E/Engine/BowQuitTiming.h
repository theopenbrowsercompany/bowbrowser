// How long the app's own part of quitting took, so the e2e runner can time it apart from Chromium's shutdown.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The Swift face of the engine's quit timing.
@interface BowQuitTiming : NSObject

/// Seconds from the start of the quit clock until every page had closed and the message loop ended, before
/// Chromium's own shutdown, or 0 before then. Read it once the engine has stopped.
+ (NSTimeInterval)closeDuration;

@end

NS_ASSUME_NONNULL_END
