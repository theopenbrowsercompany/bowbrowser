// The fixture server's C++ entry point. Objective-C++ only; never import it from Swift.
#pragma once

#import <Foundation/Foundation.h>

#include "include/cef_request_context.h"

/// Serves the files in `directory` at `https://bow.test/<path>` for every browser in `context`.
/// A path ending in `/` serves that folder's `index.html` (for example `/app/` serves `app/index.html`; the
/// fixtures have one folder per area and no root page). Paths containing `..` and missing files answer 404.
/// Takes the request context so each profile's context can be given the fixtures once profiles exist.
/// Call on the main thread after the engine has started.
void BowServeFixtures(CefRefPtr<CefRequestContext> context, NSString* _Nonnull directory);
