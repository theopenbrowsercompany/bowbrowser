#import "BowSpikeReparent.h"

#include "BowE2EHooks.h"

@implementation BowSpikeReparent

+ (NSView*)browserViewForTabID:(uint64_t)tabID {
  CefRefPtr<CefBrowser> browser = BowEngineBrowserForTabID(tabID);
  if (!browser) return nil;
  return (__bridge NSView*)browser->GetHost()->GetWindowHandle();
}

+ (BOOL)notifyScreenInfoChangedForTabID:(uint64_t)tabID {
  CefRefPtr<CefBrowser> browser = BowEngineBrowserForTabID(tabID);
  if (!browser) return NO;
  browser->GetHost()->NotifyScreenInfoChanged();
  return YES;
}

+ (BOOL)setFocus:(BOOL)focus forTabID:(uint64_t)tabID {
  CefRefPtr<CefBrowser> browser = BowEngineBrowserForTabID(tabID);
  if (!browser) return NO;
  browser->GetHost()->SetFocus(focus);
  return YES;
}

@end
