// The render process side of the page signal channel: what a page's frames report to the browser process about
// themselves, which the engine has no event for. C++: only the helper's main.mm includes it.
#pragma once

#include "include/cef_app.h"

/// The helper's CefApp. In a render process it installs the page signals script in every frame's JavaScript context
/// as the context is created, before any of the page's own scripts run; the other helper processes ignore it.
CefRefPtr<CefApp> BowHelperApp();
