// C++ hooks shared by the engine's Objective-C++ files. Never import this from Swift.
#pragma once

#include "include/cef_browser.h"

void BowEngineBrowserCreated(CefRefPtr<CefBrowser> browser);
void BowEngineBrowserClosed(CefRefPtr<CefBrowser> browser);
