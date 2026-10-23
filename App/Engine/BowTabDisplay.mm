// The tab's CefDisplayHandler: title, address, favicon and fullscreen.
#import "BowTab+Internal.h"

void BowTabClient::OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) {
  if (browser->IsPopup()) return;
  NSString* newTitle = BowToNSString(title);
  [tab_ updateState:^(NSURL* __strong*, NSString* __strong* title, NSURL* __strong*, BOOL*, BOOL*, BOOL*) {
    *title = newTitle;
  }];
}

void BowTabClient::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   const CefString& url) {
  if (browser->IsPopup() || !frame->IsMain()) return;
  NSURL* newURL = BowToNSURL(url);
  [tab_ updateState:^(NSURL* __strong* url, NSString* __strong*, NSURL* __strong*, BOOL*, BOOL*, BOOL*) {
    *url = newURL;
  }];
}

void BowTabClient::OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& iconURLs) {
  if (browser->IsPopup()) return;
  NSURL* newFaviconURL = iconURLs.empty() ? nil : BowToNSURL(iconURLs.front());
  [tab_ updateState:^(NSURL* __strong*, NSString* __strong*, NSURL* __strong* faviconURL, BOOL*, BOOL*, BOOL*) {
    *faviconURL = newFaviconURL;
  }];
}

void BowTabClient::OnFullscreenModeChange(CefRefPtr<CefBrowser> browser, bool fullscreen) {
  if (browser->IsPopup()) return;
  [tab_ fullscreenChanged:fullscreen];
}

@implementation BowTab (Display)

- (void)fullscreenChanged:(BOOL)isFullscreen {
  id<BowTabUIDelegate> delegate = self.uiDelegate;
  if ([delegate respondsToSelector:@selector(tab:fullscreenDidChange:)]) {
    [delegate tab:self fullscreenDidChange:isFullscreen];
  }
}

@end
