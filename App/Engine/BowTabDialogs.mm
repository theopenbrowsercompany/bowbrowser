// The tab's CefJSDialogHandler: JavaScript dialogs and the "leave this site?" prompt.
#import "BowTab+Internal.h"

#if BOW_E2E
#include "BowE2EHooks.h"  // E2E seam
#endif

namespace {

#if BOW_E2E  // E2E seam: set by BowEngineAnswerLeavePrompts, so e2e runs answer leave prompts off screen.
std::function<void(uint64_t, bool, std::function<void(bool)>)> gLeavePromptAnswerer;
#endif

// The dialog sheet up on each popup window of the engine's own, by browser ID, so the engine can take it down.
NSMutableDictionary<NSNumber*, NSAlert*>* PopupDialogs() {
  static NSMutableDictionary<NSNumber*, NSAlert*>* dialogs = [NSMutableDictionary dictionary];
  return dialogs;
}

// The sheet's title, by the same rules as PageDialog.title in BowCore (which the bridge cannot call): "<host> says"
// for an http or https origin, with its port when it is not the scheme's default, else "This page says".
NSString* PopupDialogTitle(NSURL* origin) {
  NSString* scheme = origin.scheme.lowercaseString;
  NSString* host = origin.host;
  if (!host.length || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
    return @"This page says";
  }
  const NSInteger defaultPort = [scheme isEqualToString:@"https"] ? 443 : 80;
  if (origin.port && origin.port.integerValue != defaultPort) {
    return [NSString stringWithFormat:@"%@:%@ says", host, origin.port];
  }
  return [host stringByAppendingString:@" says"];
}

// A page in a popup window of the engine's own asked for an alert, confirm or prompt: a sheet on that window, so
// only the popup waits. A popup in no window (an e2e run parks them off screen) is answered as cancelled.
void RunPopupWindowDialog(CefRefPtr<CefBrowser> browser,
                          const CefString& originURL,
                          CefJSDialogHandler::JSDialogType dialogType,
                          const CefString& messageText,
                          const CefString& defaultPromptText,
                          CefRefPtr<CefJSDialogCallback> callback) {
  NSView* view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
  NSWindow* window = view.window;
  if (!window) {
    callback->Continue(false, CefString());
    return;
  }
  NSNumber* browserID = @(browser->GetIdentifier());
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = PopupDialogTitle(BowToNSURL(originURL));
  alert.informativeText = BowToNSString(messageText);
  [alert addButtonWithTitle:@"OK"];
  if (dialogType != JSDIALOGTYPE_ALERT) [alert addButtonWithTitle:@"Cancel"];
  NSTextField* field = nil;
  if (dialogType == JSDIALOGTYPE_PROMPT) {
    field = [NSTextField textFieldWithString:BowToNSString(defaultPromptText)];
    field.frame = NSMakeRect(0, 0, 260, 22);
    alert.accessoryView = field;
  }
  // A page asks one dialog at a time; a new one replaces any earlier sheet (as the window feature does for tabs).
  NSAlert* earlier = PopupDialogs()[browserID];
  if (earlier.window.sheetParent) [earlier.window.sheetParent endSheet:earlier.window returnCode:NSModalResponseAbort];
  PopupDialogs()[browserID] = alert;
  __weak NSAlert* weakAlert = alert;
  [alert beginSheetModalForWindow:window
                completionHandler:^(NSModalResponse response) {
                  if (PopupDialogs()[browserID] == weakAlert) [PopupDialogs() removeObjectForKey:browserID];
                  const bool accepted = response == NSAlertFirstButtonReturn;
                  callback->Continue(accepted, accepted && field ? field.stringValue.UTF8String : "");
                }];
}

}  // namespace

bool BowTabClient::OnJSDialog(CefRefPtr<CefBrowser> browser,
                              const CefString& originURL,
                              JSDialogType dialogType,
                              const CefString& messageText,
                              const CefString& defaultPromptText,
                              CefRefPtr<CefJSDialogCallback> callback,
                              bool& suppressMessage) {
  // A closed tab's page kept for its downloads is never heard: suppressing (rather than answering) is how CEF
  // expects an unwanted dialog to be refused.
  if (RefusesUIRequest(browser, "dialog")) {
    suppressMessage = true;
    return false;
  }
  // A popup in a window of the engine's own asks on that window, never app modal.
  if (!IsOwn(browser)) {
    RunPopupWindowDialog(browser, originURL, dialogType, messageText, defaultPromptText, callback);
    return true;
  }
  // Without a UI delegate that takes dialogs the page is answered as cancelled: CEF's own dialog is app modal.
  if (![tab_ takesUIRequest:@selector(tab:runJavaScriptDialog:completionHandler:)]) {
    suppressMessage = true;
    return false;
  }
  BowJSDialogKind kind = BowJSDialogKindAlert;
  if (dialogType == JSDIALOGTYPE_CONFIRM) kind = BowJSDialogKindConfirm;
  if (dialogType == JSDIALOGTYPE_PROMPT) kind = BowJSDialogKindPrompt;
  BowJSDialogRequest* request = [[BowJSDialogRequest alloc] initWithKind:kind
                                                               originURL:BowToNSURL(originURL)
                                                                 message:BowToNSString(messageText)
                                                       defaultPromptText:BowToNSString(defaultPromptText)
                                                                isReload:NO];
  [tab_ runJavaScriptDialog:request callback:callback];
  return true;
}

// The engine cancels a page's dialogs (a navigation, the page going away). A popup window's sheet is taken down
// here, answering its page as cancelled; a tab's dialog is taken down by the window, which hears of the navigation
// or close itself.
void BowTabClient::OnResetDialogState(CefRefPtr<CefBrowser> browser) {
  if (IsOwn(browser)) return;
  NSNumber* browserID = @(browser->GetIdentifier());
  NSAlert* alert = PopupDialogs()[browserID];
  if (!alert) return;
  [PopupDialogs() removeObjectForKey:browserID];
  if (alert.window.sheetParent) [alert.window.sheetParent endSheet:alert.window returnCode:NSModalResponseAbort];
}

// The tab always answers "leave this page?" itself with its own prompt, so it knows whether the person stayed and
// can report that a close was cancelled. Popups keep CEF's own prompt.
bool BowTabClient::OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                                        const CefString& messageText,
                                        bool isReload,
                                        CefRefPtr<CefJSDialogCallback> callback) {
  // A closed tab's page kept for its downloads has nobody to ask; it leaves, as an unanswered prompt does.
  if (RefusesUIRequest(browser, "dialog")) {
    callback->Continue(true, CefString());
    return true;
  }
  if (!IsOwn(browser)) return false;
  BowJSDialogRequest* request = [[BowJSDialogRequest alloc] initWithKind:BowJSDialogKindBeforeUnload
                                                               originURL:nil
                                                                 message:BowToNSString(messageText)
                                                       defaultPromptText:@""
                                                                isReload:isReload];
  [tab_ runBeforeUnloadDialog:request callback:callback];
  return true;
}

// File choosers keep CEF's own panel, except for a closed tab's page kept for its downloads, which gets none.
bool BowTabClient::OnFileDialog(CefRefPtr<CefBrowser> browser,
                                FileDialogMode mode,
                                const CefString& title,
                                const CefString& defaultFilePath,
                                const std::vector<CefString>& acceptFilters,
                                const std::vector<CefString>& acceptExtensions,
                                const std::vector<CefString>& acceptDescriptions,
                                CefRefPtr<CefFileDialogCallback> callback) {
  if (!RefusesUIRequest(browser, "file dialog")) return false;
  callback->Cancel();
  return true;
}

@implementation BowTab (Dialogs)

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
    // Staying on a reload prompt keeps the page; it says nothing about a pending close. Only a prompt the person
    // answered gets here, so staying cancels a pending close and a quit. A navigation's prompt cancels no close.
    if (!leave && !isReload && browser && BowEngineBrowserCloseCancelled(browser)) [weakSelf finishCloseCompletions:NO];
  };
  if (_unloading && !isReload) {
    // An unload never prompts: a page that would ask to stay keeps its tab loaded. Answered outside the callback.
    // A close asked for since, or a quit begun since (whose own close request the pending one absorbed), takes
    // over and asks as usual, so a silent answer never cancels either.
    dispatch_async(dispatch_get_main_queue(), ^{
      BowTab* tab = weakSelf;
      if (tab && tab->_unloading && BowEngineIsQuitting()) {
        tab->_unloading = NO;
        [tab finishCloseCompletions:NO];
      }
      if (tab && !tab->_unloading) {
        [tab runBeforeUnloadDialog:request callback:callback];
        return;
      }
      callback->Continue(false, CefString());
      if (!tab) return;
      tab->_unloading = NO;
      if (browser) BowEngineBrowserUnloadRefused(browser);
      [tab finishCloseCompletions:NO];
    });
    return;
  }
  [self runLeavePrompt:request answer:answer];
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
                                 BowRunOnMain(^{
                                   answer(accepted, input);
                                 });
                               }];
                       }
                 otherwise:otherwise];
}

// The tab's own "leave this site?" prompt, which the tab always asks itself (never its UI delegate): a sheet on the
// window showing the tab, or a free-floating alert while the tab is detached.
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

@end

#if BOW_E2E  // E2E seam: the leave prompt and popup dialog hooks declared in BowE2EHooks.h.
void BowEngineAnswerLeavePrompts(
    std::function<void(uint64_t tabID, bool isReload, std::function<void(bool leave)> answer)> answerer) {
  gLeavePromptAnswerer = std::move(answerer);
}

NSAlert* BowEnginePopupDialogOnWindow(NSWindow* window) {
  for (NSAlert* alert in PopupDialogs().allValues) {
    if (alert.window.sheetParent == window) return alert;
  }
  return nil;
}
#endif
