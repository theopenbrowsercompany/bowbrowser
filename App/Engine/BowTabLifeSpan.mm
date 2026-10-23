// The tab's CefLifeSpanHandler: popups the page opens, and the browser's creation and close.
#import "BowTab+Internal.h"

#if BOW_E2E
#include "BowE2EHooks.h"  // E2E seam
#endif

namespace {

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

}  // namespace

bool BowTabClient::OnBeforePopup(CefRefPtr<CefBrowser> browser,
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
                                 bool* noJavaScriptAccess) {
  // Either way the new page is created here, by CEF, so it keeps its window.opener (sign in popups report back
  // through it): in a window of the engine's own by default, or as a new tab when the app asks for one.
#if BOW_E2E  // E2E seam: e2e runs keep popups (and their own popups) in the parking view, so none shows on screen.
  if (BowEngineParksPopups()) {
    NSView* parkingView = BowEngineParkingView();
    windowInfo.SetAsChild((__bridge void*)parkingView,
                          CefRect(0, 0, parkingView.bounds.size.width, parkingView.bounds.size.height));
  }
#endif
  // Popups opened by the engine's own popup windows are not the tab's. Saving a link (Alt+click) and ignored
  // actions are not new pages.
  BowTab* tab = tab_;
  const BOOL decides = [tab takesUIRequest:@selector(tab:decidePopup:)];
  if (!IsOwn(browser) || targetDisposition == CEF_WOD_SAVE_TO_DISK || targetDisposition == CEF_WOD_IGNORE_ACTION ||
      (!decides && ![tab takesUIRequest:@selector(tab:didRequestPopup:)])) {
    return false;
  }
  BowPopupSize* size = nil;
  if (popupFeatures.widthSet && popupFeatures.heightSet) {
    size = [[BowPopupSize alloc] initWithWidth:popupFeatures.width height:popupFeatures.height];
  }
  BowPopupWindowFeatures* features =
      [[BowPopupWindowFeatures alloc] initWithX:popupFeatures.xSet ? @(popupFeatures.x) : nil
                                              y:popupFeatures.ySet ? @(popupFeatures.y) : nil
                                          width:popupFeatures.widthSet ? @(popupFeatures.width) : nil
                                         height:popupFeatures.heightSet ? @(popupFeatures.height) : nil
                                        isPopup:popupFeatures.isPopup];
  BowPopupRequest* request = [[BowPopupRequest alloc] initWithTargetURL:BowToNSURL(targetURL)
                                                            disposition:ToPopupDisposition(targetDisposition)
                                                          isUserGesture:userGesture
                                                          requestedSize:size
                                                         windowFeatures:features];
  const BowPopupDecision decision = decides ? [tab decidePopup:request] : BowPopupDecisionWindow;
  switch (decision) {
    case BowPopupDecisionBlock:
      return true;
    case BowPopupDecisionWindow:
      [tab requestPopup:request];
      return false;
    case BowPopupDecisionForegroundTab:
    case BowPopupDecisionBackgroundTab: {
      // The new tab's own client receives the popup browser, so it is that tab's own browser from the start.
      BowTab* newTab = [[BowTab alloc] initForPopupWithProfileID:tab.profileID downloadHandler:downloadHandler_];
      NSView* parkingView = BowEngineParkingView();
      windowInfo.SetAsChild((__bridge void*)parkingView,
                            CefRect(0, 0, parkingView.bounds.size.width, parkingView.bounds.size.height));
      windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
      client = newTab->_client;
      [pendingPopupTabs_ setObject:newTab forKey:@(popupID)];
      [tab openPopupTab:newTab request:request];
      return false;
    }
  }
}

void BowTabClient::OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popupID) {
  BowTab* newTab = [pendingPopupTabs_ objectForKey:@(popupID)];
  [pendingPopupTabs_ removeObjectForKey:@(popupID)];
  [newTab popupCreationFailed];
}

void BowTabClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  // The first browser created with this client is the tab's own: the one it created, or the popup it was made for.
  if (ownBrowserID_ == 0) ownBrowserID_ = browser->GetIdentifier();
  if (!IsOwn(browser)) {
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

bool BowTabClient::DoClose(CefRefPtr<CefBrowser> browser) {
  BowEngineBrowserWillClose(browser);
  if (!IsOwn(browser)) {
    // Returning false makes CEF send performClose: to the browser's window, which suits a popup's own window.
    if (windowlessPopups_.erase(browser->GetIdentifier()) == 0) return false;
    // A popup in no window has no window to close: tear down its view as a tab does.
    BowTearDownBrowserView(browser);
    return true;
  }
  // A tab's browser is not tied to a window: tear down its own view instead.
  [tab_ browserWillClose];
  BowTearDownBrowserView(browser);
  return true;
}

void BowTabClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  if (IsOwn(browser)) [tab_ browserClosed];
  BowEngineBrowserClosed(browser);
}

@implementation BowTab (LifeSpan)

// Tells the delegate about a popup the engine is opening, even when the tab has closed since.
- (void)requestPopup:(BowPopupRequest*)request {
  if (![self takesUIRequest:@selector(tab:didRequestPopup:)]) return;
  __weak BowTab* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    BowTab* tab = weakSelf;
    id<BowTabUIDelegate> delegate = tab.uiDelegate;
    if ([delegate respondsToSelector:@selector(tab:didRequestPopup:)]) [delegate tab:tab didRequestPopup:request];
  });
}

- (BowPopupDecision)decidePopup:(BowPopupRequest*)request {
  id<BowTabUIDelegate> delegate = self.uiDelegate;
  if (![delegate respondsToSelector:@selector(tab:decidePopup:)]) return BowPopupDecisionWindow;
  return [delegate tab:self decidePopup:request];
}

- (void)openPopupTab:(BowTab*)newTab request:(BowPopupRequest*)request {
  __weak BowTab* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    BowTab* tab = weakSelf;
    id<BowTabUIDelegate> delegate = tab.uiDelegate;
    if (tab && !newTab.closed && [delegate respondsToSelector:@selector(tab:didOpenPopupTab:request:)]) {
      [delegate tab:tab didOpenPopupTab:newTab request:request];
    } else {
      // Nobody takes the tab: close it, so a page never lives on unseen.
      [newTab closeWithCompletion:^(BOOL) {
      }];
    }
  });
}

@end
