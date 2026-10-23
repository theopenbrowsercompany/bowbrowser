// The tab's download handler (the profile's downloads handle downloads from every tab and popup of the profile),
// and keeping a closed tab's browser alive while it downloads.
#import "BowTab+Internal.h"

#import "BowDownloads+Internal.h"
#import "BowEngine.h"

#if BOW_E2E
#include "BowE2EHooks.h"  // E2E seam
#endif

CefRefPtr<CefDownloadHandler> BowTabClient::GetDownloadHandler() {
  return downloadHandler_;
}

bool BowTabClient::RefusesUIRequest(CefRefPtr<CefBrowser> browser, const char* kind) const {
  BowTab* tab = tab_;
  if (!IsOwn(browser) || (tab && !tab.closed)) return false;
#if BOW_E2E  // E2E seam: counts what a closed tab's page was refused.
  BowEngineNoteParkedRequestRefused(kind);
#endif
  return true;
}

@implementation BowTab (Downloads)

- (BOOL)keepClosingBrowserForDownloads:(CefRefPtr<CefBrowser>)browser {
  // Quitting closes every browser at once, which cancels their downloads.
  if (BowEngineIsQuitting()) return NO;
  BowDownloads* downloads = [BowEngine.shared profileWithID:self.profileID].downloads;
  const int browserID = browser->GetIdentifier();
  if (![downloads hasActiveDownloadsForBrowser:browserID]) return NO;
  // Out of every window at once, so the tab leaves its window as any closing tab does, and muted. The page has run
  // its unload handlers, but it is not inert: its timers and network go on (throttled, as in any hidden page). So
  // nothing it asks for may reach the screen (RefusesUIRequest) or keep it alive (no new download starts from it);
  // only the downloads it had running keep it.
  NSView* browserView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
  browserView.autoresizingMask = NSViewNotSizable;
  [BowEngineParkingView() addSubview:browserView];
  browser->GetHost()->SetAudioMuted(true);
  [downloads whenDownloadsOfBrowserEnd:browserID
                                   run:^{
                                     BowTearDownBrowserView(browser);
                                   }];
  // The tab is closed for the app from now on: it reports its close now, and OnBeforeClose, once the downloads end,
  // only tells the engine.
  [self browserClosed];
  return YES;
}

@end
