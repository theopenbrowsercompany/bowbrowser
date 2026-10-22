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

// A call made before the browser existed.
@interface BowDevToolsWaitingCall : NSObject
@property(nonatomic, copy) NSString* method;
@property(nonatomic, copy, nullable) NSDictionary<NSString*, id>* params;
@property(nonatomic, copy) BowDevToolsCompletion completion;
@end

@implementation BowDevToolsWaitingCall
@end

@implementation BowDevToolsSession {
  __weak NSView* _hostView;
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<CefRegistration> _registration;
  // Calls made before the browser existed, run in order once it does.
  NSMutableArray<BowDevToolsWaitingCall*>* _waitingForBrowser;
  NSMutableDictionary<NSNumber*, BowDevToolsCompletion>* _completions;
}

- (instancetype)initWithHostView:(NSView*)view {
  self = [super init];
  if (self) {
    _hostView = view;
    _waitingForBrowser = [NSMutableArray array];
    _completions = [NSMutableDictionary dictionary];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(browserCreated:)
                                                 name:BowEngineBrowserCreatedNotification
                                               object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  // Every call gets an answer, so nothing waiting on one hangs.
  [self failEverything:@"the DevTools session was released"];
}

- (void)browserCreated:(NSNotification*)notification {
  // Chromium's view joins the host view right after creation; look for it on a later main thread task.
  __weak BowDevToolsSession* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    [weakSelf attachIfPossible];
  });
}

// Finds the browser whose Chromium view sits in the host view, starts listening to it and sends waiting calls.
- (BOOL)attachIfPossible {
  if (_browser) return YES;
  NSView* hostView = _hostView;
  if (!hostView) return NO;
  for (const CefRefPtr<CefBrowser>& browser : BowEngineOpenBrowsers()) {
    NSView* browserView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    if (![browserView isDescendantOf:hostView]) continue;
    _browser = browser;
    _registration = browser->GetHost()->AddDevToolsMessageObserver(new ResultObserver(self));
    NSArray<BowDevToolsWaitingCall*>* waiting = [_waitingForBrowser copy];
    [_waitingForBrowser removeAllObjects];
    for (BowDevToolsWaitingCall* call in waiting) {
      [self callMethod:call.method params:call.params completion:call.completion];
    }
    return YES;
  }
  return NO;
}

- (void)callMethod:(NSString*)method
            params:(NSDictionary<NSString*, id>*)params
        completion:(BowDevToolsCompletion)completion {
  if (_browser && !_browser->IsValid()) {
    completion(nil, SessionError([NSString stringWithFormat:@"%@: the browser has closed", method]));
    return;
  }
  if (![self attachIfPossible]) {
    BowDevToolsWaitingCall* call = [[BowDevToolsWaitingCall alloc] init];
    call.method = method;
    call.params = params;
    call.completion = completion;
    [_waitingForBrowser addObject:call];
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

- (void)failEverything:(NSString*)message {
  NSDictionary<NSNumber*, BowDevToolsCompletion>* completions = [_completions copy];
  [_completions removeAllObjects];
  for (BowDevToolsCompletion completion in completions.allValues) completion(nil, SessionError(message));
  NSArray<BowDevToolsWaitingCall*>* waiting = [_waitingForBrowser copy];
  [_waitingForBrowser removeAllObjects];
  for (BowDevToolsWaitingCall* call in waiting) call.completion(nil, SessionError(message));
}

@end
