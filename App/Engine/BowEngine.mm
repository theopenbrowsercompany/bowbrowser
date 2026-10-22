#import "BowEngine.h"

#include <algorithm>
#include <vector>

#include "BowEngine+Internal.h"
#include "include/cef_app.h"

namespace {

std::vector<CefRefPtr<CefBrowser>> gBrowsers;
bool gQuitting = false;
int gExitCode = 0;

}  // namespace

void BowEngineBrowserCreated(CefRefPtr<CefBrowser> browser) {
  gBrowsers.push_back(browser);
}

void BowEngineBrowserClosed(CefRefPtr<CefBrowser> browser) {
  gBrowsers.erase(std::remove_if(gBrowsers.begin(), gBrowsers.end(),
                                 [&](const CefRefPtr<CefBrowser>& b) { return b->IsSame(browser); }),
                  gBrowsers.end());
  if (gQuitting && gBrowsers.empty()) {
    CefQuitMessageLoop();
  }
}

@implementation BowEngine

+ (int)exitCode {
  return gExitCode;
}

+ (void)setExitCode:(int)exitCode {
  gExitCode = exitCode;
}

+ (void)quit {
  gQuitting = true;
  if (gBrowsers.empty()) {
    CefQuitMessageLoop();
    return;
  }
  // Closing goes through each browser's window, which reports back in BowEngineBrowserClosed.
  for (const auto& browser : std::vector<CefRefPtr<CefBrowser>>(gBrowsers)) {
    browser->GetHost()->CloseBrowser(false);
  }
}

@end
