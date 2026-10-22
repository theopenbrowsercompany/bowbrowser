// C++ hooks shared by the engine's Objective-C++ files. Never import this from Swift.
#pragma once

#include "include/cef_browser.h"

// The engine tracks every browser from creation to destruction, so quitting waits for each one to close
// and ends the message loop exactly once, after the last OnBeforeClose. Call these on the main thread.

/// A browser was requested with CefBrowserHost::CreateBrowser and OnAfterCreated has not arrived yet.
void BowEngineBrowserCreationStarted();
/// CefBrowserHost::CreateBrowser returned false after BowEngineBrowserCreationStarted.
void BowEngineBrowserCreationFailed();
/// OnAfterCreated, for requested browsers and popups alike. If the app is quitting, the browser is then closed.
void BowEngineBrowserCreated(CefRefPtr<CefBrowser> browser);
/// Asks a browser to close, running its unload handlers. Does nothing once the browser has accepted closing
/// (DoClose), and nothing if a close was already requested unless `askAgain` is true, so a page's leave prompt is
/// not shown twice for one request.
void BowEngineCloseBrowser(CefRefPtr<CefBrowser> browser, bool askAgain);
/// DoClose: the browser's unload handlers have run and it can no longer cancel closing.
void BowEngineBrowserWillClose(CefRefPtr<CefBrowser> browser);
/// OnBeforeClose. Ends the message loop when the app is quitting and this was the last browser.
void BowEngineBrowserClosed(CefRefPtr<CefBrowser> browser);
/// Called by main after CefShutdown returns.
void BowEngineDidShutDown();
