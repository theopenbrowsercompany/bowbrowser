// What the unload tests (E2E/Tests/Unload.swift) need from the engine beyond what the app does: a tab's sound
// starting and stopping, which CEF 156 does not report. Main thread only.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BowUnloadProbe : NSObject

/// Reports that the tab started or stopped playing sound, through the tab method an engine audio event would call.
/// Returns false when no open tab has the ID.
+ (BOOL)setAudible:(BOOL)audible forTab:(uint64_t)tabID;

@end

NS_ASSUME_NONNULL_END
