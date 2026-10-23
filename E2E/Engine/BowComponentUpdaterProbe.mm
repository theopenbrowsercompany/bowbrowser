#import "BowComponentUpdaterProbe.h"
#import "BowLoopbackFixtures+Shared.h"

#include <atomic>
#include <vector>

#include "include/cef_component_updater.h"

namespace {

NSString* StateName(cef_component_state_t state) {
  switch (state) {
    case CEF_COMPONENT_STATE_NEW: return @"new";
    case CEF_COMPONENT_STATE_CHECKING: return @"checking";
    case CEF_COMPONENT_STATE_CAN_UPDATE: return @"can update";
    case CEF_COMPONENT_STATE_DOWNLOADING: return @"downloading";
    case CEF_COMPONENT_STATE_DECOMPRESSING: return @"decompressing";
    case CEF_COMPONENT_STATE_PATCHING: return @"patching";
    case CEF_COMPONENT_STATE_UPDATING: return @"updating";
    case CEF_COMPONENT_STATE_UPDATED: return @"updated";
    case CEF_COMPONENT_STATE_UP_TO_DATE: return @"up to date";
    case CEF_COMPONENT_STATE_UPDATE_ERROR: return @"update error";
    case CEF_COMPONENT_STATE_RUN: return @"run";
  }
  return [NSString stringWithFormat:@"state %d", static_cast<int>(state)];
}

NSString* ErrorName(cef_component_update_error_t error) {
  switch (error) {
    case CEF_COMPONENT_UPDATE_ERROR_NONE: return @"none";
    case CEF_COMPONENT_UPDATE_ERROR_UPDATE_IN_PROGRESS: return @"update in progress";
    case CEF_COMPONENT_UPDATE_ERROR_UPDATE_CANCELED: return @"update canceled";
    case CEF_COMPONENT_UPDATE_ERROR_RETRY_LATER: return @"retry later";
    case CEF_COMPONENT_UPDATE_ERROR_SERVICE_ERROR: return @"service error";
    case CEF_COMPONENT_UPDATE_ERROR_UPDATE_CHECK_ERROR: return @"update check error";
    case CEF_COMPONENT_UPDATE_ERROR_CRX_NOT_FOUND: return @"crx not found";
    case CEF_COMPONENT_UPDATE_ERROR_INVALID_ARGUMENT: return @"invalid argument";
    case CEF_COMPONENT_UPDATE_ERROR_BAD_CRX_DATA_CALLBACK: return @"bad crx data callback";
  }
  return [NSString stringWithFormat:@"error %d", static_cast<int>(error)];
}

NSString* String(const CefString& value) {
  return [NSString stringWithUTF8String:value.ToString().c_str()] ?: @"";
}

// Hands the result to the Objective-C block. CEF calls it once, on the UI thread, which is the main thread here.
class UpdateCallback : public CefComponentUpdateCallback {
 public:
  explicit UpdateCallback(void (^completion)(NSString*)) : completion_(completion) {}

  void OnComplete(const CefString&, cef_component_update_error_t error) override {
    if (completion_) completion_(ErrorName(error));
    completion_ = nil;
  }

 private:
  void (^completion_)(NSString*);

  IMPLEMENT_REFCOUNTING(UpdateCallback);
};

}  // namespace

@implementation BowE2EComponent

- (instancetype)initWithComponent:(CefRefPtr<CefComponent>)component {
  if ((self = [super init])) {
    _componentID = [String(component->GetID()) copy];
    _name = [String(component->GetName()) copy];
    _version = [String(component->GetVersion()) copy];
    _state = [StateName(component->GetState()) copy];
  }
  return self;
}

@end

@implementation BowComponentUpdaterProbe

+ (BOOL)isAvailable {
  return CefComponentUpdater::GetComponentUpdater() != nullptr;
}

+ (NSArray<BowE2EComponent*>*)registeredComponents {
  CefRefPtr<CefComponentUpdater> updater = CefComponentUpdater::GetComponentUpdater();
  if (!updater) return @[];
  std::vector<CefRefPtr<CefComponent>> components;
  updater->GetComponents(components);
  NSMutableArray<BowE2EComponent*>* result = [NSMutableArray arrayWithCapacity:components.size()];
  for (const auto& component : components) {
    if (component) [result addObject:[[BowE2EComponent alloc] initWithComponent:component]];
  }
  return result;
}

+ (void)checkForUpdateOf:(NSString*)componentID completion:(void (^)(NSString*))completion {
  CefRefPtr<CefComponentUpdater> updater = CefComponentUpdater::GetComponentUpdater();
  if (!updater) {
    completion(@"no updater");
    return;
  }
  updater->Update(componentID.UTF8String, CEF_COMPONENT_UPDATE_PRIORITY_FOREGROUND, new UpdateCallback(completion));
}

@end

namespace {

const NSTimeInterval kServerStartTimeout = 5;
const NSTimeInterval kServerStopTimeout = 3;
// A request larger than this is cut off (an update check is a few kilobytes).
const NSUInteger kMaxRequest = 256 * 1024;

NSError* ServerError(NSString* message) {
  return [NSError errorWithDomain:@"BowE2EUpdateServer" code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}

// True when the bytes after the head hold the whole body: `Content-Length` bytes, or for a chunked body everything
// up to the last (empty) chunk. A chunked body is kept as it arrived, chunk sizes and all, which still holds the
// app IDs the check looks for.
bool BodyComplete(NSString* head, NSData* data, NSUInteger bodyStart) {
  NSString* encoding = BowLoopbackHeaderValue(head, @"Transfer-Encoding");
  if (encoding && [encoding rangeOfString:@"chunked" options:NSCaseInsensitiveSearch].location != NSNotFound) {
    NSData* last = [@"0\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange body = NSMakeRange(bodyStart, data.length - bodyStart);
    return body.length >= last.length &&
           [data rangeOfData:last options:NSDataSearchBackwards | NSDataSearchAnchored range:body].location !=
               NSNotFound;
  }
  NSInteger length = [BowLoopbackHeaderValue(head, @"Content-Length") integerValue];
  return data.length >= bodyStart + (NSUInteger)MAX(0, length);
}

}  // namespace

@implementation BowE2EUpdateRequest

- (instancetype)initWithMethod:(NSString*)method target:(NSString*)target host:(NSString*)host body:(NSString*)body {
  if ((self = [super init])) {
    _method = [method copy];
    _target = [target copy];
    _host = [host copy];
    _body = [body copy];
  }
  return self;
}

@end

@implementation BowE2EUpdateServer {
  // Every listener and connection callback runs here.
  dispatch_queue_t _queue;
  nw_listener_t _listener;
  // Open connections and the requests received, touched on _queue only.
  NSMutableArray<nw_connection_t>* _connections;
  NSMutableArray<BowE2EUpdateRequest*>* _requests;
  // Left when the listener reaches the cancelled state, so stop can wait for the socket to close.
  dispatch_group_t _cancelled;
  std::atomic<bool> _stopped;
}

+ (instancetype)startWithError:(NSError**)error {
  BowE2EUpdateServer* server = [[BowE2EUpdateServer alloc] initPrivate];
  if (![server start:error]) {
    [server stop];
    return nil;
  }
  return server;
}

- (instancetype)initPrivate {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("bow.e2e.update-server", DISPATCH_QUEUE_SERIAL);
    _connections = [NSMutableArray array];
    _requests = [NSMutableArray array];
    _cancelled = dispatch_group_create();
  }
  return self;
}

// Never waits on _queue here: the last reference can go on _queue itself, from a callback that held it.
- (void)dealloc {
  if (_stopped.exchange(true)) return;
  if (_listener) nw_listener_cancel(_listener);
  NSMutableArray<nw_connection_t>* connections = _connections;
  dispatch_async(_queue, ^{
    for (nw_connection_t connection in [connections copy]) nw_connection_force_cancel(connection);
  });
}

- (NSArray<BowE2EUpdateRequest*>*)requests {
  __block NSArray<BowE2EUpdateRequest*>* requests = nil;
  dispatch_sync(_queue, ^{
    requests = [_requests copy];
  });
  return requests;
}

- (BOOL)start:(NSError**)error {
  sec_identity_t identity = BowLoopbackFixtureIdentity(error);
  if (!identity) return NO;
  nw_parameters_t parameters = nw_parameters_create_secure_tcp(
      ^(nw_protocol_options_t tlsOptions) {
        sec_protocol_options_t options = nw_tls_copy_sec_protocol_options(tlsOptions);
        sec_protocol_options_set_local_identity(options, identity);
        // HTTP/1.1 only: this server does not speak HTTP/2.
        sec_protocol_options_add_tls_application_protocol(options, "http/1.1");
      },
      NW_PARAMETERS_DEFAULT_CONFIGURATION);
  BowLoopbackBind(parameters);
  nw_listener_t listener = nw_listener_create(parameters);
  if (!listener) {
    if (error) *error = ServerError(@"cannot create a loopback listener");
    return NO;
  }
  dispatch_semaphore_t settled = dispatch_semaphore_create(0);
  __block bool ready = false;
  __block bool signalled = false;
  __block nw_error_t failure = nil;
  dispatch_group_t cancelled = _cancelled;
  dispatch_group_enter(cancelled);
  nw_listener_set_queue(listener, _queue);
  nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t stateError) {
    switch (state) {
      case nw_listener_state_ready:
        ready = true;
        break;
      case nw_listener_state_failed:
        failure = stateError;
        break;
      case nw_listener_state_cancelled:
        dispatch_group_leave(cancelled);
        break;
      default:
        return;
    }
    if (!signalled) {
      signalled = true;
      dispatch_semaphore_signal(settled);
    }
  });
  __weak BowE2EUpdateServer* weakSelf = self;
  nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
    BowE2EUpdateServer* server = weakSelf;
    if (server) {
      [server accept:connection];
    } else {
      nw_connection_cancel(connection);
    }
  });
  _listener = listener;
  nw_listener_start(listener);
  long waited = dispatch_semaphore_wait(
      settled, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kServerStartTimeout * NSEC_PER_SEC)));
  __block bool isReady = false;
  __block NSString* reason = nil;
  dispatch_sync(_queue, ^{
    isReady = ready;
    if (!ready) reason = waited != 0 ? @"it did not start in time" : BowLoopbackDescribe(failure);
  });
  if (!isReady) {
    if (error) *error = ServerError([@"the update server listener could not start: " stringByAppendingString:reason]);
    return NO;
  }
  _port = nw_listener_get_port(listener);
  return YES;
}

- (void)accept:(nw_connection_t)connection {
  if (_stopped.load()) {
    nw_connection_cancel(connection);
    return;
  }
  [_connections addObject:connection];
  __weak BowE2EUpdateServer* weakSelf = self;
  nw_connection_set_queue(connection, _queue);
  nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t) {
    if (state == nw_connection_state_failed) nw_connection_cancel(connection);
    BowE2EUpdateServer* server = weakSelf;
    if (server && state == nw_connection_state_cancelled) [server->_connections removeObject:connection];
  });
  nw_connection_start(connection);
  [self receiveOn:connection data:[NSMutableData data]];
}

// Reads until the head and the body its Content-Length announces are in, then records and answers the request.
- (void)receiveOn:(nw_connection_t)connection data:(NSMutableData*)data {
  __weak BowE2EUpdateServer* weakSelf = self;
  nw_connection_receive(
      connection, 1, (uint32_t)kMaxRequest,
      ^(dispatch_data_t content, nw_content_context_t, bool isComplete, nw_error_t error) {
        BowE2EUpdateServer* server = weakSelf;
        if (!server) {
          nw_connection_cancel(connection);
          return;
        }
        if (content) {
          dispatch_data_apply(content, ^bool(dispatch_data_t, size_t, const void* buffer, size_t size) {
            [data appendBytes:buffer length:size];
            return true;
          });
        }
        NSData* end = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange found = [data rangeOfData:end options:0 range:NSMakeRange(0, data.length)];
        if (found.location != NSNotFound) {
          NSString* head =
              [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, found.location)]
                                    encoding:NSUTF8StringEncoding]
                  ?: @"";
          NSUInteger bodyStart = NSMaxRange(found);
          if (BodyComplete(head, data, bodyStart) || error || isComplete || data.length > kMaxRequest) {
            NSData* body = [data subdataWithRange:NSMakeRange(bodyStart, data.length - bodyStart)];
            [server answer:connection head:head body:body];
            return;
          }
        } else if (error || isComplete || data.length > kMaxRequest) {
          nw_connection_cancel(connection);
          return;
        }
        [server receiveOn:connection data:data];
      });
}

- (void)answer:(nw_connection_t)connection head:(NSString*)head body:(NSData*)body {
  NSArray<NSString*>* requestLine =
      [[head componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "];
  BowE2EUpdateRequest* request = [[BowE2EUpdateRequest alloc]
      initWithMethod:requestLine.count > 0 ? requestLine[0] : @""
              target:requestLine.count > 1 ? requestLine[1] : @""
                host:BowLoopbackHeaderValue(head, @"Host") ?: @""
                body:[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @""];
  [_requests addObject:request];
  NSData* response = [@"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nCache-Control: no-store\r\n"
                      @"Connection: close\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  dispatch_data_t data =
      dispatch_data_create(response.bytes, response.length, _queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  nw_connection_send(connection, data, NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true, ^(nw_error_t) {
    nw_connection_cancel(connection);
  });
}

- (void)stop {
  if (_stopped.exchange(true)) return;
  nw_listener_t listener = _listener;
  NSMutableArray<nw_connection_t>* connections = _connections;
  dispatch_sync(_queue, ^{
    // Connections that still arrive are refused (accept: checks _stopped); the ones open now are closed at once.
    if (listener) nw_listener_cancel(listener);
    for (nw_connection_t connection in [connections copy]) nw_connection_force_cancel(connection);
  });
  // A listener that was never created never entered the group.
  dispatch_group_wait(_cancelled, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kServerStopTimeout * NSEC_PER_SEC)));
}

@end
