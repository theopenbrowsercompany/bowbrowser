// What the certs tests (E2E/Tests/Certs.swift) read from Chromium's component updater, the service that keeps the
// certificate revocation list (CRLSet), the Chrome Root Store and the Certificate Transparency log list current
// between engine updates. Read only, apart from asking for one update check. Main thread only (CEF's UI thread).
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One registered component as the updater reported it when it was read.
@interface BowE2EComponent : NSObject
@property(nonatomic, readonly, copy) NSString *componentID;
/// Empty until the component is installed.
@property(nonatomic, readonly, copy) NSString *name;
/// Empty until the component is installed.
@property(nonatomic, readonly, copy) NSString *version;
/// The updater's state, in lower case words (new, checking, up to date, update error, ...).
@property(nonatomic, readonly, copy) NSString *state;
@end

@interface BowComponentUpdaterProbe : NSObject

/// True when CEF hands out its component updater on this thread.
+ (BOOL)isAvailable;

/// Every component registered with the updater, in the updater's order. Empty when the updater is unavailable or
/// was turned off (`--disable-component-update`).
+ (NSArray<BowE2EComponent *> *)registeredComponents;

/// Asks the updater for an on demand, foreground update check of one component. `completion` runs once on the main
/// thread with the result in lower case words (none, update check error, service error, ...).
+ (void)checkForUpdateOf:(NSString *)componentID completion:(void (^)(NSString *result))completion;

@end

NS_ASSUME_NONNULL_END
