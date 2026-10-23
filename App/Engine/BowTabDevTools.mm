// DevTools for a tab's page, in a browser of its own.
#import "BowTab+Internal.h"

#if BOW_E2E  // E2E seam: the DevTools requests e2e runs record instead of opening a window on screen.
#include <map>
#include <utility>

#include "BowE2EHooks.h"  // E2E seam

namespace {
std::map<uint64_t, std::pair<size_t, CGPoint>> gDevToolsRequests;
}

size_t BowEngineDevToolsRequests(uint64_t tabID, CGPoint* inspectedPoint) {
  auto found = gDevToolsRequests.find(tabID);
  if (found == gDevToolsRequests.end()) {
    if (inspectedPoint) *inspectedPoint = CGPointMake(-1, -1);
    return 0;
  }
  if (inspectedPoint) *inspectedPoint = found->second.second;
  return found->second.first;
}
#endif

@implementation BowTab (DevTools)

- (void)showDevToolsInspectingPoint:(CGPoint)point {
  [self openDevToolsAt:CefPoint(static_cast<int>(point.x), static_cast<int>(point.y))];
}

- (void)showDevTools {
  [self openDevToolsAt:CefPoint()];
}

// The DevTools browser shares the tab's client, which treats it as one of the popups the engine opens in windows of
// its own: the engine tracks it so quitting closes it and waits for it, it keeps CEF's defaults for everything else,
// and Chromium closes it with the tab's browser.
- (void)openDevToolsAt:(const CefPoint&)point {
  if (self.closed || !_browser || self.willClose) return;
#if BOW_E2E  // E2E seam: an e2e run records the request instead of opening a window that would show on screen.
  if (BowEngineParksPopups()) {
    auto& entry = gDevToolsRequests[self.tabID];
    entry.first += 1;
    entry.second = point.x == 0 && point.y == 0 ? CGPointMake(-1, -1) : CGPointMake(point.x, point.y);
    return;
  }
#endif
  // DevTools is a Chrome style window of its own: CEF supports only Chrome style for DevTools, and a Chrome style
  // browser takes no parent view on macOS, so it can be neither docked in the window nor kept out of sight.
  CefWindowInfo windowInfo;
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  CefBrowserSettings settings;
  _browser->GetHost()->ShowDevTools(windowInfo, _client, settings, point);
}

- (void)closeDevTools {
  if (_browser) _browser->GetHost()->CloseDevTools();
}

- (BOOL)hasDevTools {
  return _browser && _browser->GetHost()->HasDevTools();
}

@end
