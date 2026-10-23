// The tab's CefRequestHandler: the navigation policy, HTTP sign in, certificate errors and render process exits.
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
  if (!IsOwn(browser) || !frame->IsMain()) return false;
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
  if (!IsOwn(browser)) return;
  [tab_ renderProcessTerminated:ToProcessGoneReason(status)];
}

bool BowTabClient::GetAuthCredentials(CefRefPtr<CefBrowser> browser,
                                      const CefString& originURL,
                                      bool isProxy,
                                      const CefString& host,
                                      int port,
                                      const CefString& realm,
                                      const CefString& scheme,
                                      CefRefPtr<CefAuthCallback> callback) {
  // Called on the IO thread, unlike the other handlers: whether the browser is the tab's, the tab and its delegate
  // are all asked on the main thread.
  BowAuthChallenge* challenge = [[BowAuthChallenge alloc] initWithURL:BowToNSURL(originURL)
                                                                 host:BowToNSString(host)
                                                                 port:port
                                                                realm:BowToNSString(realm)
                                                               scheme:BowToNSString(scheme)
                                                            fromProxy:isProxy];
  CefRefPtr<BowTabClient> client(this);
  dispatch_async(dispatch_get_main_queue(), ^{
    BowTab* tab = client->tab_;
    if (client->IsOwn(browser) && tab && [tab takesUIRequest:@selector(tab:answerAuthChallenge:completionHandler:)]) {
      [tab answerAuthChallenge:challenge callback:callback];
    } else {
      callback->Cancel();
    }
  });
  return true;
}

bool BowTabClient::OnCertificateError(CefRefPtr<CefBrowser> browser,
                                      cef_errorcode_t certError,
                                      const CefString& requestURL,
                                      CefRefPtr<CefSSLInfo> sslInfo,
                                      CefRefPtr<CefCallback> callback) {
  if (!IsOwn(browser) || ![tab_ takesUIRequest:@selector(tab:decideCertificateError:decisionHandler:)]) return false;
  BowCertificateError* error = [[BowCertificateError alloc] initWithURL:BowToNSURL(requestURL) code:certError];
  [tab_ decideCertificateError:error callback:callback];
  return true;
}

@implementation BowTab (Requests)

- (void)renderProcessTerminated:(BowProcessGoneReason)reason {
  // Whatever was loading is gone with the process, and so is what its frames reported.
  [self failNavigation:ERR_ABORTED text:kBowAbortedText];
  [self keepPageSignalsOfFrame:nil];
  [self askUIDelegateLater:@selector(tab:renderProcessDidTerminate:)
                       ask:^(BowTab* tab, id<BowTabUIDelegate> delegate) {
                         [delegate tab:tab renderProcessDidTerminate:reason];
                       }
                 otherwise:nil];
}

- (void)answerAuthChallenge:(BowAuthChallenge*)challenge callback:(CefRefPtr<CefAuthCallback>)callback {
  void (^answer)(NSString*, NSString*) = ^(NSString* user, NSString* password) {
    if (user && password) {
      callback->Continue(user.UTF8String, password.UTF8String);
    } else {
      callback->Cancel();
    }
  };
  [self askUIDelegateLater:@selector(tab:answerAuthChallenge:completionHandler:)
      ask:^(BowTab* tab, id<BowTabUIDelegate> delegate) {
        BowAnswerOnce* once = [[BowAnswerOnce alloc] initWithFallback:^{
          answer(nil, nil);
        }];
        [delegate tab:tab
            answerAuthChallenge:challenge
              completionHandler:^(NSString* user, NSString* password) {
                if (![once claim]) return;
                NSString* userCopy = [user copy];
                NSString* passwordCopy = [password copy];
                BowRunOnMain(^{
                  answer(userCopy, passwordCopy);
                });
              }];
      }
      otherwise:^{
        answer(nil, nil);
      }];
}

- (void)decideCertificateError:(BowCertificateError*)error callback:(CefRefPtr<CefCallback>)callback {
  void (^answer)(BOOL) = ^(BOOL proceed) {
    if (proceed) {
      callback->Continue();
    } else {
      callback->Cancel();
    }
  };
  [self askUIDelegateLater:@selector(tab:decideCertificateError:decisionHandler:)
      ask:^(BowTab* tab, id<BowTabUIDelegate> delegate) {
        BowAnswerOnce* once = [[BowAnswerOnce alloc] initWithFallback:^{
          answer(NO);
        }];
        [delegate tab:tab
            decideCertificateError:error
                   decisionHandler:^(BOOL proceed) {
                     if (![once claim]) return;
                     BowRunOnMain(^{
                       answer(proceed);
                     });
                   }];
      }
      otherwise:^{
        answer(NO);
      }];
}

@end
