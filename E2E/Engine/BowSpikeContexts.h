// Spike S2 (throwaway): several request contexts in one window. Swift sees this header.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BowSpikeContexts : NSObject

/// Creates a profile with its own handler, which records when its context finished initializing and every request
/// it is asked about. `cachePath` nil keeps it in memory; `sharedWith` names a profile whose storage it shares
/// (CreateContext(other, handler)), and then `cachePath` is ignored. Returns the seconds CreateContext took, or -1
/// when the profile could not be created.
+ (double)createProfileWithID:(NSString *)profileID
                    cachePath:(nullable NSString *)cachePath
                   sharedWith:(nullable NSString *)sharedWith;

/// Seconds from the start of CreateContext to its handler's OnRequestContextInitialized, or -1 before that.
+ (double)initializationSecondsForProfile:(NSString *)profileID;

/// The URLs this profile's own handler was asked about, in order.
+ (NSArray<NSString *> *)requestURLsForProfile:(NSString *)profileID;

/// CefRequestContext::GetCachePath of the profile, empty for an in-memory one.
+ (NSString *)cachePathOfProfile:(NSString *)profileID;

/// CefRequestContext::IsSharingWith between two profiles' contexts.
+ (BOOL)profile:(NSString *)profileID sharesStorageWith:(NSString *)otherID;

/// Memory now: `browser` (this process's physical footprint, bytes), `children` (summed footprint of its child
/// processes), `childCount`, and `load1` (the one minute load average).
+ (NSDictionary<NSString *, NSNumber *> *)memorySnapshot;

@end

NS_ASSUME_NONNULL_END
