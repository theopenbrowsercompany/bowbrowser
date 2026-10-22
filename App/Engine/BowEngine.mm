#import "BowEngine.h"

#include <unistd.h>

#include <cstdio>
#include <map>

#include "BowEngine+Internal.h"
#if BOW_E2E
#include "BowE2EHooks.h"  // E2E seam
#endif
#include "include/cef_app.h"

const int BowEngineQuitTimeoutExitCode = 3;

namespace {

struct BrowserEntry {
  CefRefPtr<CefBrowser> browser;
  // True once DoClose has run: the close can no longer be cancelled and OnBeforeClose follows.
  bool willClose = false;
  // True once CloseBrowser has been called. Until willClose the page may still cancel (its leave prompt).
  bool closeRequested = false;
};

// Open browsers by identifier, plus the number requested but not created yet.
std::map<int, BrowserEntry> gBrowsers;
int gPendingCreations = 0;

bool gQuitting = false;
bool gMessageLoopQuit = false;
CFAbsoluteTime gQuitStart = 0;
dispatch_source_t gQuitWatchdog = nil;

int gExitCode = 0;
NSTimeInterval gQuitDuration = 0;
BowEngineConfiguration* gConfiguration = nil;

void QuitMessageLoopIfDone() {
  if (!gQuitting || gMessageLoopQuit || !gBrowsers.empty() || gPendingCreations > 0) return;
  // CEF requires every OnBeforeClose before the loop ends; an empty map guarantees that.
  gMessageLoopQuit = true;
  CefQuitMessageLoop();
}

void StartQuitWatchdog() {
  NSTimeInterval timeout = gConfiguration.quitTimeout;
  if (timeout <= 0) return;
  // Runs off the main thread so it still fires if the main thread is stuck, for example inside CefShutdown.
  gQuitWatchdog =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
  dispatch_source_set_timer(gQuitWatchdog, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                            DISPATCH_TIME_FOREVER, 0);
  dispatch_source_set_event_handler(gQuitWatchdog, ^{
    fprintf(stderr, "quit: timed out after %.1f seconds\n", timeout);
    fflush(stderr);
    _exit(BowEngineQuitTimeoutExitCode);
  });
  dispatch_resume(gQuitWatchdog);
}

}  // namespace

void BowEngineStart(BowEngineConfiguration* configuration) {
  gConfiguration = configuration;
}

#if BOW_E2E  // E2E seam: the hooks declared in BowE2EHooks.h.
NSNotificationName const BowEngineBrowserCreatedNotification = @"BowEngineBrowserCreatedNotification";

std::vector<CefRefPtr<CefBrowser>> BowEngineOpenBrowsers() {
  std::vector<CefRefPtr<CefBrowser>> browsers;
  for (const auto& [identifier, entry] : gBrowsers) browsers.push_back(entry.browser);
  return browsers;
}
#endif

void BowEngineBrowserCreationStarted() {
  gPendingCreations++;
}

void BowEngineBrowserCreationFailed() {
  if (gPendingCreations > 0) gPendingCreations--;
  QuitMessageLoopIfDone();
}

void BowEngineBrowserCreated(CefRefPtr<CefBrowser> browser) {
  // Popups are created by CEF, not requested through BowEngineBrowserCreationStarted.
  if (!browser->IsPopup() && gPendingCreations > 0) gPendingCreations--;
  gBrowsers[browser->GetIdentifier()] = BrowserEntry{browser};
#if BOW_E2E  // E2E seam
  [[NSNotificationCenter defaultCenter] postNotificationName:BowEngineBrowserCreatedNotification object:nil];
#endif
  if (gQuitting) {
    // Not from inside OnAfterCreated: close on a later main thread task.
    dispatch_async(dispatch_get_main_queue(), ^{
      BowEngineCloseBrowser(browser, false);
    });
  }
}

void BowEngineCloseBrowser(CefRefPtr<CefBrowser> browser, bool askAgain) {
  auto it = gBrowsers.find(browser->GetIdentifier());
  if (it == gBrowsers.end() || it->second.willClose) return;
  if (it->second.closeRequested && !askAgain) return;
  it->second.closeRequested = true;
  browser->GetHost()->CloseBrowser(false);
}

void BowEngineBrowserWillClose(CefRefPtr<CefBrowser> browser) {
  auto it = gBrowsers.find(browser->GetIdentifier());
  if (it != gBrowsers.end()) it->second.willClose = true;
}

void BowEngineBrowserClosed(CefRefPtr<CefBrowser> browser) {
  gBrowsers.erase(browser->GetIdentifier());
  QuitMessageLoopIfDone();
}

void BowEngineDidShutDown() {
  if (gQuitWatchdog) {
    dispatch_source_cancel(gQuitWatchdog);
    gQuitWatchdog = nil;
  }
  if (gQuitStart > 0) gQuitDuration = CFAbsoluteTimeGetCurrent() - gQuitStart;
  if (gConfiguration.reportsQuitTime && gQuitStart > 0) {
    fprintf(stderr, "quit: seconds=%.2f\n", gQuitDuration);
    fflush(stderr);
  }
}

@implementation BowEngine

+ (int)exitCode {
  return gExitCode;
}

+ (void)setExitCode:(int)exitCode {
  gExitCode = exitCode;
}

+ (NSTimeInterval)quitDuration {
  return gQuitDuration;
}

+ (void)startQuitClock {
  if (gQuitStart > 0) return;
  gQuitStart = CFAbsoluteTimeGetCurrent();
  StartQuitWatchdog();
}

+ (void)quit {
  [self startQuitClock];
  // A second quit means the person asked again (for example after staying on a page that asked to be kept),
  // so browsers that have not accepted closing yet are asked again.
  const bool askAgain = gQuitting;
  gQuitting = true;
  // Copy first, so a browser reporting back during the loop cannot change what is being iterated.
  const std::map<int, BrowserEntry> browsers = gBrowsers;
  for (const auto& [identifier, entry] : browsers) {
    BowEngineCloseBrowser(entry.browser, askAgain);
  }
  QuitMessageLoopIfDone();
}

@end
