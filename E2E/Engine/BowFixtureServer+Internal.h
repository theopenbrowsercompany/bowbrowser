// The fixture server's C++ entry point. Objective-C++ only; never import it from Swift.
#pragma once

#import <Foundation/Foundation.h>

#include "include/cef_request_context.h"

/// Serves the files in `directory` at `https://bow.test/<path>` for every browser in `context`, and the same files at
/// `https://other.bow.test/<path>`, another site, for tests of links that leave a site.
/// A path ending in `/` serves that folder's `index.html` (for example `/app/` serves `app/index.html`; the
/// fixtures have one folder per area and no root page). Paths containing `..` and missing files answer 404.
/// Reserved prefixes need no file: `/_redirect/<path>` answers 302 Found to `https://bow.test/<path>`,
/// `/_redirect_other/<path>` answers 302 Found to `https://other.bow.test/<path>` (a redirect that leaves the site),
/// `/_204/<anything>` answers 204 No Content, `/_error/<anything>` fails to connect (ERR_CONNECTION_REFUSED),
/// `/_hang/<anything>` never answers, `/_slow/[<bytes>/]<name>` is a slow download, and
/// `/_held/<key>/<bytes>/<name>` is a download that holds after its first chunk until `key` is released.
/// BowFixtureServer.serveDirectory calls it for every profile through BowEngineObserveProfileContexts.
/// Call on the main thread after the engine has started.
void BowServeFixtures(CefRefPtr<CefRequestContext> context, NSString* _Nonnull directory);
