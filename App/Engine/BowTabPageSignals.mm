// The browser side of the page signal channel (App/Helper/BowPageSignalNames.h): the render process reports from
// each frame when it plays sound and when the person edited one of its form fields, and the tab turns them into its
// audible and edited form state (BowTab.mm). CEF 156 has no audible event of its own (its audio handler takes the
// sound over instead of reporting it), and the app sees key events only, not paste, drop, dictation or autofill.
#import "BowTab+Internal.h"

#include "../Helper/BowPageSignalNames.h"

bool BowTabClient::OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                            CefRefPtr<CefFrame> frame,
                                            CefProcessId sourceProcess,
                                            CefRefPtr<CefProcessMessage> message) {
  if (message->GetName() != kBowPageSignalMessage) return false;
  // A frame that already left the page (its signal crossed its detach) has nothing left to report.
  if (sourceProcess != PID_RENDERER || !IsOwn(browser) || !frame || !frame->IsValid()) return true;
  CefRefPtr<CefListValue> values = message->GetArgumentList();
  if (values->GetSize() != 2 || values->GetType(0) != VTYPE_STRING || values->GetType(1) != VTYPE_BOOL) return true;
  [tab_ pageSignal:BowToNSString(values->GetString(0))
                on:values->GetBool(1)
             frame:BowToNSString(frame->GetIdentifier())];
  return true;
}

void BowTabClient::OnFrameDetached(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame) {
  if (!IsOwn(browser)) return;
  [tab_ pageFrameDetached:BowToNSString(frame->GetIdentifier())];
}
