#import "BowTab.h"

#import <AppKit/AppKit.h>

#include <atomic>

#import "BowTab+Internal.h"
#include "include/cef_image.h"

namespace {

// Tab IDs are unique for the life of the engine and never reused.
uint64_t gNextTabID = 1;

// Hands a downloaded site icon to the tab's caller as an NSImage with every scale the download has.
class FaviconCallback : public CefDownloadImageCallback {
 public:
  explicit FaviconCallback(void (^completion)(NSImage* _Nullable)) : completion_([completion copy]) {}

  void OnDownloadImageFinished(const CefString&, int, CefRefPtr<CefImage> image) override {
    NSImage* result = nil;
    if (image && !image->IsEmpty()) {
      result = [[NSImage alloc] initWithSize:NSMakeSize(image->GetWidth(), image->GetHeight())];
      for (float scale : {1.0f, 2.0f}) {
        int width = 0;
        int height = 0;
        CefRefPtr<CefBinaryValue> png = image->GetAsPNG(scale, true, width, height);
        if (!png || png->GetSize() == 0) continue;
        NSMutableData* data = [NSMutableData dataWithLength:png->GetSize()];
        png->GetData(data.mutableBytes, data.length, 0);
        NSBitmapImageRep* rep = [NSBitmapImageRep imageRepWithData:data];
        if (!rep) continue;
        rep.size = result.size;
        [result addRepresentation:rep];
      }
      if (result.representations.count == 0) result = nil;
    }
    void (^completion)(NSImage* _Nullable) = completion_;
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(result);
    });
  }

 private:
  void (^completion_)(NSImage* _Nullable);
  IMPLEMENT_REFCOUNTING(FaviconCallback);
};

}  // namespace

NSString* const kBowAbortedText = @"ERR_ABORTED";

NSString* BowToNSString(const CefString& value) {
  return [NSString stringWithUTF8String:value.ToString().c_str()] ?: @"";
}

NSURL* _Nullable BowToNSURL(const CefString& value) {
  NSString* string = BowToNSString(value);
  return string.length > 0 ? [NSURL URLWithString:string] : nil;
}

void BowRunOnMain(dispatch_block_t block) {
  if (NSThread.isMainThread) {
    block();
  } else {
    dispatch_async(dispatch_get_main_queue(), block);
  }
}

BowNavigationTransition BowToTransition(cef_transition_type_t type) {
  if (type & TT_FORWARD_BACK_FLAG) return BowNavigationTransitionBackForward;
  switch (type & TT_SOURCE_MASK) {
    case TT_LINK:
      return BowNavigationTransitionLink;
    case TT_EXPLICIT:
    case TT_AUTO_BOOKMARK:
    case TT_GENERATED:
    case TT_KEYWORD:
    case TT_KEYWORD_GENERATED:
      return BowNavigationTransitionTyped;
    case TT_FORM_SUBMIT:
      return BowNavigationTransitionFormSubmit;
    case TT_RELOAD:
      return BowNavigationTransitionReload;
    default:
      return BowNavigationTransitionOther;
  }
}

void BowTearDownBrowserView(CefRefPtr<CefBrowser> browser) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!browser->IsValid()) return;
    @autoreleasepool {
      NSView* browserView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
      [browserView removeFromSuperview];
    }
  });
}

@implementation BowAnswerOnce {
  dispatch_block_t _fallback;
  std::atomic<bool> _answered;
}

- (instancetype)initWithFallback:(dispatch_block_t)fallback {
  self = [super init];
  if (self) {
    _fallback = [fallback copy];
    _answered = false;
  }
  return self;
}

- (BOOL)claim {
  return !_answered.exchange(true);
}

- (void)dealloc {
  if (!_answered) dispatch_async(dispatch_get_main_queue(), _fallback);
}

@end

#pragma mark - BowTabState

@implementation BowTabState

- (instancetype)initWithTabID:(uint64_t)tabID
                          url:(NSURL*)url
                        title:(NSString*)title
                   faviconURL:(NSURL*)faviconURL
                      loading:(BOOL)loading
                    canGoBack:(BOOL)canGoBack
                 canGoForward:(BOOL)canGoForward
                      audible:(BOOL)audible
               capturingVideo:(BOOL)capturingVideo
               capturingAudio:(BOOL)capturingAudio {
  self = [super init];
  if (self) {
    _tabID = tabID;
    _url = [url copy];
    _title = [title copy];
    _faviconURL = [faviconURL copy];
    _loading = loading;
    _canGoBack = canGoBack;
    _canGoForward = canGoForward;
    _audible = audible;
    _capturingVideo = capturingVideo;
    _capturingAudio = capturingAudio;
  }
  return self;
}

- (NSString*)description {
  return [NSString stringWithFormat:@"<BowTabState %llu %@ \"%@\"%@>", _tabID, _url.absoluteString ?: @"(none)",
                                    _title, _loading ? @" loading" : @""];
}

@end

#pragma mark - BowFindResult

@implementation BowFindResult

- (instancetype)initWithMatchCount:(NSInteger)matchCount
                       activeMatch:(NSInteger)activeMatch
                       finalUpdate:(BOOL)finalUpdate {
  self = [super init];
  if (self) {
    _matchCount = matchCount;
    _activeMatch = activeMatch;
    _finalUpdate = finalUpdate;
  }
  return self;
}

- (NSString*)description {
  return [NSString stringWithFormat:@"<BowFindResult %ld of %ld%@>", (long)_activeMatch, (long)_matchCount,
                                    _finalUpdate ? @" final" : @""];
}

@end

#pragma mark - BowTab

@implementation BowTab

- (instancetype)initWithProfile:(BowProfile*)profile url:(NSURL*)url {
  return [self initWithProfileID:profile.profileID
                 downloadHandler:profile.downloads.handler
                  requestContext:profile.requestContext
                             url:url];
}

- (instancetype)initWithProfileID:(NSString*)profileID
                  downloadHandler:(CefRefPtr<CefDownloadHandler>)downloadHandler
                   requestContext:(CefRefPtr<CefRequestContext>)requestContext
                              url:(NSURL*)url {
  self = [self initWithProfileID:profileID downloadHandler:downloadHandler];
  if (self) {
    // The browser starts out detached, in the engine's parking view, until a host view attaches the tab.
    NSView* parkingView = BowEngineParkingView();
    CefWindowInfo windowInfo;
    windowInfo.SetAsChild((__bridge void*)parkingView,
                          CefRect(0, 0, parkingView.bounds.size.width, parkingView.bounds.size.height));
    windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    CefBrowserSettings settings;
    // Created asynchronously: a new persistent profile's context initializes on disk first, and CEF waits for it.
    // The browser arrives in OnAfterCreated and navigates only after that, so delegates set right after creating
    // the tab see its first navigation.
    if (!CefBrowserHost::CreateBrowser(windowInfo, _client, url.absoluteString.UTF8String, settings, nullptr,
                                       requestContext)) {
      BowEngineBrowserCreationFailed(self);
      _closeReason = BowTabCloseReasonPage;
      _closed = YES;
      [self finishCloseCompletions:YES];
      [self reportClosed];
    }
  }
  return self;
}

- (instancetype)initWithProfileID:(NSString*)profileID downloadHandler:(CefRefPtr<CefDownloadHandler>)downloadHandler {
  self = [super init];
  if (self) {
    _tabID = gNextTabID++;
    _profileID = [profileID copy];
    _closeCompletions = [NSMutableArray array];
    _state = [[BowTabState alloc] initWithTabID:_tabID
                                            url:nil
                                          title:@""
                                     faviconURL:nil
                                        loading:NO
                                      canGoBack:NO
                                   canGoForward:NO
                                        audible:NO
                                 capturingVideo:NO
                                 capturingAudio:NO];
    _client = new BowTabClient(self, downloadHandler);
    BowEngineBrowserCreationStarted(self);
  }
  return self;
}

- (void)popupCreationFailed {
  if (self.closed || _browser) return;
  BowEngineBrowserCreationFailed(self);
  _closeReason = BowTabCloseReasonPage;
  self.closed = YES;
  [self finishCloseCompletions:YES];
  [self reportClosed];
}

- (CefRefPtr<CefBrowser>)browser {
  return _browser;
}

- (NSView*)browserView {
  if (!_browser || self.willClose) return nil;
  return (__bridge NSView*)_browser->GetHost()->GetWindowHandle();
}

- (void)browserCreated:(CefRefPtr<CefBrowser>)browser {
  if (self.closed) {
    // A popup browser CEF created after the tab had given up on it (its opener closed first) has no owner left:
    // close it, still parked and never shown, without running its beforeunload (nobody could answer a prompt for
    // it). Not from inside OnAfterCreated.
    dispatch_async(dispatch_get_main_queue(), ^{
      browser->GetHost()->CloseBrowser(true);
    });
    return;
  }
  _browser = browser;
  // Size Chromium's view without keeping a reference to it: its lifetime decides the browser's.
  NSView* browserView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
  browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  // A host view may have attached the tab while the browser was being created. A tab opened in the background
  // stays parked, hidden from the start, and so does one whose host view is in no window yet until that window
  // shows it. A tab about to close skips this.
  NSView* hostView = self.hostView;
  if (!hostView.window && !_closeWhenCreated) BowEngineParkNewBrowserView(browserView);
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
  // The ownerless popup browser browserCreated: closes: the tab reported its close, and its reason, already.
  if (self.closed) return;
  _willClose = YES;
  if (_unloading && BowEngineIsQuitting()) {
    // A quit that began while an unload was pending (the quit's own close request was absorbed by it, and the page
    // did not prompt) closes the page: the tab reports a close by quitting, and the unload answers NO.
    _unloading = NO;
    [self finishCloseCompletions:NO];
  }
  if (_unloading) return;
  // A close the app asked for stays the app's even if the page also called window.close() or a quit began.
  if (_closeCompletions.count > 0) {
    _closeReason = BowTabCloseReasonApp;
  } else {
    _closeReason = BowEngineIsQuitting() ? BowTabCloseReasonQuit : BowTabCloseReasonPage;
  }
}

- (void)browserClosed {
  // The ownerless popup browser browserCreated: closed: the tab reported its close already.
  if (self.closed) return;
  _browser = nullptr;
  [self failNavigation:ERR_ABORTED text:kBowAbortedText];
  self.closed = YES;
  [self finishCloseCompletions:YES];
  [self reportClosed];
}

// Reports on a later main thread task, so the app never reacts to a close from inside a CEF callback.
- (void)reportClosed {
  __weak BowTab* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    BowTab* tab = weakSelf;
    id<BowTabUIDelegate> delegate = tab.uiDelegate;
    if (tab && tab->_unloading) {
      if ([delegate respondsToSelector:@selector(tabDidUnload:)]) [delegate tabDidUnload:tab];
    } else if ([delegate respondsToSelector:@selector(tabDidClose:)]) {
      [delegate tabDidClose:tab];
    }
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
                                     canGoForward:canGoForward
                                          audible:old.audible
                                   capturingVideo:old.capturingVideo
                                   capturingAudio:old.capturingAudio];
  id<BowTabUIDelegate> delegate = self.uiDelegate;
  if ([delegate respondsToSelector:@selector(tab:didChangeState:)]) [delegate tab:self didChangeState:self.state];
}

#pragma mark UI requests

// Requests that need an answer reach the UI delegate on a later main thread task, never inside the engine
// callback, so the app can show modal UI or open tabs safely (the popup decision and the popup tab hand-off are
// the exceptions: both are answered at once, inside OnBeforePopup). Whether the tab takes a request (instead of the
// engine's default) is decided when it arrives. If the delegate is gone by the time it would be asked, the request
// answers as cancel, except a beforeunload question, which the tab then asks itself.

- (void)fullscreenChanged:(BOOL)isFullscreen {
  id<BowTabUIDelegate> delegate = self.uiDelegate;
  if ([delegate respondsToSelector:@selector(tab:fullscreenDidChange:)]) {
    [delegate tab:self fullscreenDidChange:isFullscreen];
  }
}

- (BOOL)takesUIRequest:(SEL)selector {
  return [self.uiDelegate respondsToSelector:selector];
}

// Asks the UI delegate on a later main thread task, if the tab is still open and its delegate still takes
// `selector`; otherwise runs `otherwise`, when given. A completion handler `ask` passes along that never gets
// called answers as cancel once released.
- (void)askUIDelegateLater:(SEL)selector
                       ask:(void (^)(BowTab* tab, id<BowTabUIDelegate> delegate))ask
                 otherwise:(nullable dispatch_block_t)otherwise {
  __weak BowTab* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    BowTab* tab = weakSelf;
    id<BowTabUIDelegate> delegate = tab.uiDelegate;
    if (tab && !tab.closed && [delegate respondsToSelector:selector]) {
      ask(tab, delegate);
    } else if (otherwise) {
      otherwise();
    }
  });
}

#pragma mark Find in page

- (void)findText:(NSString*)text forward:(BOOL)forward matchCase:(BOOL)matchCase {
  if (!_browser) return;
  if (text.length == 0) {
    [self stopFind];
    return;
  }
  if (!_findText || ![text isEqualToString:_findText] || matchCase != _findMatchCase) {
    // A new search: nothing counted yet.
    _findMatchCount = 0;
    _findActiveMatch = 0;
  }
  _findText = [text copy];
  _findMatchCase = matchCase;
  // Always a follow-up: Chromium restarts the search itself when the text or case changed, and a first request
  // (findNext false) only highlights, selecting no active match.
  _browser->GetHost()->Find(text.UTF8String, forward, matchCase, true);
}

- (void)stopFind {
  if (!_browser || !_findText) return;
  _findText = nil;
  _findStoppedIdentifier = _findIdentifier;
  // Keeping the selection makes the active match the page's selection, as Escape does in other browsers.
  _browser->GetHost()->StopFinding(false);
}

#pragma mark Commands

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
  if (!_browser) return;
  if (_navigation) _stopRequested = YES;
  _browser->StopLoad();
}

- (void)mediaCaptureChangedVideo:(BOOL)video audio:(BOOL)audio {
  BowTabState* old = self.state;
  if (old.capturingVideo == video && old.capturingAudio == audio) return;
  self.state = [[BowTabState alloc] initWithTabID:_tabID
                                              url:old.url
                                            title:old.title
                                       faviconURL:old.faviconURL
                                          loading:old.loading
                                        canGoBack:old.canGoBack
                                     canGoForward:old.canGoForward
                                          audible:old.audible
                                   capturingVideo:video
                                   capturingAudio:audio];
  id<BowTabUIDelegate> delegate = self.uiDelegate;
  if ([delegate respondsToSelector:@selector(tab:didChangeState:)]) [delegate tab:self didChangeState:self.state];
}

- (double)zoomLevel {
  return _browser && !self.willClose ? _browser->GetHost()->GetZoomLevel() : 0;
}

- (void)setZoomLevel:(double)zoomLevel {
  if (_browser && !self.willClose) _browser->GetHost()->SetZoomLevel(zoomLevel);
}

- (void)unloadWithCompletion:(void (^)(BOOL))completion {
  // A tab closing for good (the page called window.close(), or the engine quits) is never unloaded instead.
  if (self.closed || self.willClose || BowEngineIsQuitting()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(NO);
    });
    return;
  }
  // A close already pending stays a close: the unload does not take it over.
  if (_closeCompletions.count > 0 && !_unloading) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(NO);
    });
    return;
  }
  _unloading = YES;
  [_closeCompletions addObject:[completion copy]];
  if (!_browser) {
    _closeWhenCreated = YES;
    return;
  }
  BowEngineCloseBrowser(_browser, true);
}

- (void)closeWithCompletion:(void (^)(BOOL))completion {
  if (self.closed) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(YES);
    });
    return;
  }
  // A close asked for while an unload is pending wins: the unload answers NO (the tab reports a close, not an
  // unload), and the page may prompt. Past DoClose the unload is done but for the teardown, so it stands and the
  // close just waits for it (answering YES).
  if (_unloading && !_willClose) {
    _unloading = NO;
    [self finishCloseCompletions:NO];
  }
  [_closeCompletions addObject:[completion copy]];
  if (!_browser) {
    _closeWhenCreated = YES;
    return;
  }
  // Each close request asks the page again, as quitting again does.
  BowEngineCloseBrowser(_browser, true);
}

- (void)loadFaviconAtURL:(NSURL*)url
            maxPixelSize:(NSUInteger)maxPixelSize
              completion:(void (^)(NSImage* _Nullable))completion {
  if (!_browser || self.willClose || self.closed) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(nil);
    });
    return;
  }
  _browser->GetHost()->DownloadImage(url.absoluteString.UTF8String, true, static_cast<uint32_t>(maxPixelSize), false,
                                     new FaviconCallback(completion));
}

@end
