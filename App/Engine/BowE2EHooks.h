// The engine's only seam for the e2e harness in E2E/: everything the harness needs from the engine that the
// app itself does not. Compiled only when BOW_E2E is set (Debug builds). Objective-C++ only; never import it
// from Swift. App code must not call anything declared here.
#pragma once

#if BOW_E2E

#import <Foundation/Foundation.h>

@class NSAlert;
@class NSView;
@class NSWindow;

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

/// Seconds from the start of the quit clock until every page had closed and the message loop ended, before
/// Chromium's own shutdown, or 0 before then: the app's part of `BowEngine.quitDuration`.
NSTimeInterval BowEngineQuitCloseDuration();

/// From now on, popups the engine opens with windows of their own are created in the engine's parking view
/// instead (a view in no window), so an e2e run never shows one. Their pages still run. Call on the main thread.
void BowEngineParkPopups();

/// True once BowEngineParkPopups has been called.
bool BowEngineParksPopups();

/// While `host` is set and returns a view, a popup the engine would park is created in that view instead (a view in
/// an off screen window the harness owns), so its page runs in a real window: its dialogs come up as sheets on that
/// window, and its close goes through the window (performClose:) as a popup window's does. nil (or `host`
/// returning nil) parks popups again. Called on the main thread as each popup is created.
void BowEngineHostPopups(NSView* (^host)(void));

/// The view BowEngineHostPopups' host gives for a popup about to open in a window of its own, or nil to park it. Called
/// by the engine only for a popup it opens as a window, never for one that becomes a tab or is blocked.
NSView* BowEngineHostedPopupView();

/// Asks the popup browser shown inside `view` to close with the same request quitting makes of every browser
/// (CloseBrowser without forcing). Returns false when no popup browser is in `view`, or it is closing or was asked to
/// close already, so nothing was sent. Main thread only.
bool BowEngineClosePopupInView(NSView* view);

/// The alert, confirm or prompt sheet a hosted popup's page has up on `window`, or nil when none is. Main thread only.
NSAlert* BowEnginePopupDialogOnWindow(NSWindow* window);

/// From now on, a tab's own "leave this site?" prompt (shown when its UI delegate takes no JavaScript dialogs) is
/// never put on screen: `answerer` is called instead, on a later main thread task, with the tab's ID and whether
/// the page is being reloaded, and calls `answer` once, on the main thread, with true to leave or false to stay
/// (later calls are ignored, and an `answer` released uncalled leaves). Everything around the prompt (cancelling
/// the close or quit on stay) runs as usual. Call on the main thread, after the engine has started and before any
/// page can ask.
void BowEngineAnswerLeavePrompts(
    std::function<void(uint64_t tabID, bool isReload, std::function<void(bool leave)> answer)> answerer);

/// Counts one UI request (`kind`: popup, dialog, download, permission, file dialog, context menu) that the page of
/// a closed tab, kept alive for its downloads, made and was refused. Called by the engine. Main thread only.
void BowEngineNoteParkedRequestRefused(const char* kind);

/// How many UI requests of `kind` pages of closed tabs kept for their downloads were refused so far. Main thread only.
size_t BowEngineParkedRequestsRefused(const char* kind);

/// Once BowEngineParksPopups has been called, a tab asked to show DevTools records the request instead of opening it:
/// this engine version opens DevTools only as a window of its own (Chrome style, which takes no parent view), which
/// would show on screen and activate the app. Returns how many requests the tab with this ID made, and sets
/// `inspectedPoint` to the point the last one inspected (x and y -1 for none). Main thread only.
size_t BowEngineDevToolsRequests(uint64_t tabID, CGPoint* inspectedPoint);

/// Reports that the open tab with this ID started (true) or stopped (false) playing sound, through the same tab
/// method a frame's sound signal from the render process calls, as a frame of its own, so a test controls exactly
/// when the sound stops. Returns false when no open tab has the ID.
/// Main thread only.
bool BowEngineSetTabAudible(uint64_t tabID, bool audible);

/// Calls `observer` on the main thread each time a renderer serving a tab's browser, or a popup sharing a tab's
/// client, ends (BowTabClient::OnRenderProcessTerminated), with the ID of the tab whose own browser it served (0 for
/// a popup, or for a tab's browser whose tab has already gone), the termination status's name (`crashed`, `killed`,
/// `abnormal`, `oom`, `launch-failed`, `integrity-failure`, or `unknown` for a status this list does not name) and
/// Chromium's error code. The engine reports each
/// termination through BowEngineNoteRenderProcessTerminated before deciding whether the tab shows its crashed page.
/// Call on the main thread; observers stay for the rest of the run.
void BowEngineObserveRenderProcessTerminations(
    std::function<void(uint64_t tabID, const char* status, int errorCode)> observer);

/// Called by the engine for each renderer termination: passes it to the observers above. Main thread only.
void BowEngineNoteRenderProcessTerminated(uint64_t tabID, cef_termination_status_t status, int errorCode);

#endif  // BOW_E2E
