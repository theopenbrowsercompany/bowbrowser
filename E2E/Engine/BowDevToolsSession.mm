#import "BowDevToolsSession.h"

#include "BowE2EHooks.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_registration.h"

NSErrorDomain const BowDevToolsErrorDomain = @"BowDevToolsErrorDomain";

typedef void (^BowDevToolsCompletion)(NSDictionary<NSString*, id>* _Nullable, NSError* _Nullable);

@interface BowDevToolsSession ()
- (void)methodFinished:(int)messageID success:(BOOL)success data:(NSData*)data;
- (void)browserDetached;
@end

namespace {

NSError* SessionError(NSString* message) {
  return [NSError errorWithDomain:BowDevToolsErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}

// Forwards results to the session. Chromium calls it on the main thread (the UI thread).
class ResultObserver : public CefDevToolsMessageObserver {
 public:
  explicit ResultObserver(BowDevToolsSession* session) : session_(session) {}

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int messageID,
                              bool success,
                              const void* result,
                              size_t resultSize) override {
    [session_ methodFinished:messageID success:success data:[NSData dataWithBytes:result length:resultSize]];
  }

  // Results pending at this point will never arrive (the browser closed, or the agent detached for another
  // reason); the next call attaches it again.
  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) override { [session_ browserDetached]; }

 private:
  __weak BowDevToolsSession* session_;

  IMPLEMENT_REFCOUNTING(ResultObserver);
};

// Message ids are chosen here rather than by Chromium, so a call's completion is stored before the call is sent
// and a result that arrives during ExecuteDevToolsMethod still finds it.
int gNextMessageID = 1;

}  // namespace

@implementation BowDevToolsSession {
  uint64_t _tabID;
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<CefRegistration> _registration;
  NSMutableDictionary<NSNumber*, BowDevToolsCompletion>* _completions;
  BOOL _closed;
}

- (instancetype)initWithTabID:(uint64_t)tabID {
  self = [super init];
  if (self) {
    _tabID = tabID;
    _completions = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)dealloc {
  // Every call gets an answer, so nothing waiting on one hangs.
  [self failEverything:@"the DevTools session was released"];
}

// Finds the tab's browser and starts listening to it. A tab owns one browser for its whole life, attached to a
// window or not, so the browser found first stays the session's browser.
- (BOOL)attachIfPossible {
  if (_browser) return YES;
  if (_closed) return NO;
  CefRefPtr<CefBrowser> browser = BowEngineBrowserForTabID(_tabID);
  if (!browser) return NO;
  _browser = browser;
  _registration = browser->GetHost()->AddDevToolsMessageObserver(new ResultObserver(self));
  return YES;
}

- (void)callMethod:(NSString*)method
            params:(NSDictionary<NSString*, id>*)params
        completion:(BowDevToolsCompletion)completion {
  if (_closed || (_browser && !_browser->IsValid())) {
    completion(nil, SessionError([NSString stringWithFormat:@"%@: the browser has closed", method]));
    return;
  }
  if (![self attachIfPossible]) {
    if (!BowEngineTabIsOpening(_tabID)) {
      completion(nil, SessionError([NSString stringWithFormat:@"%@: no open tab has ID %llu", method, _tabID]));
      return;
    }
    // The tab's browser is still being created (a new persistent profile starts up on disk first): try again
    // shortly. The test step's own timeout bounds the wait.
    __weak BowDevToolsSession* weakSelf = self;
    NSDictionary<NSString*, id>* paramsCopy = [params copy];
    BowDevToolsCompletion completionCopy = [completion copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      BowDevToolsSession* session = weakSelf;
      if (!session) {
        completionCopy(nil, SessionError(@"the DevTools session was released"));
        return;
      }
      [session callMethod:method params:paramsCopy completion:completionCopy];
    });
    return;
  }

  CefRefPtr<CefDictionaryValue> dictionary = CefDictionaryValue::Create();
  if (params.count > 0) {
    // dataWithJSONObject: throws rather than failing for values JSON cannot hold, so check first.
    NSData* json = [NSJSONSerialization isValidJSONObject:params]
                       ? [NSJSONSerialization dataWithJSONObject:params options:0 error:nil]
                       : nil;
    CefRefPtr<CefValue> value = json ? CefParseJSON(json.bytes, json.length, JSON_PARSER_RFC) : nullptr;
    if (!value || value->GetType() != VTYPE_DICTIONARY) {
      completion(nil, SessionError([NSString stringWithFormat:@"%@: params are not a JSON object", method]));
      return;
    }
    dictionary = value->GetDictionary();
  }

  const int messageID = gNextMessageID++;
  _completions[@(messageID)] = [completion copy];
  if (_browser->GetHost()->ExecuteDevToolsMethod(messageID, method.UTF8String, dictionary) == 0) {
    [self finish:messageID result:nil error:[NSString stringWithFormat:@"%@: the browser did not accept the call", method]];
  }
}

- (void)methodFinished:(int)messageID success:(BOOL)success data:(NSData*)data {
  id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  NSDictionary* result = [object isKindOfClass:[NSDictionary class]] ? object : nil;
  if (!result) {
    [self finish:messageID result:nil error:@"DevTools answered with something other than a JSON object"];
  } else if (!success) {
    // Failed calls answer {"code": ..., "message": ...}.
    NSString* message = [result[@"message"] isKindOfClass:[NSString class]] ? result[@"message"] : @"unknown error";
    [self finish:messageID result:nil error:message];
  } else {
    [self finish:messageID result:result error:nil];
  }
}

- (void)finish:(int)messageID result:(NSDictionary*)result error:(NSString*)error {
  BowDevToolsCompletion completion = _completions[@(messageID)];
  if (!completion) return;
  [_completions removeObjectForKey:@(messageID)];
  completion(result, error ? SessionError(error) : nil);
}

- (void)browserDetached {
  NSDictionary<NSNumber*, BowDevToolsCompletion>* completions = [_completions copy];
  [_completions removeAllObjects];
  for (BowDevToolsCompletion completion in completions.allValues) {
    completion(nil, SessionError(@"DevTools detached before answering, for example because the browser closed"));
  }
}

- (void)close {
  if (_closed) return;
  _closed = YES;
  _registration = nullptr;
  _browser = nullptr;
  [self failEverything:@"the browser has closed"];
}

- (void)failEverything:(NSString*)message {
  NSDictionary<NSNumber*, BowDevToolsCompletion>* completions = [_completions copy];
  [_completions removeAllObjects];
  for (BowDevToolsCompletion completion in completions.allValues) completion(nil, SessionError(message));
}

@end
