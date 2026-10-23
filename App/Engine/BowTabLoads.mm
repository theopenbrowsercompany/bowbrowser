// The tab's CefLoadHandler and the navigation tracking it feeds.
#import "BowTab+Internal.h"

void BowTabClient::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                        bool isLoading,
                                        bool canGoBack,
                                        bool canGoForward) {
  if (!IsOwn(browser)) return;
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
void BowTabClient::OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType transitionType) {
  if (!IsOwn(browser) || !frame->IsMain()) return;
  NSURL* url = BowToNSURL(frame->GetURL());
  if (url) {
    [tab_ navigationCommitted:url
                   transition:BowToTransition(transitionType)
                        frame:BowToNSString(frame->GetIdentifier())];
  }
}

void BowTabClient::OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int httpStatusCode) {
  if (!IsOwn(browser) || !frame->IsMain()) return;
  [tab_ navigationFinished:httpStatusCode frame:BowToNSString(frame->GetIdentifier())];
}

void BowTabClient::OnLoadError(CefRefPtr<CefBrowser> browser,
                               CefRefPtr<CefFrame> frame,
                               ErrorCode errorCode,
                               const CefString& errorText,
                               const CefString& failedUrl) {
  if (!IsOwn(browser) || !frame->IsMain()) return;
  [tab_ navigationFailed:errorCode text:BowToNSString(errorText) url:BowToNSURL(failedUrl)];
}

@implementation BowTab (Loads)

// Navigation events are delivered inside the engine callback that produced them, so they arrive in the engine's
// order. Each belongs to the navigation in progress: start opens it, redirects and the commit move it on, and
// finish or fail ends it. An engine callback that belongs to no navigation in progress (the load end of the error
// page Chromium shows after a failure, or the abort of a navigation the policy cancelled) is not reported. A load
// end counts only from the main frame the navigation committed in: the error page runs in its own process, so its
// load end can arrive after the next page commits.
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
                                                   isUserGesture:isUserGesture
                                                      isRedirect:isRedirect];
  id<BowTabNavigationDelegate> policyDelegate = self.navigationDelegate;
  if ([policyDelegate respondsToSelector:@selector(tab:decidePolicyForNavigation:)] &&
      [policyDelegate tab:self decidePolicyForNavigation:navigation] == BowNavigationPolicyCancel) {
    // A cancelled new navigation was never reported. A cancelled redirect ends the navigation it belongs to, which
    // was.
    if (isRedirect && _navigation) [self failNavigation:ERR_ABORTED text:kBowAbortedText];
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
  if (_navigation) [self failNavigation:ERR_ABORTED text:kBowAbortedText];
  [self beginNavigation:navigation];
  return YES;
}

// Opens `navigation` and reports its start.
- (void)beginNavigation:(BowNavigation*)navigation {
  _navigation = navigation;
  _navigationCommitted = NO;
  _navigationFrame = nil;
  _stopRequested = NO;
  id<BowTabNavigationDelegate> delegate = self.navigationDelegate;
  if ([delegate respondsToSelector:@selector(tab:didStartNavigation:)]) {
    [delegate tab:self didStartNavigation:navigation];
  }
}

- (void)navigationCommitted:(NSURL*)url
                  transition:(BowNavigationTransition)transition
                       frame:(NSString*)frameIdentifier {
  // A commit the policy was not asked about (a page restored from the back/forward cache) is a navigation of its
  // own: end a committed one still open, and report its start first, keeping the order.
  if (_navigation && _navigationCommitted) [self failNavigation:ERR_ABORTED text:kBowAbortedText];
  if (!_navigation) {
    [self beginNavigation:[[BowNavigation alloc] initWithURL:url transition:transition isUserGesture:NO]];
  }
  _navigation = [[BowNavigation alloc] initWithURL:url
                                        transition:_navigation.transition
                                     isUserGesture:_navigation.isUserGesture];
  _navigationCommitted = YES;
  _navigationFrame = [frameIdentifier copy];
  [self keepPageSignalsOfFrame:frameIdentifier];
  id<BowTabNavigationDelegate> delegate = self.navigationDelegate;
  if ([delegate respondsToSelector:@selector(tab:didCommitNavigation:)]) {
    [delegate tab:self didCommitNavigation:_navigation];
  }
}

// A load end, which finishes the committed navigation in progress when it comes from the frame that navigation
// committed in.
- (void)navigationFinished:(NSInteger)httpStatusCode frame:(NSString*)frameIdentifier {
  if (![frameIdentifier isEqualToString:_navigationFrame]) return;
  [self finishNavigation:httpStatusCode];
}

// Ends the committed navigation in progress, if any, as finished.
- (void)finishNavigation:(NSInteger)httpStatusCode {
  if (!_navigation || !_navigationCommitted) return;
  BowNavigation* navigation = _navigation;
  _navigation = nil;
  _navigationFrame = nil;
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
  _navigationFrame = nil;
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
      [tab failNavigation:ERR_ABORTED text:kBowAbortedText];
    } else {
      [tab finishNavigation:0];
    }
  });
}

@end
