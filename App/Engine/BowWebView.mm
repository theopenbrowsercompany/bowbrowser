#import "BowWebView.h"

#include "BowEngine+Internal.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"

namespace {

NSString* ToNSString(const CefString& value) {
  return [NSString stringWithUTF8String:value.ToString().c_str()] ?: @"";
}

}  // namespace

class BowBrowserClient;

@interface BowWebView () {
  CefRefPtr<BowBrowserClient> _client;
  CefRefPtr<CefBrowser> _browser;
}
@property(nonatomic, readwrite, copy) NSString* title;
@property(nonatomic, readwrite, copy) NSString* currentURL;
@property(nonatomic) BOOL closeAllowed;
- (void)browserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)browserClosed;
@end

// Receives Chromium's callbacks for one browser and forwards them to its view.
// Every callback runs on the main thread because the app uses CefRunMessageLoop.
class BowBrowserClient : public CefClient,
                         public CefLifeSpanHandler,
                         public CefLoadHandler,
                         public CefDisplayHandler {
 public:
  explicit BowBrowserClient(BowWebView* view) : view_(view) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    BowEngineBrowserCreated(browser);
    [view_ browserCreated:browser];
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    // Allow the close: Chromium then asks the window to close again, and this time it may.
    view_.closeAllowed = YES;
    return false;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    [view_ browserClosed];
    BowEngineBrowserClosed(browser);
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    BowWebView* view = view_;
    view.title = ToNSString(title);
    if (view.onTitleChange) view.onTitleChange(view.title);
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (!frame->IsMain()) return;
    BowWebView* view = view_;
    view.currentURL = ToNSString(url);
    if (view.onAddressChange) view.onAddressChange(view.currentURL);
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int httpStatusCode) override {
    if (!frame->IsMain()) return;
    BowWebView* view = view_;
    if (view.onLoadEnd) view.onLoadEnd(httpStatusCode);
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override {
    // ERR_ABORTED happens when a navigation is replaced by another one; it is not a failure.
    if (!frame->IsMain() || errorCode == ERR_ABORTED) return;
    BowWebView* view = view_;
    if (view.onLoadError) view.onLoadError(errorCode, ToNSString(errorText), ToNSString(failedUrl));
  }

 private:
  __weak BowWebView* view_;

  IMPLEMENT_REFCOUNTING(BowBrowserClient);
};

@implementation BowWebView

- (instancetype)initWithFrame:(NSRect)frame url:(NSString*)url {
  self = [super initWithFrame:frame];
  if (self) {
    _title = @"";
    _currentURL = [url copy];
  }
  return self;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!self.window || _client) return;

  // The browser is created as a child view once this view is in a window.
  _client = new BowBrowserClient(self);
  CefWindowInfo windowInfo;
  NSRect bounds = self.bounds;
  windowInfo.SetAsChild((__bridge void*)self, CefRect(0, 0, bounds.size.width, bounds.size.height));
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  CefBrowserHost::CreateBrowser(windowInfo, _client, self.currentURL.UTF8String, settings, nullptr, nullptr);
}

- (void)browserCreated:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  NSView* browserView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
  browserView.frame = self.bounds;
  browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}

- (void)browserClosed {
  _browser = nullptr;
}

- (void)loadURL:(NSString*)url {
  self.currentURL = url;
  if (_browser) _browser->GetMainFrame()->LoadURL(url.UTF8String);
}

- (BOOL)shouldCloseWindow {
  if (!_browser || self.closeAllowed) return YES;
  _browser->GetHost()->CloseBrowser(false);
  return NO;
}

@end
