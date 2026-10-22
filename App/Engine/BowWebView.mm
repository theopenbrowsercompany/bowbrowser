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

typedef NS_ENUM(NSInteger, BowBrowserState) {
  BowBrowserStateNotCreated,
  BowBrowserStateCreating,
  BowBrowserStateOpen,
  BowBrowserStateClosed,
};

@interface BowWebView () {
  CefRefPtr<BowBrowserClient> _client;
  CefRefPtr<CefBrowser> _browser;
}
@property(nonatomic, readwrite, copy) NSString* title;
@property(nonatomic, readwrite, copy) NSString* currentURL;
@property(nonatomic) BowBrowserState browserState;
// The window asked to close before the browser existed; close the browser as soon as it does.
@property(nonatomic) BOOL closeWhenCreated;
- (void)browserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)browserClosed;
@end

namespace {

// Destroys a closing browser by removing Chromium's host view. In windowed Alloy style on macOS the browser is
// destroyed only when that view is deallocated, and OnBeforeClose follows. Runs as its own main thread task,
// never inside a CEF callback.
void TearDownBrowserView(CefRefPtr<CefBrowser> browser) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!browser->IsValid()) return;
    @autoreleasepool {
      NSView* hostView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
      [hostView removeFromSuperview];
    }
  });
}

}  // namespace

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

  // Popups opened by the page (window.open) share this client but live in windows CEF creates and closes
  // itself. The engine tracks them so quitting waits for them; the view only follows its own browser.

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    BowEngineBrowserCreated(browser);
    if (!browser->IsPopup()) [view_ browserCreated:browser];
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    BowEngineBrowserWillClose(browser);
    // Returning false makes CEF send performClose: to the browser's window, which suits a popup's own window.
    if (browser->IsPopup()) return false;
    // For the view's browser that would tie the browser to the window, which is destroyed only when deallocated.
    // Tear down the browser's own view instead, so a browser can close without closing its window.
    TearDownBrowserView(browser);
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (!browser->IsPopup()) [view_ browserClosed];
    BowEngineBrowserClosed(browser);
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    if (browser->IsPopup()) return;
    BowWebView* view = view_;
    view.title = ToNSString(title);
    if (view.onTitleChange) view.onTitleChange(view.title);
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (browser->IsPopup() || !frame->IsMain()) return;
    BowWebView* view = view_;
    view.currentURL = ToNSString(url);
    if (view.onAddressChange) view.onAddressChange(view.currentURL);
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int httpStatusCode) override {
    if (browser->IsPopup() || !frame->IsMain()) return;
    BowWebView* view = view_;
    if (view.onLoadEnd) view.onLoadEnd(httpStatusCode);
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override {
    // ERR_ABORTED happens when a navigation is replaced by another one; it is not a failure.
    if (browser->IsPopup() || !frame->IsMain() || errorCode == ERR_ABORTED) return;
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
  self.browserState = BowBrowserStateCreating;
  BowEngineBrowserCreationStarted();
  CefWindowInfo windowInfo;
  NSRect bounds = self.bounds;
  windowInfo.SetAsChild((__bridge void*)self, CefRect(0, 0, bounds.size.width, bounds.size.height));
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  if (!CefBrowserHost::CreateBrowser(windowInfo, _client, self.currentURL.UTF8String, settings, nullptr, nullptr)) {
    BowEngineBrowserCreationFailed();
    self.browserState = BowBrowserStateClosed;
  }
}

- (void)browserCreated:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  self.browserState = BowBrowserStateOpen;
  // Size Chromium's view without keeping a reference to it: its lifetime decides the browser's.
  NSView* browserView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
  browserView.frame = self.bounds;
  browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  if (self.closeWhenCreated) {
    // Not from inside OnAfterCreated: close on a later main thread task.
    dispatch_async(dispatch_get_main_queue(), ^{
      BowEngineCloseBrowser(browser, false);
    });
  }
}

- (void)browserClosed {
  _browser = nullptr;
  self.browserState = BowBrowserStateClosed;
  // Report on a later main thread task, so the app never closes windows from inside a CEF callback.
  __weak BowWebView* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    BowWebView* view = weakSelf;
    if (view.onBrowserClosed) view.onBrowserClosed();
  });
}

- (void)loadURL:(NSString*)url {
  self.currentURL = url;
  if (_browser) _browser->GetMainFrame()->LoadURL(url.UTF8String);
}

- (BOOL)shouldCloseWindow {
  switch (self.browserState) {
    case BowBrowserStateNotCreated:
    case BowBrowserStateClosed:
      return YES;
    case BowBrowserStateCreating:
      self.closeWhenCreated = YES;
      return NO;
    case BowBrowserStateOpen:
      // Each close request from the person asks the page again, as quitting again does.
      BowEngineCloseBrowser(_browser, true);
      return NO;
  }
}

@end
