// The tab's CefJSDialogHandler: JavaScript dialogs and the "leave this site?" prompt.
#import "BowTab+Internal.h"

#if BOW_E2E
#include "BowE2EHooks.h"  // E2E seam
#endif

namespace {

#if BOW_E2E  // E2E seam: set by BowEngineAnswerLeavePrompts, so e2e runs answer leave prompts off screen.
std::function<void(uint64_t, bool, std::function<void(bool)>)> gLeavePromptAnswerer;
#endif

}  // namespace

bool BowTabClient::OnJSDialog(CefRefPtr<CefBrowser> browser,
                              const CefString& originURL,
                              JSDialogType dialogType,
                              const CefString& messageText,
                              const CefString& defaultPromptText,
                              CefRefPtr<CefJSDialogCallback> callback,
                              bool& suppressMessage) {
  if (!IsOwn(browser) || ![tab_ takesUIRequest:@selector(tab:runJavaScriptDialog:completionHandler:)]) {
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

// The tab always answers "leave this page?" itself (through its UI delegate or its own prompt), so it knows
// whether the person stayed and can report that a close was cancelled. Popups keep CEF's own prompt.
bool BowTabClient::OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                                        const CefString& messageText,
                                        bool isReload,
                                        CefRefPtr<CefJSDialogCallback> callback) {
  if (!IsOwn(browser)) return false;
  BowJSDialogRequest* request = [[BowJSDialogRequest alloc] initWithKind:BowJSDialogKindBeforeUnload
                                                               originURL:nil
                                                                 message:BowToNSString(messageText)
                                                       defaultPromptText:@""
                                                                isReload:isReload];
  [tab_ runBeforeUnloadDialog:request callback:callback];
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
    // Staying on a reload prompt keeps the page; it says nothing about a pending close.
    if (!leave && !isReload && browser && BowEngineBrowserCloseCancelled(browser)) {
      BowTab* tab = weakSelf;
      if (tab) tab->_unloading = NO;
      [tab finishCloseCompletions:NO];
    }
  };
  if (_unloading && !isReload) {
    // An unload never prompts: a page that would ask to stay keeps its tab loaded. Answered outside the callback.
    dispatch_async(dispatch_get_main_queue(), ^{
      answer(NO, nil);
    });
    return;
  }
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
                                 BowRunOnMain(^{
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

@end

#if BOW_E2E  // E2E seam: the leave prompt hook declared in BowE2EHooks.h.
void BowEngineAnswerLeavePrompts(
    std::function<void(uint64_t tabID, bool isReload, std::function<void(bool leave)> answer)> answerer) {
  gLeavePromptAnswerer = std::move(answerer);
}
#endif
