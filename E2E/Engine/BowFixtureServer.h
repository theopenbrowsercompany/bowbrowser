// Serves e2e fixture pages at https://bow.test/ without a server, port or DNS lookup.
// Swift sees this header; the C++ entry point that takes a request context is in BowFixtureServer+Internal.h.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The Swift face of the fixture server.
@interface BowFixtureServer : NSObject

/// Serves `directory` at `https://bow.test/` in every profile: those that exist now and each one created later.
/// Call after the engine has started and before opening a window on a fixture page.
+ (void)serveDirectory:(NSString *)directory;

/// Lets the held downloads with `key` (`/_held/<key>/<bytes>/<name>`) send the rest of their bytes and end, and
/// those that start with it later run through without holding. Call from any thread.
+ (void)releaseHeld:(NSString *)key;

/// Releases every held download and forgets the keys released so far. The runner calls it after each test, so a
/// held download a failed test left never hangs the next one.
+ (void)releaseAllHeld;

@end

NS_ASSUME_NONNULL_END
