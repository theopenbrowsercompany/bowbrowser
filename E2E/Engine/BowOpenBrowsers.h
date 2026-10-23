// Counts the engine's open browsers, so the e2e runner can check that each test leaves none behind.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The Swift face of the engine's browser count.
@interface BowOpenBrowsers : NSObject

/// How many browsers are open or being created, popups included. Call on the main thread.
+ (NSInteger)count;

@end

NS_ASSUME_NONNULL_END
