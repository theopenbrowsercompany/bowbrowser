// Keeps the popup windows pages open off screen during e2e runs. Swift sees this header.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The Swift face of the engine's popup parking.
@interface BowPopupParking : NSObject

/// From now on, popups pages open live in a view in no window instead of windows of their own, so an e2e run
/// never shows one; their pages still run. Call after the engine has started and before any test opens a popup.
+ (void)start;

@end

NS_ASSUME_NONNULL_END
