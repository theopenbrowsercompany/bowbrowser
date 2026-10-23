// Keeps the popup windows pages open off screen during e2e runs. Swift sees this header.
#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The Swift face of the engine's popup parking.
@interface BowPopupParking : NSObject

/// From now on, popups pages open live in a view in no window instead of windows of their own, so an e2e run
/// never shows one; their pages still run. Call after the engine has started and before any test opens a popup.
+ (void)start;

/// While `host` is set and returns a view, each new popup is created in that view (the content of an off screen
/// window the harness owns) instead of being parked, so its dialogs and its close go through a real window. nil, or
/// `host` returning nil, parks popups again. `host` is called on the main thread as each popup is created.
+ (void)hostPopupsIn:(NSView* _Nullable (^_Nullable)(void))host NS_SWIFT_NAME(hostPopups(in:));

/// Asks the popup browser inside `view` to close with the request quitting makes of every browser. Returns NO when
/// no popup browser is inside `view`. Call on the main thread.
+ (BOOL)closePopupInView:(NSView*)view NS_SWIFT_NAME(closePopup(in:));

/// The alert, confirm or prompt sheet a hosted popup's page has up on `window`, or nil. Call on the main thread.
+ (nullable NSAlert*)dialogOnWindow:(NSWindow*)window NS_SWIFT_NAME(dialog(on:));

@end

NS_ASSUME_NONNULL_END
