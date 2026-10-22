// The engine's only seam for the e2e harness in E2E/: everything the harness needs from the engine that the
// app itself does not. Compiled only when BOW_E2E is set (Debug builds). Objective-C++ only; never import it
// from Swift. App code must not call anything declared here.
#pragma once

#if BOW_E2E

#import <Foundation/Foundation.h>

#include <vector>

#include "include/cef_browser.h"

/// Every browser that has been created and not closed yet, popups included. Call on the main thread.
std::vector<CefRefPtr<CefBrowser>> BowEngineOpenBrowsers();

/// Posted on the main thread after each browser is created (after BowEngineBrowserCreated), with no object.
extern NSNotificationName const BowEngineBrowserCreatedNotification;

#endif  // BOW_E2E
