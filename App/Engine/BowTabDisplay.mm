// The tab's CefDisplayHandler: title, address, favicon, status text, fullscreen and camera and microphone use.
#import "BowTab+Internal.h"

void BowTabClient::OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) {
  if (!IsOwn(browser)) return;
  NSString* newTitle = BowToNSString(title);
  [tab_ updateState:^(NSURL* __strong*, NSString* __strong* title, NSURL* __strong*, BOOL*, BOOL*, BOOL*) {
    *title = newTitle;
  }];
}

void BowTabClient::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   const CefString& url) {
  if (!IsOwn(browser) || !frame->IsMain()) return;
  NSURL* newURL = BowToNSURL(url);
  [tab_ updateState:^(NSURL* __strong* url, NSString* __strong*, NSURL* __strong*, BOOL*, BOOL*, BOOL*) {
    *url = newURL;
  }];
}

void BowTabClient::OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& iconURLs) {
  if (!IsOwn(browser)) return;
  NSURL* newFaviconURL = iconURLs.empty() ? nil : BowToNSURL(iconURLs.front());
  [tab_ updateState:^(NSURL* __strong*, NSString* __strong*, NSURL* __strong* faviconURL, BOOL*, BOOL*, BOOL*) {
    *faviconURL = newFaviconURL;
  }];
}

void BowTabClient::OnFullscreenModeChange(CefRefPtr<CefBrowser> browser, bool fullscreen) {
  if (!IsOwn(browser)) return;
  [tab_ fullscreenChanged:fullscreen];
}

void BowTabClient::OnStatusMessage(CefRefPtr<CefBrowser> browser, const CefString& value) {
  if (!IsOwn(browser)) return;
  [tab_ statusTextChanged:BowToNSString(value)];
}

void BowTabClient::OnMediaAccessChange(CefRefPtr<CefBrowser> browser, bool hasVideoAccess, bool hasAudioAccess) {
  if (!IsOwn(browser)) return;
  [tab_ mediaCaptureChangedVideo:hasVideoAccess audio:hasAudioAccess];
}

@implementation BowTab (Display)

- (void)fullscreenChanged:(BOOL)isFullscreen {
  id<BowTabUIDelegate> delegate = self.uiDelegate;
  if ([delegate respondsToSelector:@selector(tab:fullscreenDidChange:)]) {
    [delegate tab:self fullscreenDidChange:isFullscreen];
  }
}

- (void)statusTextChanged:(NSString*)text {
  // Only a change reaches the delegate; the text starts empty.
  if (self.closed || [(_statusText ?: @"") isEqualToString:text]) return;
  _statusText = [text copy];
  id<BowTabUIDelegate> delegate = self.uiDelegate;
  if ([delegate respondsToSelector:@selector(tab:statusTextDidChange:)]) {
    [delegate tab:self statusTextDidChange:_statusText];
  }
}

@end
