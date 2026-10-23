#pragma once

#import "BowDownloads.h"

/// Called once when the engine's message loop has ended, before CefShutdown. Every profile's downloads stop
/// following their files and let go of the browsers and controls they hold, and ignore later reports, so nothing
/// reaches Chromium or the app during shutdown. Main thread only; does no work that could slow quitting.
void BowDownloadsEngineDidStop();
