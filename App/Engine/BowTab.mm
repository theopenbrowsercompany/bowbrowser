#import "BowTab.h"

#import <AppKit/AppKit.h>

#include <atomic>
#include <set>

#include "BowEngine+Internal.h"
#if BOW_E2E
#include "BowE2EHooks.h"  // E2E seam
#endif
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_find_handler.h"
#include "include/cef_image.h"

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

#if BOW_E2E  // E2E seam: set by BowEngineAnswerLeavePrompts, so e2e runs answer leave prompts off screen.
std::function<void(uint64_t, bool, std::function<void(bool)>)> gLeavePromptAnswerer;
#endif

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

// The text of the ERR_ABORTED failures the tab reports itself, matching how the engine names its errors.
NSString* const kAbortedText = @"ERR_ABORTED";

// Runs `block` now when on the main thread, otherwise on the main queue. Delegates may answer from any thread.
void RunOnMain(dispatch_block_t block) {
  if (NSThread.isMainThread) {
    block();
  } else {
    dispatch_async(dispatch_get_main_queue(), block);
  }
}

BowNavigationTransition ToTransition(cef_transition_type_t type) {
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

BowPopupDisposition ToPopupDisposition(cef_window_open_disposition_t disposition) {
  switch (disposition) {
    case CEF_WOD_NEW_BACKGROUND_TAB:
      return BowPopupDispositionBackgroundTab;
    case CEF_WOD_NEW_POPUP:
    case CEF_WOD_NEW_PICTURE_IN_PICTURE:
      return BowPopupDispositionPopup;
    case CEF_WOD_NEW_WINDOW:
    case CEF_WOD_OFF_THE_RECORD:
      return BowPopupDispositionWindow;
    default:
      return BowPopupDispositionForegroundTab;
  }
}

BowProcessGoneReason ToProcessGoneReason(cef_termination_status_t status) {
  switch (status) {
    case TS_ABNORMAL_TERMINATION:
    case TS_PROCESS_CRASHED:
      return BowProcessGoneReasonCrashed;
    case TS_PROCESS_WAS_KILLED:
      return BowProcessGoneReasonKilled;
    case TS_PROCESS_OOM:
      return BowProcessGoneReasonOutOfMemory;
    case TS_LAUNCH_FAILED:
      return BowProcessGoneReasonLaunchFailed;
    default:
      return BowProcessGoneReasonOther;
  }
}

BowPermissionKind MediaPermissionKinds(uint32_t permissions) {
  BowPermissionKind kinds = 0;
  if (permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) kinds |= BowPermissionKindCamera;
  if (permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) kinds |= BowPermissionKindMicrophone;
  if (permissions & (CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE)) {
    kinds |= BowPermissionKindScreenCapture;
  }
  return kinds ?: BowPermissionKindOther;
}

BowPermissionKind PromptPermissionKinds(uint32_t permissions) {
  const struct {
    uint32_t cef;
    BowPermissionKind kind;
  } known[] = {
      {CEF_PERMISSION_TYPE_CAMERA_STREAM, BowPermissionKindCamera},
      {CEF_PERMISSION_TYPE_MIC_STREAM, BowPermissionKindMicrophone},
      {CEF_PERMISSION_TYPE_GEOLOCATION, BowPermissionKindGeolocation},
      {CEF_PERMISSION_TYPE_NOTIFICATIONS, BowPermissionKindNotifications},
      {CEF_PERMISSION_TYPE_CLIPBOARD, BowPermissionKindClipboard},
      {CEF_PERMISSION_TYPE_MIDI_SYSEX, BowPermissionKindMIDISysex},
      {CEF_PERMISSION_TYPE_STORAGE_ACCESS, BowPermissionKindStorageAccess},
      {CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, BowPermissionKindStorageAccess},
      {CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, BowPermissionKindWindowManagement},
      {CEF_PERMISSION_TYPE_LOCAL_FONTS, BowPermissionKindLocalFonts},
  };
  BowPermissionKind kinds = 0;
  uint32_t unknown = permissions;
  for (const auto& entry : known) {
    if (permissions & entry.cef) kinds |= entry.kind;
    unknown &= ~entry.cef;
  }
  if (unknown || !kinds) kinds |= BowPermissionKindOther;
  return kinds;
}

// A menu label without its keyboard mnemonic markers: "&Back" reads "Back", and "&&" is a literal ampersand.
NSString* MenuTitle(const CefString& label) {
  std::u16string text = label.ToString16();
  std::u16string plain;
  plain.reserve(text.size());
  for (size_t i = 0; i < text.size(); i++) {
    if (text[i] != u'&') {
      plain += text[i];
    } else if (i + 1 < text.size() && text[i + 1] == u'&') {
      plain += u'&';
      i++;
    }
  }
  return [NSString stringWithCharacters:reinterpret_cast<const unichar*>(plain.data()) length:plain.size()];
}

NSArray<BowContextMenuItem*>* MenuItems(CefRefPtr<CefMenuModel> model) {
  NSMutableArray<BowContextMenuItem*>* items = [NSMutableArray array];
  if (!model) return items;
  for (size_t i = 0; i < model->GetCount(); i++) {
    if (!model->IsVisibleAt(i)) continue;
    const cef_menu_item_type_t type = model->GetTypeAt(i);
    NSArray<BowContextMenuItem*>* submenu = type == MENUITEMTYPE_SUBMENU ? MenuItems(model->GetSubMenuAt(i)) : @[];
    [items addObject:[[BowContextMenuItem alloc] initWithCommandID:model->GetCommandIdAt(i)
                                                             title:MenuTitle(model->GetLabelAt(i))
                                                         isEnabled:model->IsEnabledAt(i)
                                                         isChecked:model->IsCheckedAt(i)
                                                       isSeparator:type == MENUITEMTYPE_SEPARATOR
                                                           submenu:submenu]];
  }
  return items;
}

}  // namespace

#pragma mark - BowAnswerOnce

// Keeps a delegate's completion handler to one answer. The handler block holds it; when the block is released
// without having answered, the fallback (the cancel answer) runs on a later main thread task.
@interface BowAnswerOnce : NSObject
- (instancetype)initWithFallback:(dispatch_block_t)fallback;
/// YES the first time, NO after that.
- (BOOL)claim;
@end

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

#pragma mark - BowFindResult

@interface BowFindResult ()
- (instancetype)initWithMatchCount:(NSInteger)matchCount
                       activeMatch:(NSInteger)activeMatch
                       finalUpdate:(BOOL)finalUpdate NS_DESIGNATED_INITIALIZER;
@end

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

class BowTabClient;

@interface BowTab () {
  CefRefPtr<BowTabClient> _client;
  CefRefPtr<CefBrowser> _browser;
  // Completions of closeWithCompletion: calls waiting for the page to close or to stay.
  NSMutableArray<void (^)(BOOL)>* _closeCompletions;
  // A close or a load asked for before the browser existed, done once it does.
  BOOL _closeWhenCreated;
  NSURL* _loadWhenCreated;
  // The main frame navigation in progress: started and not yet finished, failed or replaced. Nil otherwise.
  BowNavigation* _navigation;
  BOOL _navigationCommitted;
  // YES once the app stopped the navigation in progress.
  BOOL _stopRequested;
  // The text and case of the search in progress; nil while not finding, so late results of a stopped search drop.
  NSString* _findText;
  BOOL _findMatchCase;
  // The highest request identifier the engine has reported (each find request gets a higher one), so results of
  // older requests drop, and the highest one when finding last stopped, so its late results drop too.
  int _findIdentifier;
  int _findStoppedIdentifier;
  // What the search has reported so far, since each report carries only what changed.
  int _findMatchCount;
  int _findActiveMatch;
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
- (BOOL)navigationWillStart:(NSURL*)url
                 transition:(BowNavigationTransition)transition
              isUserGesture:(BOOL)isUserGesture
                 isRedirect:(BOOL)isRedirect;
- (void)navigationCommitted:(NSURL*)url transition:(BowNavigationTransition)transition;
- (void)navigationFinished:(NSInteger)httpStatusCode;
- (void)navigationFailed:(NSInteger)errorCode text:(NSString*)errorText url:(nullable NSURL*)url;
- (void)loadingStopped;
- (void)fullscreenChanged:(BOOL)isFullscreen;
/// YES when the UI delegate takes the request `selector` asks for, so the engine's default must not run. Asked
/// before building the request, so requests nobody takes cost nothing.
- (BOOL)takesUIRequest:(SEL)selector;
- (void)requestPopup:(BowPopupRequest*)request;
- (void)runJavaScriptDialog:(BowJSDialogRequest*)request callback:(CefRefPtr<CefJSDialogCallback>)callback;
- (void)runBeforeUnloadDialog:(BowJSDialogRequest*)request callback:(CefRefPtr<CefJSDialogCallback>)callback;
- (void)requestPermission:(BowPermissionRequest*)request answer:(void (^)(BowPermissionDecision))answer;
- (void)runContextMenu:(BowContextMenuRequest*)request callback:(CefRefPtr<CefRunContextMenuCallback>)callback;
- (void)renderProcessTerminated:(BowProcessGoneReason)reason;
- (void)findResultForSearch:(int)identifier
                      count:(int)count
                activeMatch:(int)activeMatch
                finalUpdate:(BOOL)finalUpdate;
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

BowContextMenuMediaType ToMediaType(cef_context_menu_media_type_t type) {
  switch (type) {
    case CM_MEDIATYPE_IMAGE:
      return BowContextMenuMediaTypeImage;
    case CM_MEDIATYPE_VIDEO:
      return BowContextMenuMediaTypeVideo;
    case CM_MEDIATYPE_AUDIO:
      return BowContextMenuMediaTypeAudio;
    case CM_MEDIATYPE_CANVAS:
      return BowContextMenuMediaTypeCanvas;
    case CM_MEDIATYPE_FILE:
      return BowContextMenuMediaTypeFile;
    case CM_MEDIATYPE_PLUGIN:
      return BowContextMenuMediaTypePlugin;
    default:
      return BowContextMenuMediaTypeNone;
  }
}

BowContextMenuTarget ToMenuTargets(int flags) {
  BowContextMenuTarget targets = 0;
  if (flags & CM_TYPEFLAG_PAGE) targets |= BowContextMenuTargetPage;
  if (flags & CM_TYPEFLAG_FRAME) targets |= BowContextMenuTargetFrame;
  if (flags & CM_TYPEFLAG_LINK) targets |= BowContextMenuTargetLink;
  if (flags & CM_TYPEFLAG_MEDIA) targets |= BowContextMenuTargetMedia;
  if (flags & CM_TYPEFLAG_SELECTION) targets |= BowContextMenuTargetSelection;
  if (flags & CM_TYPEFLAG_EDITABLE) targets |= BowContextMenuTargetEditable;
  return targets;
}

}  // namespace

// Receives Chromium's callbacks for one tab's browser and forwards them to the tab, which turns them into delegate
// calls. Every callback runs on the main thread because the app uses CefRunMessageLoop.
//
// Popups the page opens (always in CEF's own windows, see OnBeforePopup) share this client but live in windows CEF
// creates and closes itself. The engine tracks them so quitting waits for them; the tab only follows its own
// browser, and popups keep CEF's default behavior for everything else.
class BowTabClient : public CefClient,
                     public CefLifeSpanHandler,
                     public CefLoadHandler,
                     public CefDisplayHandler,
                     public CefJSDialogHandler,
                     public CefRequestHandler,
                     public CefPermissionHandler,
                     public CefContextMenuHandler,
                     public CefFindHandler {
 public:
  explicit BowTabClient(BowTab* tab) : tab_(tab) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }

  // CefLifeSpanHandler

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popupID,
                     const CefString& targetURL,
                     const CefString& targetFrameName,
                     WindowOpenDisposition targetDisposition,
                     bool userGesture,
                     const CefPopupFeatures& popupFeatures,
                     CefWindowInfo& windowInfo,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extraInfo,
                     bool* noJavaScriptAccess) override {
    // The engine always opens the page itself, in a popup window of its own, so the new page keeps its
    // window.opener (sign in popups report back through it). Here a link to a new tab, a page's window.open(url)
    // and a link with rel="opener" all look the same, so none can safely become a tab without that connection.
#if BOW_E2E  // E2E seam: e2e runs keep popups (and their own popups) in the parking view, so none shows on screen.
    if (BowEngineParksPopups()) {
      NSView* parkingView = BowEngineParkingView();
      windowInfo.SetAsChild((__bridge void*)parkingView,
                            CefRect(0, 0, parkingView.bounds.size.width, parkingView.bounds.size.height));
    }
#endif
    // A popup's own popups are not the tab's. Saving a link (Alt+click) and ignored actions are not new pages.
    if (browser->IsPopup() || targetDisposition == CEF_WOD_SAVE_TO_DISK || targetDisposition == CEF_WOD_IGNORE_ACTION ||
        ![tab_ takesUIRequest:@selector(tab:didRequestPopup:)]) {
      return false;
    }
    BowPopupSize* size = nil;
    if (popupFeatures.widthSet && popupFeatures.heightSet) {
      size = [[BowPopupSize alloc] initWithWidth:popupFeatures.width height:popupFeatures.height];
    }
    BowPopupRequest* request = [[BowPopupRequest alloc] initWithTargetURL:ToNSURL(targetURL)
                                                              disposition:ToPopupDisposition(targetDisposition)
                                                            isUserGesture:userGesture
                                                            requestedSize:size];
    [tab_ requestPopup:request];
    return false;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    if (browser->IsPopup()) {
      // A popup created in no window (parked by an e2e run) cannot close through a window; DoClose needs to know.
      NSView* browserView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
      if (!browserView.window) windowlessPopups_.insert(browser->GetIdentifier());
      BowEngineBrowserCreated(browser, nil);
      return;
    }
    BowTab* tab = tab_;
    [tab browserCreated:browser];
    BowEngineBrowserCreated(browser, tab);
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    BowEngineBrowserWillClose(browser);
    if (browser->IsPopup()) {
      // Returning false makes CEF send performClose: to the browser's window, which suits a popup's own window.
      if (windowlessPopups_.erase(browser->GetIdentifier()) == 0) return false;
      // A popup in no window has no window to close: tear down its view as a tab does.
      TearDownBrowserView(browser);
      return true;
    }
    // A tab's browser is not tied to a window: tear down its own view instead.
    [tab_ browserWillClose];
    TearDownBrowserView(browser);
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (!browser->IsPopup()) [tab_ browserClosed];
    BowEngineBrowserClosed(browser);
  }

  // CefRequestHandler

  // Asked before every main frame navigation and every server redirect; returning true cancels it.
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool userGesture,
                      bool isRedirect) override {
    if (browser->IsPopup() || !frame->IsMain()) return false;
    NSURL* url = ToNSURL(request->GetURL());
    if (!url) return false;
    BOOL allowed = [tab_ navigationWillStart:url
                                  transition:ToTransition(request->GetTransitionType())
                               isUserGesture:userGesture
                                  isRedirect:isRedirect];
    return !allowed;
  }

  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int errorCode,
                                 const CefString& errorString) override {
    if (browser->IsPopup()) return;
    [tab_ renderProcessTerminated:ToProcessGoneReason(status)];
  }

  // CefDisplayHandler

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

  void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser, bool fullscreen) override {
    if (browser->IsPopup()) return;
    [tab_ fullscreenChanged:fullscreen];
  }

  // CefFindHandler

  void OnFindResult(CefRefPtr<CefBrowser> browser,
                    int identifier,
                    int count,
                    const CefRect& selectionRect,
                    int activeMatchOrdinal,
                    bool finalUpdate) override {
    if (browser->IsPopup()) return;
    [tab_ findResultForSearch:identifier count:count activeMatch:activeMatchOrdinal finalUpdate:finalUpdate];
  }

  // CefLoadHandler

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
    if (!isLoading) [tab_ loadingStopped];
  }

  // Called once a navigation has committed, before the new page starts loading. Chromium does not call it for
  // same document navigations or for the error page it shows after a failure.
  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType transitionType) override {
    if (browser->IsPopup() || !frame->IsMain()) return;
    NSURL* url = ToNSURL(frame->GetURL());
    if (url) [tab_ navigationCommitted:url transition:ToTransition(transitionType)];
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int httpStatusCode) override {
    if (browser->IsPopup() || !frame->IsMain()) return;
    [tab_ navigationFinished:httpStatusCode];
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override {
    if (browser->IsPopup() || !frame->IsMain()) return;
    [tab_ navigationFailed:errorCode text:ToNSString(errorText) url:ToNSURL(failedUrl)];
  }

  // CefJSDialogHandler

  bool OnJSDialog(CefRefPtr<CefBrowser> browser,
                  const CefString& originURL,
                  JSDialogType dialogType,
                  const CefString& messageText,
                  const CefString& defaultPromptText,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool& suppressMessage) override {
    if (browser->IsPopup() || ![tab_ takesUIRequest:@selector(tab:runJavaScriptDialog:completionHandler:)]) {
      return false;
    }
    BowJSDialogKind kind = BowJSDialogKindAlert;
    if (dialogType == JSDIALOGTYPE_CONFIRM) kind = BowJSDialogKindConfirm;
    if (dialogType == JSDIALOGTYPE_PROMPT) kind = BowJSDialogKindPrompt;
    BowJSDialogRequest* request = [[BowJSDialogRequest alloc] initWithKind:kind
                                                                 originURL:ToNSURL(originURL)
                                                                   message:ToNSString(messageText)
                                                         defaultPromptText:ToNSString(defaultPromptText)
                                                                  isReload:NO];
    [tab_ runJavaScriptDialog:request callback:callback];
    return true;
  }

  // The tab always answers "leave this page?" itself (through its UI delegate or its own prompt), so it knows
  // whether the person stayed and can report that a close was cancelled. Popups keep CEF's own prompt.
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                            const CefString& messageText,
                            bool isReload,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    if (browser->IsPopup()) return false;
    BowJSDialogRequest* request = [[BowJSDialogRequest alloc] initWithKind:BowJSDialogKindBeforeUnload
                                                                 originURL:nil
                                                                   message:ToNSString(messageText)
                                                         defaultPromptText:@""
                                                                  isReload:isReload];
    [tab_ runBeforeUnloadDialog:request callback:callback];
    return true;
  }

  // CefPermissionHandler

  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser,
                                      CefRefPtr<CefFrame> frame,
                                      const CefString& requestingOrigin,
                                      uint32_t requestedPermissions,
                                      CefRefPtr<CefMediaAccessCallback> callback) override {
    if (browser->IsPopup() || ![tab_ takesUIRequest:@selector(tab:requestPermission:decisionHandler:)]) return false;
    BowPermissionRequest* request =
        [[BowPermissionRequest alloc] initWithRequestingOrigin:ToNSURL(requestingOrigin)
                                                         kinds:MediaPermissionKinds(requestedPermissions)];
    [tab_ requestPermission:request
                     answer:^(BowPermissionDecision decision) {
                       if (decision == BowPermissionDecisionAllow) {
                         callback->Continue(requestedPermissions);
                       } else {
                         callback->Cancel();
                       }
                     }];
    return true;
  }

  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser,
                              uint64_t promptID,
                              const CefString& requestingOrigin,
                              uint32_t requestedPermissions,
                              CefRefPtr<CefPermissionPromptCallback> callback) override {
    if (browser->IsPopup() || ![tab_ takesUIRequest:@selector(tab:requestPermission:decisionHandler:)]) return false;
    BowPermissionRequest* request =
        [[BowPermissionRequest alloc] initWithRequestingOrigin:ToNSURL(requestingOrigin)
                                                         kinds:PromptPermissionKinds(requestedPermissions)];
    [tab_ requestPermission:request
                     answer:^(BowPermissionDecision decision) {
                       cef_permission_request_result_t result = CEF_PERMISSION_RESULT_DISMISS;
                       if (decision == BowPermissionDecisionAllow) result = CEF_PERMISSION_RESULT_ACCEPT;
                       if (decision == BowPermissionDecisionDeny) result = CEF_PERMISSION_RESULT_DENY;
                       callback->Continue(result);
                     }];
    return true;
  }

  // CefContextMenuHandler

  bool RunContextMenu(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefContextMenuParams> params,
                      CefRefPtr<CefMenuModel> model,
                      CefRefPtr<CefRunContextMenuCallback> callback) override {
    if (browser->IsPopup() || ![tab_ takesUIRequest:@selector(tab:runContextMenu:completionHandler:)]) return false;
    // The params and model are valid only during this call, so everything is copied out now.
    BowContextMenuRequest* request =
        [[BowContextMenuRequest alloc] initWithLocation:CGPointMake(params->GetXCoord(), params->GetYCoord())
                                                targets:ToMenuTargets(params->GetTypeFlags())
                                              mediaType:ToMediaType(params->GetMediaType())
                                                pageURL:ToNSURL(params->GetPageUrl())
                                               frameURL:ToNSURL(params->GetFrameUrl())
                                                linkURL:ToNSURL(params->GetLinkUrl())
                                              sourceURL:ToNSURL(params->GetSourceUrl())
                                          selectionText:ToNSString(params->GetSelectionText())
                                           defaultItems:MenuItems(model)];
    [tab_ runContextMenu:request callback:callback];
    return true;
  }

 private:
  __weak BowTab* tab_;
  // Identifiers of this tab's popups that were created in no window.
  std::set<int> windowlessPopups_;

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
    // The browser arrives in OnAfterCreated and navigates only after that, so delegates set right after creating
    // the tab see its first navigation.
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
  _willClose = YES;
}

- (void)browserClosed {
  _browser = nullptr;
  [self failNavigation:ERR_ABORTED text:kAbortedText];
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
    if ([delegate respondsToSelector:@selector(tabDidClose:)]) [delegate tabDidClose:tab];
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
  id<BowTabUIDelegate> delegate = self.uiDelegate;
  if ([delegate respondsToSelector:@selector(tab:didChangeState:)]) [delegate tab:self didChangeState:self.state];
}

#pragma mark Navigation

// Navigation events are delivered inside the engine callback that produced them, so they arrive in the engine's
// order. Each belongs to the navigation in progress: start opens it, redirects and the commit move it on, and
// finish or fail ends it. An engine callback that belongs to no navigation in progress (the load end of the error
// page Chromium shows after a failure, or the abort of a navigation the policy cancelled) is not reported.
//
// Every start gets an end. A navigation that is replaced, stopped, cancelled at a redirect, cut short by the tab
// closing or its render process exiting, or that ends without a page (a 204 response or a download) fails with
// ERR_ABORTED. Chromium reports the abort of a replaced navigation before the replacing one starts. A committed
// navigation that gets no load end (a page restored from the back/forward cache) finishes once loading stops.

- (BOOL)navigationWillStart:(NSURL*)url
                 transition:(BowNavigationTransition)transition
              isUserGesture:(BOOL)isUserGesture
                 isRedirect:(BOOL)isRedirect {
  BowNavigation* navigation = [[BowNavigation alloc] initWithURL:url
                                                      transition:transition
                                                   isUserGesture:isUserGesture];
  id<BowTabNavigationDelegate> policyDelegate = self.navigationDelegate;
  if ([policyDelegate respondsToSelector:@selector(tab:decidePolicyForNavigation:)] &&
      [policyDelegate tab:self decidePolicyForNavigation:navigation] == BowNavigationPolicyCancel) {
    // A cancelled new navigation was never reported. A cancelled redirect ends the navigation it belongs to, which
    // was.
    if (isRedirect && _navigation) [self failNavigation:ERR_ABORTED text:kAbortedText];
    return NO;
  }
  if (isRedirect && _navigation) {
    _navigation = navigation;
    id<BowTabNavigationDelegate> delegate = self.navigationDelegate;
    if ([delegate respondsToSelector:@selector(tab:didRedirectNavigation:)]) {
      [delegate tab:self didRedirectNavigation:navigation];
    }
    return YES;
  }
  // A new navigation replaces any in progress. An uncommitted one has normally ended already with its own abort;
  // one still open (a committed page that had not finished loading) fails now.
  if (_navigation) [self failNavigation:ERR_ABORTED text:kAbortedText];
  [self beginNavigation:navigation];
  return YES;
}

// Opens `navigation` and reports its start.
- (void)beginNavigation:(BowNavigation*)navigation {
  _navigation = navigation;
  _navigationCommitted = NO;
  _stopRequested = NO;
  id<BowTabNavigationDelegate> delegate = self.navigationDelegate;
  if ([delegate respondsToSelector:@selector(tab:didStartNavigation:)]) {
    [delegate tab:self didStartNavigation:navigation];
  }
}

- (void)navigationCommitted:(NSURL*)url transition:(BowNavigationTransition)transition {
  // A commit the policy was not asked about (a page restored from the back/forward cache) is a navigation of its
  // own: end a committed one still open, and report its start first, keeping the order.
  if (_navigation && _navigationCommitted) [self failNavigation:ERR_ABORTED text:kAbortedText];
  if (!_navigation) {
    [self beginNavigation:[[BowNavigation alloc] initWithURL:url transition:transition isUserGesture:NO]];
  }
  _navigation = [[BowNavigation alloc] initWithURL:url
                                        transition:_navigation.transition
                                     isUserGesture:_navigation.isUserGesture];
  _navigationCommitted = YES;
  id<BowTabNavigationDelegate> delegate = self.navigationDelegate;
  if ([delegate respondsToSelector:@selector(tab:didCommitNavigation:)]) {
    [delegate tab:self didCommitNavigation:_navigation];
  }
}

- (void)navigationFinished:(NSInteger)httpStatusCode {
  if (!_navigation || !_navigationCommitted) return;
  BowNavigation* navigation = _navigation;
  _navigation = nil;
  id<BowTabNavigationDelegate> delegate = self.navigationDelegate;
  if ([delegate respondsToSelector:@selector(tab:didFinishNavigation:httpStatusCode:)]) {
    [delegate tab:self didFinishNavigation:navigation httpStatusCode:httpStatusCode];
  }
}

- (void)navigationFailed:(NSInteger)errorCode text:(NSString*)errorText url:(NSURL*)url {
  if (!_navigation) return;
  // An abort ends the navigation in progress only when it is that navigation's: the abort of a navigation the
  // policy cancelled (never reported) or of an older one is not.
  if (errorCode == ERR_ABORTED && (_navigationCommitted || ![_navigation.url isEqual:url])) return;
  [self failNavigation:errorCode text:errorText];
}

// Ends the navigation in progress, if any, with a failure.
- (void)failNavigation:(NSInteger)errorCode text:(NSString*)errorText {
  BowNavigation* navigation = _navigation;
  if (!navigation) return;
  _navigation = nil;
  id<BowTabNavigationDelegate> delegate = self.navigationDelegate;
  if ([delegate respondsToSelector:@selector(tab:didFailNavigation:error:)]) {
    [delegate tab:self
        didFailNavigation:navigation
                    error:[[BowNavigationError alloc] initWithCode:errorCode errorText:errorText]];
  }
}

// Loading stopped. A committed navigation still open fails as aborted when the app stopped it; otherwise (a page
// restored from the back/forward cache gets no load end) it finishes, with status 0. Either way on a later main
// thread task, after any load end that comes with the same stop.
- (void)loadingStopped {
  BowNavigation* navigation = _navigation;
  if (!navigation || !_navigationCommitted) return;
  __weak BowTab* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    BowTab* tab = weakSelf;
    if (!tab || tab->_navigation != navigation) return;
    if (tab->_stopRequested) {
      [tab failNavigation:ERR_ABORTED text:kAbortedText];
    } else {
      [tab navigationFinished:0];
    }
  });
}

#pragma mark UI requests

// Requests that need an answer reach the UI delegate on a later main thread task, never inside the engine
// callback, so the app can show modal UI or open tabs safely. Whether the tab takes a request (instead of the
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

// Tells the delegate about a popup the engine is opening, even when the tab has closed since.
- (void)requestPopup:(BowPopupRequest*)request {
  __weak BowTab* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    BowTab* tab = weakSelf;
    id<BowTabUIDelegate> delegate = tab.uiDelegate;
    if ([delegate respondsToSelector:@selector(tab:didRequestPopup:)]) [delegate tab:tab didRequestPopup:request];
  });
}

- (void)runJavaScriptDialog:(BowJSDialogRequest*)request callback:(CefRefPtr<CefJSDialogCallback>)callback {
  void (^answer)(BOOL, NSString*) = ^(BOOL accepted, NSString* userInput) {
    callback->Continue(accepted, userInput.UTF8String ?: "");
  };
  [self askDelegateForDialog:request
                      answer:answer
                   otherwise:^{
                     answer(NO, nil);
                   }];
}

- (void)runBeforeUnloadDialog:(BowJSDialogRequest*)request callback:(CefRefPtr<CefJSDialogCallback>)callback {
  CefRefPtr<CefBrowser> browser = _browser;
  const BOOL isReload = request.isReload;
  __weak BowTab* weakSelf = self;
  void (^answer)(BOOL, NSString*) = ^(BOOL leave, NSString*) {
    callback->Continue(leave, CefString());
    // Staying on a reload prompt keeps the page; it says nothing about a pending close.
    if (!leave && !isReload && browser && BowEngineBrowserCloseCancelled(browser)) {
      [weakSelf finishCloseCompletions:NO];
    }
  };
  if (![self takesUIRequest:@selector(tab:runJavaScriptDialog:completionHandler:)]) {
    [self runLeavePrompt:request answer:answer];
    return;
  }
  // A delegate gone before it is asked must not cancel a close or quit by default: the tab asks itself instead.
  [self askDelegateForDialog:request
                      answer:answer
                   otherwise:^{
                     BowTab* tab = weakSelf;
                     if (tab) {
                       [tab runLeavePrompt:request answer:answer];
                     } else {
                       answer(YES, nil);
                     }
                   }];
}

// Hands a dialog to the UI delegate. The handler answers once; released unanswered, it answers NO (cancel, or
// stay on the page).
- (void)askDelegateForDialog:(BowJSDialogRequest*)request
                      answer:(void (^)(BOOL, NSString* _Nullable))answer
                   otherwise:(dispatch_block_t)otherwise {
  [self askUIDelegateLater:@selector(tab:runJavaScriptDialog:completionHandler:)
                       ask:^(BowTab* tab, id<BowTabUIDelegate> delegate) {
                         BowAnswerOnce* once = [[BowAnswerOnce alloc] initWithFallback:^{
                           answer(NO, nil);
                         }];
                         [delegate tab:tab
                             runJavaScriptDialog:request
                               completionHandler:^(BOOL accepted, NSString* userInput) {
                                 if (![once claim]) return;
                                 NSString* input = [userInput copy];
                                 RunOnMain(^{
                                   answer(accepted, input);
                                 });
                               }];
                       }
                 otherwise:otherwise];
}

// The tab's own "leave this site?" prompt, used when the UI delegate takes no dialogs: a sheet on the window
// showing the tab, or a free-floating alert while the tab is detached.
- (void)runLeavePrompt:(BowJSDialogRequest*)request answer:(void (^)(BOOL, NSString* _Nullable))answer {
#if BOW_E2E  // E2E seam: an e2e run answers the prompt itself instead of showing it, outside the CEF callback.
  if (gLeavePromptAnswerer) {
    const uint64_t tabID = self.tabID;
    const bool isReload = request.isReload;
    // One answer only; released unanswered, it leaves, so a run never waits on a prompt nobody answers.
    BowAnswerOnce* once = [[BowAnswerOnce alloc] initWithFallback:^{
      answer(YES, nil);
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
      gLeavePromptAnswerer(tabID, isReload, [once, answer](bool leave) {
        if ([once claim]) answer(leave, nil);
      });
    });
    return;
  }
#endif
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = request.isReload ? @"Reload this site?" : @"Leave this site?";
  alert.informativeText = @"Changes you made may not be saved.";
  [alert addButtonWithTitle:request.isReload ? @"Reload" : @"Leave"];
  [alert addButtonWithTitle:@"Cancel"];
  NSWindow* window = self.hostView.window;
  if (window) {
    [alert beginSheetModalForWindow:window
                  completionHandler:^(NSModalResponse response) {
                    answer(response == NSAlertFirstButtonReturn, nil);
                  }];
  } else {
    // A detached tab has no window to attach a sheet to. Ask outside the CEF callback.
    dispatch_async(dispatch_get_main_queue(), ^{
      answer([alert runModal] == NSAlertFirstButtonReturn, nil);
    });
  }
}

- (void)requestPermission:(BowPermissionRequest*)request answer:(void (^)(BowPermissionDecision))answer {
  [self askUIDelegateLater:@selector(tab:requestPermission:decisionHandler:)
      ask:^(BowTab* tab, id<BowTabUIDelegate> delegate) {
        BowAnswerOnce* once = [[BowAnswerOnce alloc] initWithFallback:^{
          answer(BowPermissionDecisionDismiss);
        }];
        [delegate tab:tab
            requestPermission:request
              decisionHandler:^(BowPermissionDecision decision) {
                if (![once claim]) return;
                RunOnMain(^{
                  answer(decision);
                });
              }];
      }
      otherwise:^{
        answer(BowPermissionDecisionDismiss);
      }];
}

- (void)runContextMenu:(BowContextMenuRequest*)request callback:(CefRefPtr<CefRunContextMenuCallback>)callback {
  void (^answer)(NSInteger) = ^(NSInteger commandID) {
    if (commandID == BowContextMenuNoCommand) {
      callback->Cancel();
    } else {
      callback->Continue(static_cast<int>(commandID), EVENTFLAG_NONE);
    }
  };
  [self askUIDelegateLater:@selector(tab:runContextMenu:completionHandler:)
      ask:^(BowTab* tab, id<BowTabUIDelegate> delegate) {
        BowAnswerOnce* once = [[BowAnswerOnce alloc] initWithFallback:^{
          answer(BowContextMenuNoCommand);
        }];
        [delegate tab:tab
               runContextMenu:request
            completionHandler:^(NSInteger commandID) {
              if (![once claim]) return;
              RunOnMain(^{
                answer(commandID);
              });
            }];
      }
      otherwise:^{
        answer(BowContextMenuNoCommand);
      }];
}

- (void)renderProcessTerminated:(BowProcessGoneReason)reason {
  // Whatever was loading is gone with the process.
  [self failNavigation:ERR_ABORTED text:kAbortedText];
  [self askUIDelegateLater:@selector(tab:renderProcessDidTerminate:)
                       ask:^(BowTab* tab, id<BowTabUIDelegate> delegate) {
                         [delegate tab:tab renderProcessDidTerminate:reason];
                       }
                 otherwise:nil];
}

#pragma mark Find in page

- (void)findResultForSearch:(int)identifier
                      count:(int)count
                activeMatch:(int)activeMatch
                finalUpdate:(BOOL)finalUpdate {
  if (!_findText || identifier < _findIdentifier || identifier <= _findStoppedIdentifier) return;
  _findIdentifier = identifier;
  // Each report carries only what changed: -1 means the count or the position is as last reported.
  if (count >= 0) _findMatchCount = count;
  if (activeMatch >= 0) _findActiveMatch = activeMatch;
  BowFindResult* result = [[BowFindResult alloc] initWithMatchCount:_findMatchCount
                                                        activeMatch:_findActiveMatch
                                                        finalUpdate:finalUpdate];
  id<BowTabUIDelegate> delegate = self.uiDelegate;
  if ([delegate respondsToSelector:@selector(tab:didUpdateFindResult:)]) {
    [delegate tab:self didUpdateFindResult:result];
  }
}

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

#if BOW_E2E  // E2E seam: the leave prompt hook declared in BowE2EHooks.h.
void BowEngineAnswerLeavePrompts(
    std::function<void(uint64_t tabID, bool isReload, std::function<void(bool leave)> answer)> answerer) {
  gLeavePromptAnswerer = std::move(answerer);
}
#endif
