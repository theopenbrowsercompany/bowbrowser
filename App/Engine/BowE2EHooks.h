// The engine's only seam for the e2e harness in E2E/: everything the harness needs from the engine that the
// app itself does not. Compiled only when BOW_E2E is set (Debug builds). Objective-C++ only; never import it
// from Swift. App code must not call anything declared here.
#pragma once

#if BOW_E2E

#import <Foundation/Foundation.h>

#include <cstdint>
#include <functional>

#include "include/cef_browser.h"
#include "include/cef_request_context.h"

/// The browser of the open tab with this ID, or null when no open tab has it. Call on the main thread.
CefRefPtr<CefBrowser> BowEngineBrowserForTabID(uint64_t tabID);

/// True while the tab with this ID exists but its browser is still being created.
bool BowEngineTabIsOpening(uint64_t tabID);

/// How many browsers are open or being created, popups included. The harness checks it is back to zero after
/// each test has closed its windows. Call on the main thread.
size_t BowEngineOpenBrowserCount();

/// Calls `observer` now with the request context of every existing profile, and later with each new profile's
/// context as it is created, before any of its tabs. The fixture server uses it to serve every profile.
void BowEngineObserveProfileContexts(std::function<void(CefRefPtr<CefRequestContext>)> observer);

/// Called by main when the message loop has ended, before CefShutdown: records how long quitting took up to here.
void BowEngineMessageLoopDidEnd();

/// Seconds from the start of the quit clock until every page had closed and the message loop ended, before
/// Chromium's own shutdown, or 0 before then: the app's part of `BowEngine.quitDuration`.
NSTimeInterval BowEngineQuitCloseDuration();

/// From now on, popups the engine opens with windows of their own are created in the engine's parking view
/// instead (a view in no window), so an e2e run never shows one. Their pages still run. Call on the main thread.
void BowEngineParkPopups();

/// True once BowEngineParkPopups has been called.
bool BowEngineParksPopups();

/// From now on, a tab's own "leave this site?" prompt (shown when its UI delegate takes no JavaScript dialogs) is
/// never put on screen: `answerer` is called instead, on a later main thread task, with the tab's ID and whether
/// the page is being reloaded, and calls `answer` once, on the main thread, with true to leave or false to stay
/// (later calls are ignored, and an `answer` released uncalled leaves). Everything around the prompt (cancelling
/// the close or quit on stay) runs as usual. Call on the main thread, after the engine has started and before any
/// page can ask.
void BowEngineAnswerLeavePrompts(
    std::function<void(uint64_t tabID, bool isReload, std::function<void(bool leave)> answer)> answerer);

#endif  // BOW_E2E
