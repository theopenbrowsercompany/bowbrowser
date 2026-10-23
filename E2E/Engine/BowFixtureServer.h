// Serves e2e fixture pages at https://bow.test/ without a server, port or DNS lookup.
// Swift sees this header; the C++ entry point that takes a request context is in BowFixtureServer+Internal.h.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The Swift face of the fixture server.
@interface BowFixtureServer : NSObject

/// Serves `directory` at `https://bow.test/` in the global request context (the default profile).
/// Call after the engine has started and before opening a window on a fixture page.
+ (void)serveDirectory:(NSString *)directory;

@end

NS_ASSUME_NONNULL_END
