// The tab's download handler (the profile's downloads handle downloads from every tab and popup of the profile),
// and keeping a closed tab's browser alive while it downloads.
#import "BowTab+Internal.h"

#import "BowDownloads+Internal.h"
#import "BowEngine.h"

CefRefPtr<CefDownloadHandler> BowTabClient::GetDownloadHandler() {
  return downloadHandler_;
}

@implementation BowTab (Downloads)

- (BOOL)keepClosingBrowserForDownloads:(CefRefPtr<CefBrowser>)browser {
  // Quitting closes every browser at once, which cancels their downloads.
  if (BowEngineIsQuitting()) return NO;
  BowDownloads* downloads = [BowEngine.shared profileWithID:self.profileID].downloads;
  const int browserID = browser->GetIdentifier();
  if (![downloads hasActiveDownloadsForBrowser:browserID]) return NO;
  // Out of every window at once, so the tab leaves its window as any closing tab does. The page has run its unload
  // handlers already; only its downloads keep the browser.
  NSView* browserView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
  browserView.autoresizingMask = NSViewNotSizable;
  [BowEngineParkingView() addSubview:browserView];
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
