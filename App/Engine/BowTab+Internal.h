// What a tab's Objective-C++ files share: the tab's private state and methods, and its CEF client, which
// implements each CEF handler in its own file (BowTabLifeSpan.mm, BowTabLoads.mm and so on) behind one client.
// C++: never import this from Swift.
#pragma once

#import <AppKit/AppKit.h>

#include <set>

#include "BowEngine+Internal.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_find_handler.h"
#include "include/cef_keyboard_handler.h"

NS_ASSUME_NONNULL_BEGIN

NSString* BowToNSString(const CefString& value);
NSURL* _Nullable BowToNSURL(const CefString& value);
/// Runs `block` now when on the main thread, otherwise on the main queue. Delegates may answer from any thread.
void BowRunOnMain(dispatch_block_t block);
/// Destroys a closing browser by removing Chromium's view, wherever it is (a host view or the parking view). In
/// windowed Alloy style on macOS the browser is destroyed only when that view is deallocated, and OnBeforeClose
/// follows. Runs as its own main thread task, never inside a CEF callback.
void BowTearDownBrowserView(CefRefPtr<CefBrowser> browser);
BowNavigationTransition BowToTransition(cef_transition_type_t type);

/// The text of the ERR_ABORTED failures the tab reports itself, matching how the engine names its errors.
extern NSString* const kBowAbortedText;

// Keeps a delegate's completion handler to one answer. The handler block holds it; when the block is released
// without having answered, the fallback (the cancel answer) runs on a later main thread task.
@interface BowAnswerOnce : NSObject
- (instancetype)initWithFallback:(dispatch_block_t)fallback;
/// YES the first time, NO after that.
- (BOOL)claim;
@end

class BowTabClient;

@interface BowTabState ()
- (instancetype)initWithTabID:(uint64_t)tabID
                          url:(nullable NSURL*)url
                        title:(NSString*)title
                   faviconURL:(nullable NSURL*)faviconURL
                      loading:(BOOL)loading
                    canGoBack:(BOOL)canGoBack
                 canGoForward:(BOOL)canGoForward
                      audible:(BOOL)audible
               capturingVideo:(BOOL)capturingVideo
               capturingAudio:(BOOL)capturingAudio NS_DESIGNATED_INITIALIZER;
@end

@interface BowFindResult ()
- (instancetype)initWithMatchCount:(NSInteger)matchCount
                       activeMatch:(NSInteger)activeMatch
                       finalUpdate:(BOOL)finalUpdate NS_DESIGNATED_INITIALIZER;
@end

@interface BowTab () {
 @package
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
  // The engine's identifier of the main frame the navigation in progress committed in, once committed. The engine
  // gives a frame a new identifier when a navigation commits in a new frame host, which this Chromium does for each
  // new document (the error page shown after a failure also runs in its own process), so a late load end of the page
  // it replaced is told apart from the committed page's own.
  NSString* _navigationFrame;
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
  // YES while an unload is pending: the page's leave prompt answers stay without showing, and a close reports
  // tabDidUnload: instead of tabDidClose:.
  BOOL _unloading;
}
/// A tab whose browser is created next with its client: by `initWithProfile:url:`, or by CEF for a popup the app
/// takes as a tab, in the opener's profile. The engine keeps it alive from now on; its browser arrives in
/// OnAfterCreated.
- (instancetype)initWithProfileID:(NSString*)profileID downloadHandler:(CefRefPtr<CefDownloadHandler>)downloadHandler;
/// CEF did not create the popup browser this tab was made for. Does nothing once it has a browser.
- (void)popupCreationFailed;
- (void)mediaCaptureChangedVideo:(BOOL)video audio:(BOOL)audio;
@property(nonatomic, readwrite) BowTabState* state;
@property(nonatomic, readwrite, getter=isClosed) BOOL closed;
- (void)browserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)browserWillClose;
- (void)browserClosed;
- (void)finishCloseCompletions:(BOOL)closed;
- (void)updateState:(void (^)(NSURL* _Nullable __strong* _Nonnull url,
                              NSString* _Nonnull __strong* _Nonnull title,
                              NSURL* _Nullable __strong* _Nonnull faviconURL,
                              BOOL* loading,
                              BOOL* canGoBack,
                              BOOL* canGoForward))change;
@end

// Implemented in the handler files, one category each.
@interface BowTab (Handlers)
- (BOOL)navigationWillStart:(NSURL*)url
                 transition:(BowNavigationTransition)transition
              isUserGesture:(BOOL)isUserGesture
                 isRedirect:(BOOL)isRedirect;
- (void)navigationCommitted:(NSURL*)url
                  transition:(BowNavigationTransition)transition
                       frame:(NSString*)frameIdentifier;
- (void)navigationFinished:(NSInteger)httpStatusCode frame:(NSString*)frameIdentifier;
- (void)navigationFailed:(NSInteger)errorCode text:(NSString*)errorText url:(nullable NSURL*)url;
- (void)failNavigation:(NSInteger)errorCode text:(NSString*)errorText;
- (void)loadingStopped;
- (void)fullscreenChanged:(BOOL)isFullscreen;
/// YES when the UI delegate takes the request `selector` asks for, so the engine's default must not run. Asked
/// before building the request, so requests nobody takes cost nothing.
- (BOOL)takesUIRequest:(SEL)selector;
/// Asks the UI delegate on a later main thread task, if the tab is still open and its delegate still takes
/// `selector`; otherwise runs `otherwise`, when given.
- (void)askUIDelegateLater:(SEL)selector
                       ask:(void (^)(BowTab* tab, id<BowTabUIDelegate> delegate))ask
                 otherwise:(nullable dispatch_block_t)otherwise;
- (void)requestPopup:(BowPopupRequest*)request;
/// The UI delegate's answer, asked synchronously; `BowPopupDecisionWindow` without one.
- (BowPopupDecision)decidePopup:(BowPopupRequest*)request;
/// Hands `newTab` to the UI delegate at once, before its browser exists, so it sees the popup's first navigation;
/// closes it when nobody takes it.
- (void)openPopupTab:(BowTab*)newTab request:(BowPopupRequest*)request;
- (BOOL)handleKeyBeforePage:(BowKeyEvent*)event;
- (void)answerAuthChallenge:(BowAuthChallenge*)challenge callback:(CefRefPtr<CefAuthCallback>)callback;
- (void)decideCertificateError:(BowCertificateError*)error callback:(CefRefPtr<CefCallback>)callback;
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

// Receives Chromium's callbacks for one tab's browser and forwards them to the tab, which turns them into delegate
// calls. Every callback runs on the main thread because the app uses CefRunMessageLoop. Each handler lives in its
// own file: life span and popups (BowTabLifeSpan.mm), loads (BowTabLoads.mm), display (BowTabDisplay.mm),
// JavaScript dialogs (BowTabDialogs.mm), requests (BowTabRequests.mm), permissions (BowTabPermissions.mm), context
// menus (BowTabContextMenu.mm), keys (BowTabKeyboard.mm), find (BowTabFind.mm) and downloads (BowTabDownloads.mm).
//
// Popups the engine opens in windows of its own (see OnBeforePopup) share this client but live in windows CEF
// creates and closes itself. The engine tracks them so quitting waits for them; the tab only follows its own
// browser (IsOwn), and popups keep CEF's default behavior for everything else. A popup the app takes as a tab gets
// a client of its own instead, so it is that tab's own browser.
class BowTabClient : public CefClient,
                     public CefLifeSpanHandler,
                     public CefLoadHandler,
                     public CefDisplayHandler,
                     public CefJSDialogHandler,
                     public CefRequestHandler,
                     public CefPermissionHandler,
                     public CefContextMenuHandler,
                     public CefFindHandler,
                     public CefKeyboardHandler {
 public:
  BowTabClient(BowTab* tab, CefRefPtr<CefDownloadHandler> downloadHandler)
      : tab_(tab), downloadHandler_(downloadHandler) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override;

  // CefLifeSpanHandler (BowTabLifeSpan.mm)
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
                     bool* noJavaScriptAccess) override;
  void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popupID) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

  // CefRequestHandler (BowTabRequests.mm)
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool userGesture,
                      bool isRedirect) override;
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int errorCode,
                                 const CefString& errorString) override;
  bool GetAuthCredentials(CefRefPtr<CefBrowser> browser,
                          const CefString& originURL,
                          bool isProxy,
                          const CefString& host,
                          int port,
                          const CefString& realm,
                          const CefString& scheme,
                          CefRefPtr<CefAuthCallback> callback) override;
  bool OnCertificateError(CefRefPtr<CefBrowser> browser,
                          cef_errorcode_t certError,
                          const CefString& requestURL,
                          CefRefPtr<CefSSLInfo> sslInfo,
                          CefRefPtr<CefCallback> callback) override;

  // CefDisplayHandler (BowTabDisplay.mm)
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override;
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& url) override;
  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& iconURLs) override;
  void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser, bool fullscreen) override;
  void OnMediaAccessChange(CefRefPtr<CefBrowser> browser, bool hasVideoAccess, bool hasAudioAccess) override;

  // CefFindHandler (BowTabFind.mm)
  void OnFindResult(CefRefPtr<CefBrowser> browser,
                    int identifier,
                    int count,
                    const CefRect& selectionRect,
                    int activeMatchOrdinal,
                    bool finalUpdate) override;

  // CefLoadHandler (BowTabLoads.mm)
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack, bool canGoForward) override;
  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType transitionType) override;
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int httpStatusCode) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override;

  // CefJSDialogHandler (BowTabDialogs.mm)
  bool OnJSDialog(CefRefPtr<CefBrowser> browser,
                  const CefString& originURL,
                  JSDialogType dialogType,
                  const CefString& messageText,
                  const CefString& defaultPromptText,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool& suppressMessage) override;
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                            const CefString& messageText,
                            bool isReload,
                            CefRefPtr<CefJSDialogCallback> callback) override;

  // CefPermissionHandler (BowTabPermissions.mm)
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser,
                                      CefRefPtr<CefFrame> frame,
                                      const CefString& requestingOrigin,
                                      uint32_t requestedPermissions,
                                      CefRefPtr<CefMediaAccessCallback> callback) override;
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser,
                              uint64_t promptID,
                              const CefString& requestingOrigin,
                              uint32_t requestedPermissions,
                              CefRefPtr<CefPermissionPromptCallback> callback) override;

  // CefKeyboardHandler (BowTabKeyboard.mm)
  bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                     const CefKeyEvent& event,
                     CefEventHandle osEvent,
                     bool* isKeyboardShortcut) override;

  // CefContextMenuHandler (BowTabContextMenu.mm)
  bool RunContextMenu(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefContextMenuParams> params,
                      CefRefPtr<CefMenuModel> model,
                      CefRefPtr<CefRunContextMenuCallback> callback) override;

  /// True for the tab's own browser: the first browser created with this client. Every other browser created with
  /// it is a popup the engine opened in a window of its own, which keeps CEF's defaults.
  bool IsOwn(CefRefPtr<CefBrowser> browser) const {
    return ownBrowserID_ != 0 && browser->GetIdentifier() == ownBrowserID_;
  }

  __weak BowTab* tab_;

 private:
  int ownBrowserID_ = 0;
  // The native key codes of key downs the app claimed, each until its key up.
  std::set<int> claimedKeyCodes_;
  // Tabs made for popups decided as tabs, by popup ID, until CEF creates their browser or gives up.
  NSMapTable<NSNumber*, BowTab*>* pendingPopupTabs_ = [NSMapTable strongToWeakObjectsMapTable];
  // For a popup tab's client: the opener's client and the popup's ID there, until the popup browser is created.
  CefRefPtr<BowTabClient> openerClient_;
  int openerPopupID_ = 0;
  CefRefPtr<CefDownloadHandler> downloadHandler_;
  // Identifiers of this tab's popups that were created in no window.
  std::set<int> windowlessPopups_;

  IMPLEMENT_REFCOUNTING(BowTabClient);
};

NS_ASSUME_NONNULL_END
