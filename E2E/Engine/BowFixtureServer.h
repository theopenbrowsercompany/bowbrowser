// Serves e2e fixture pages at https://bow.test/ without a server, port or DNS lookup.
#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
#include "include/cef_request_context.h"

/// Serves the files in `directory` at `https://bow.test/<path>` for every browser in `context`.
/// A path ending in `/` serves that folder's `index.html` (for example `/app/` serves `app/index.html`; the
/// fixtures have one folder per area and no root page). Paths containing `..` and missing files answer 404.
/// Takes the request context so each profile's context can be given the fixtures once profiles exist.
/// Call on the main thread after the engine has started.
void BowServeFixtures(CefRefPtr<CefRequestContext> context, NSString* _Nonnull directory);
#endif

NS_ASSUME_NONNULL_BEGIN

/// The Swift face of the fixture server.
@interface BowFixtureServer : NSObject

/// Serves `directory` at `https://bow.test/` in the global request context (the default profile).
/// Call after the engine has started and before opening a window on a fixture page.
+ (void)serveDirectory:(NSString *)directory;

@end

NS_ASSUME_NONNULL_END
