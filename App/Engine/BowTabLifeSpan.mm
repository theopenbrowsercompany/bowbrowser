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
  BowPopupRequest* request = [[BowPopupRequest alloc] initWithTargetURL:BowToNSURL(targetURL)
                                                            disposition:ToPopupDisposition(targetDisposition)
                                                          isUserGesture:userGesture
                                                          requestedSize:size];
  [tab_ requestPopup:request];
  return false;
}

void BowTabClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
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

bool BowTabClient::DoClose(CefRefPtr<CefBrowser> browser) {
  BowEngineBrowserWillClose(browser);
  if (browser->IsPopup()) {
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
  if (!browser->IsPopup()) [tab_ browserClosed];
  BowEngineBrowserClosed(browser);
}

@implementation BowTab (LifeSpan)

// Tells the delegate about a popup the engine is opening, even when the tab has closed since.
- (void)requestPopup:(BowPopupRequest*)request {
  __weak BowTab* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    BowTab* tab = weakSelf;
    id<BowTabUIDelegate> delegate = tab.uiDelegate;
    if ([delegate respondsToSelector:@selector(tab:didRequestPopup:)]) [delegate tab:tab didRequestPopup:request];
  });
}

@end
