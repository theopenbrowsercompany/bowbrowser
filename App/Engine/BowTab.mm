#import "BowTab.h"

#import <AppKit/AppKit.h>

#include "BowEngine+Internal.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"

namespace {

NSString* ToNSString(const CefString& value) {
  return [NSString stringWithUTF8String:value.ToString().c_str()] ?: @"";
}

NSURL* _Nullable ToNSURL(const CefString& value) {
  NSString* string = ToNSString(value);
  return string.length > 0 ? [NSURL URLWithString:string] : nil;
}

// Tab IDs are unique for the life of the engine and never reused.
uint64_t gNextTabID = 1;

}  // namespace

#pragma mark - BowTabState

@interface BowTabState ()
- (instancetype)initWithTabID:(uint64_t)tabID
                          url:(nullable NSURL*)url
                        title:(NSString*)title
                   faviconURL:(nullable NSURL*)faviconURL
                      loading:(BOOL)loading
                    canGoBack:(BOOL)canGoBack
                 canGoForward:(BOOL)canGoForward NS_DESIGNATED_INITIALIZER;
@end

@implementation BowTabState

- (instancetype)initWithTabID:(uint64_t)tabID
                          url:(NSURL*)url
                        title:(NSString*)title
                   faviconURL:(NSURL*)faviconURL
                      loading:(BOOL)loading
                    canGoBack:(BOOL)canGoBack
                 canGoForward:(BOOL)canGoForward {
  self = [super init];
  if (self) {
    _tabID = tabID;
    _url = [url copy];
    _title = [title copy];
    _faviconURL = [faviconURL copy];
    _loading = loading;
    _canGoBack = canGoBack;
    _canGoForward = canGoForward;
  }
  return self;
}

- (NSString*)description {
  return [NSString stringWithFormat:@"<BowTabState %llu %@ \"%@\"%@>", _tabID, _url.absoluteString ?: @"(none)",
                                    _title, _loading ? @" loading" : @""];
}

@end

#pragma mark - BowTab

class BowTabClient;

@interface BowTab () {
  CefRefPtr<BowTabClient> _client;
  CefRefPtr<CefBrowser> _browser;
  // Completions of closeWithCompletion: calls waiting for the page to close or to stay.
  NSMutableArray<void (^)(BOOL)>* _closeCompletions;
  // A close or a load asked for before the browser existed, done once it does.
  BOOL _closeWhenCreated;
  NSURL* _loadWhenCreated;
}
@property(nonatomic, readwrite) BowTabState* state;
@property(nonatomic, readwrite, getter=isClosed) BOOL closed;
- (void)browserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)browserWillClose;
- (void)browserClosed;
- (void)updateState:(void (^)(NSURL* _Nullable __strong* url,
                              NSString* __strong* title,
                              NSURL* _Nullable __strong* faviconURL,
                              BOOL* loading,
                              BOOL* canGoBack,
                              BOOL* canGoForward))change;
- (void)loadEnded:(NSInteger)httpStatusCode;
- (void)loadFailed:(NSInteger)errorCode text:(NSString*)errorText url:(NSString*)failedURL;
- (void)runLeavePromptForReload:(BOOL)isReload callback:(CefRefPtr<CefJSDialogCallback>)callback;
@end

namespace {

// Destroys a closing browser by removing Chromium's view, wherever it is (a host view or the parking view). In
// windowed Alloy style on macOS the browser is destroyed only when that view is deallocated, and OnBeforeClose
// follows. Runs as its own main thread task, never inside a CEF callback.
void TearDownBrowserView(CefRefPtr<CefBrowser> browser) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!browser->IsValid()) return;
    @autoreleasepool {
      NSView* browserView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
      [browserView removeFromSuperview];
    }
  });
}

}  // namespace

// Receives Chromium's callbacks for one tab's browser and forwards them to the tab.
// Every callback runs on the main thread because the app uses CefRunMessageLoop.
class BowTabClient : public CefClient,
                     public CefLifeSpanHandler,
                     public CefLoadHandler,
                     public CefDisplayHandler,
                     public CefJSDialogHandler {
 public:
  explicit BowTabClient(BowTab* tab) : tab_(tab) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }

  // Popups opened by the page (window.open) share this client but live in windows CEF creates and closes
  // itself. The engine tracks them so quitting waits for them; the tab only follows its own browser.

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    if (browser->IsPopup()) {
      BowEngineBrowserCreated(browser, nil);
      return;
    }
    BowTab* tab = tab_;
    [tab browserCreated:browser];
    BowEngineBrowserCreated(browser, tab);
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    BowEngineBrowserWillClose(browser);
    // Returning false makes CEF send performClose: to the browser's window, which suits a popup's own window.
    if (browser->IsPopup()) return false;
    // A tab's browser is not tied to a window: tear down its own view instead.
    [tab_ browserWillClose];
    TearDownBrowserView(browser);
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (!browser->IsPopup()) [tab_ browserClosed];
    BowEngineBrowserClosed(browser);
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    if (browser->IsPopup()) return;
    NSString* newTitle = ToNSString(title);
    [tab_ updateState:^(NSURL* __strong*, NSString* __strong* title, NSURL* __strong*, BOOL*, BOOL*, BOOL*) {
      *title = newTitle;
    }];
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (browser->IsPopup() || !frame->IsMain()) return;
    NSURL* newURL = ToNSURL(url);
    [tab_ updateState:^(NSURL* __strong* url, NSString* __strong*, NSURL* __strong*, BOOL*, BOOL*, BOOL*) {
      *url = newURL;
    }];
  }

  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& iconURLs) override {
    if (browser->IsPopup()) return;
    NSURL* newFaviconURL = iconURLs.empty() ? nil : ToNSURL(iconURLs.front());
    [tab_ updateState:^(NSURL* __strong*, NSString* __strong*, NSURL* __strong* faviconURL, BOOL*, BOOL*, BOOL*) {
      *faviconURL = newFaviconURL;
    }];
  }

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override {
    if (browser->IsPopup()) return;
    [tab_ updateState:^(NSURL* __strong*, NSString* __strong*, NSURL* __strong*, BOOL* loading, BOOL* back,
                        BOOL* forward) {
      *loading = isLoading;
      *back = canGoBack;
      *forward = canGoForward;
    }];
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int httpStatusCode) override {
    if (browser->IsPopup() || !frame->IsMain()) return;
    [tab_ loadEnded:httpStatusCode];
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override {
    // ERR_ABORTED happens when a navigation is replaced by another one; it is not a failure.
    if (browser->IsPopup() || !frame->IsMain() || errorCode == ERR_ABORTED) return;
    [tab_ loadFailed:errorCode text:ToNSString(errorText) url:ToNSString(failedUrl)];
  }

  // The tab asks "leave this page?" itself, so it knows whether the person stayed and can report that a close was
  // cancelled. Popups keep CEF's own prompt.
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                            const CefString& messageText,
                            bool isReload,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    if (browser->IsPopup()) return false;
    [tab_ runLeavePromptForReload:isReload callback:callback];
    return true;
  }

 private:
  __weak BowTab* tab_;

  IMPLEMENT_REFCOUNTING(BowTabClient);
};

@implementation BowTab

- (instancetype)initWithProfile:(BowProfile*)profile url:(NSURL*)url {
  self = [super init];
  if (self) {
    _tabID = gNextTabID++;
    _profileID = [profile.profileID copy];
    _closeCompletions = [NSMutableArray array];
    _state = [[BowTabState alloc] initWithTabID:_tabID
                                            url:nil
                                          title:@""
                                     faviconURL:nil
                                        loading:NO
                                      canGoBack:NO
                                   canGoForward:NO];
    _client = new BowTabClient(self);

    // The browser starts out detached, in the engine's parking view, until a host view attaches the tab.
    NSView* parkingView = BowEngineParkingView();
    CefWindowInfo windowInfo;
    windowInfo.SetAsChild((__bridge void*)parkingView,
                          CefRect(0, 0, parkingView.bounds.size.width, parkingView.bounds.size.height));
    windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    CefBrowserSettings settings;
    BowEngineBrowserCreationStarted(self);
    // Created asynchronously: a new persistent profile's context initializes on disk first, and CEF waits for it.
    // The browser arrives in OnAfterCreated.
    if (!CefBrowserHost::CreateBrowser(windowInfo, _client, url.absoluteString.UTF8String, settings, nullptr,
                                       profile.requestContext)) {
      BowEngineBrowserCreationFailed(self);
      _closed = YES;
      [self finishCloseCompletions:YES];
      [self reportClosed];
    }
  }
  return self;
}

- (CefRefPtr<CefBrowser>)browser {
  return _browser;
}

- (NSView*)browserView {
  if (!_browser || self.willClose) return nil;
  return (__bridge NSView*)_browser->GetHost()->GetWindowHandle();
}

- (void)browserCreated:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  // Size Chromium's view without keeping a reference to it: its lifetime decides the browser's.
  NSView* browserView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
  browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  // A host view may have attached the tab while the browser was being created.
  NSView* hostView = self.hostView;
  if (hostView) [hostView addSubview:browserView];
  browserView.frame = browserView.superview.bounds;

  if (_closeWhenCreated) {
    // Not from inside OnAfterCreated: close on a later main thread task.
    dispatch_async(dispatch_get_main_queue(), ^{
      BowEngineCloseBrowser(browser, true);
    });
  } else if (_loadWhenCreated) {
    browser->GetMainFrame()->LoadURL(_loadWhenCreated.absoluteString.UTF8String);
  }
  _loadWhenCreated = nil;
}

- (void)browserWillClose {
  _willClose = YES;
}

- (void)browserClosed {
  _browser = nullptr;
  self.closed = YES;
  [self finishCloseCompletions:YES];
  [self reportClosed];
}

// Reports on a later main thread task, so the app never reacts to a close from inside a CEF callback.
- (void)reportClosed {
  __weak BowTab* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    BowTab* tab = weakSelf;
    if (tab.onClose) tab.onClose();
  });
}

- (void)finishCloseCompletions:(BOOL)closed {
  NSArray<void (^)(BOOL)>* completions = [_closeCompletions copy];
  [_closeCompletions removeAllObjects];
  for (void (^completion)(BOOL) in completions) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(closed);
    });
  }
}

- (void)updateState:(void (^)(NSURL* _Nullable __strong* url,
                              NSString* __strong* title,
                              NSURL* _Nullable __strong* faviconURL,
                              BOOL* loading,
                              BOOL* canGoBack,
                              BOOL* canGoForward))change {
  BowTabState* old = self.state;
  NSURL* url = old.url;
  NSString* title = old.title;
  NSURL* faviconURL = old.faviconURL;
  BOOL loading = old.loading;
  BOOL canGoBack = old.canGoBack;
  BOOL canGoForward = old.canGoForward;
  change(&url, &title, &faviconURL, &loading, &canGoBack, &canGoForward);
  if ((url == old.url || [url isEqual:old.url]) && [title isEqualToString:old.title] &&
      (faviconURL == old.faviconURL || [faviconURL isEqual:old.faviconURL]) && loading == old.loading &&
      canGoBack == old.canGoBack && canGoForward == old.canGoForward) {
    return;
  }
  self.state = [[BowTabState alloc] initWithTabID:_tabID
                                              url:url
                                            title:title
                                       faviconURL:faviconURL
                                          loading:loading
                                        canGoBack:canGoBack
                                     canGoForward:canGoForward];
  if (self.onStateChange) self.onStateChange(self.state);
}

- (void)loadEnded:(NSInteger)httpStatusCode {
  if (self.onLoadEnd) self.onLoadEnd(httpStatusCode);
}

- (void)loadFailed:(NSInteger)errorCode text:(NSString*)errorText url:(NSString*)failedURL {
  if (self.onLoadError) self.onLoadError(errorCode, errorText, failedURL);
}

- (void)loadURL:(NSURL*)url {
  if (_browser) {
    _browser->GetMainFrame()->LoadURL(url.absoluteString.UTF8String);
  } else if (!self.closed) {
    _loadWhenCreated = [url copy];
  }
}

- (void)goBack {
  if (_browser) _browser->GoBack();
}

- (void)goForward {
  if (_browser) _browser->GoForward();
}

- (void)reload {
  if (_browser) _browser->Reload();
}

- (void)stop {
  if (_browser) _browser->StopLoad();
}

- (void)closeWithCompletion:(void (^)(BOOL))completion {
  if (self.closed) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(YES);
    });
    return;
  }
  [_closeCompletions addObject:[completion copy]];
  if (!_browser) {
    _closeWhenCreated = YES;
    return;
  }
  // Each close request asks the page again, as quitting again does.
  BowEngineCloseBrowser(_browser, true);
}

- (void)runLeavePromptForReload:(BOOL)isReload callback:(CefRefPtr<CefJSDialogCallback>)callback {
  CefRefPtr<CefBrowser> browser = _browser;
  __weak BowTab* weakSelf = self;
  void (^answer)(BOOL) = ^(BOOL leave) {
    callback->Continue(leave, CefString());
    // Staying on a reload prompt keeps the page; it says nothing about a pending close.
    if (!leave && !isReload && browser && BowEngineBrowserCloseCancelled(browser)) {
      [weakSelf finishCloseCompletions:NO];
    }
  };

  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = isReload ? @"Reload this site?" : @"Leave this site?";
  alert.informativeText = @"Changes you made may not be saved.";
  [alert addButtonWithTitle:isReload ? @"Reload" : @"Leave"];
  [alert addButtonWithTitle:@"Cancel"];
  NSWindow* window = self.hostView.window;
  if (window) {
    [alert beginSheetModalForWindow:window
                  completionHandler:^(NSModalResponse response) {
                    answer(response == NSAlertFirstButtonReturn);
                  }];
  } else {
    // A detached tab has no window to attach a sheet to. Ask outside the CEF callback.
    dispatch_async(dispatch_get_main_queue(), ^{
      answer([alert runModal] == NSAlertFirstButtonReturn);
    });
  }
}

@end
