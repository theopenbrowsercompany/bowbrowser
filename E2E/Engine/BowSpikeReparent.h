// Spike S1 (throwaway): engine calls the reparent spike needs. Swift sees this header.
#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BowSpikeReparent : NSObject

/// Chromium's view for the tab's browser (CefBrowserHost::GetWindowHandle), wherever it is, or nil.
+ (nullable NSView *)browserViewForTabID:(uint64_t)tabID;

/// CefBrowserHost::NotifyScreenInfoChanged. Returns NO when the tab has no browser.
+ (BOOL)notifyScreenInfoChangedForTabID:(uint64_t)tabID;

/// CefBrowserHost::SetFocus. Returns NO when the tab has no browser.
+ (BOOL)setFocus:(BOOL)focus forTabID:(uint64_t)tabID;

@end

NS_ASSUME_NONNULL_END
