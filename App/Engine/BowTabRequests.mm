// The tab's CefRequestHandler: the navigation policy and render process exits.
#import "BowTab+Internal.h"

namespace {

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

}  // namespace

// Asked before every main frame navigation and every server redirect; returning true cancels it.
bool BowTabClient::OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefFrame> frame,
                                  CefRefPtr<CefRequest> request,
                                  bool userGesture,
                                  bool isRedirect) {
  if (browser->IsPopup() || !frame->IsMain()) return false;
  NSURL* url = BowToNSURL(request->GetURL());
  if (!url) return false;
  BOOL allowed = [tab_ navigationWillStart:url
                                transition:BowToTransition(request->GetTransitionType())
                             isUserGesture:userGesture
                                isRedirect:isRedirect];
  return !allowed;
}

void BowTabClient::OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                             TerminationStatus status,
                                             int errorCode,
                                             const CefString& errorString) {
  if (browser->IsPopup()) return;
  [tab_ renderProcessTerminated:ToProcessGoneReason(status)];
}

@implementation BowTab (Requests)

- (void)renderProcessTerminated:(BowProcessGoneReason)reason {
  // Whatever was loading is gone with the process.
  [self failNavigation:ERR_ABORTED text:kBowAbortedText];
  [self askUIDelegateLater:@selector(tab:renderProcessDidTerminate:)
                       ask:^(BowTab* tab, id<BowTabUIDelegate> delegate) {
                         [delegate tab:tab renderProcessDidTerminate:reason];
                       }
                 otherwise:nil];
}

@end
