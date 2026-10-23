#import "BowLoopbackFixtures.h"
#import "BowLoopbackFixtures+Identity.h"

#import <Network/Network.h>
#import <Security/Security.h>

#include <atomic>

namespace {

// The certificate listener's identity: a self-signed RSA 2048 certificate for badcert.bow.test (subject alternative
// name too), valid until 2126, with its key, as PKCS#12 protected by kIdentityPassword. A test fixture only: nothing
// trusts it, and that is the point. Made with LibreSSL's openssl:
//   openssl req -x509 -newkey rsa:2048 -nodes -days 36500 -sha256 -subj "/CN=badcert.bow.test/O=Bow e2e fixture"
//     -addext "subjectAltName=DNS:badcert.bow.test" (plus serverAuth key usage) -keyout key.pem -out cert.pem
//   openssl pkcs12 -export -inkey key.pem -in cert.pem -passout pass:bow-e2e | base64
NSString* const kIdentityPKCS12 =
    @"MIIJ4gIBAzCCCagGCSqGSIb3DQEHAaCCCZkEggmVMIIJkTCCBBcGCSqGSIb3DQEHBqCCBAgwggQEAgEAMIID/QYJKoZIhvcNAQcBMBwGCiqG"
    @"SIb3DQEMAQYwDgQIUCLUD7anCbICAggAgIID0AamFcogUGTydj3G2/1IY9GCa1jih2GxQAFyNx1wlmcARwfrLpzxmySQm1FuCDz5Qy4t0SB2"
    @"Phl3xWyhLAuLH8w+AU32wf5WaBPg/CkK2I/hKr3928qaYvLQWiyYXwHPKR1nz5J6JIqKj5FnV5X8GLWhsyyMRoNZtuOKa2MM+hxnBamkzpI2"
    @"cfvk3SN1MCDJ4fgmkXPEKgVRVJoiKaXpGkn924+vjVDpHojDYHyHtrisJhSzTbVySx8/NpsI16WPatSCGFpGTbyGeTd/xhCOKdkHm6NLD4v8"
    @"QLgqRWU7qZeFMRWkFlKmQVTpH+bXzvTLV4GttR70bSFyws6ybMzi7/Z67TP9FM4dpWm1rvN9BTRAm06nR28UeKoqRuen/bNKFff05ckP3fT8"
    @"s13INx2aK4t/LfIwUeJZf2V+Fxtyj8x+Wbji1IKOEnpN0PtdSdH4WtcMLdCEQWNU85ZkBnczYXS4tOgGNUKZrL81PQWNJY5gBkP0//kviGKo"
    @"qsDLU0o5yLaF631IcWOBQN7Bb08UZGzEHmMCvJukhKGOgKE0THswf+h2ROioTG6c0Dr7VFiku5UUpdM9xrX5ifBNnWu5kH//KpNDvxh7d1Np"
    @"Q4RxKYVnb1fZHECOhoRm7Ln7ZG9Hew3wICvjJaf+AyfcaBgKUihCcJoV/3Mj8y6tYdnnGTmlkPwvkdOdEAMQQjVkavyvUyat58y4msopv258"
    @"CJ3tyQZQwNse2939KpwOjLiZCj/dSmcfOpZyoKGeLoEDSy+kPFnZwG85uO4aXB3gMwWzO96EnC1mgjobecdDk5Akf/6cezNw3yoOHY1PpwvD"
    @"q4GOQpbRpEI12tNjkUjzZTcPXQ7rcNmuUCH3lO4maH9d/u92wK5mXM5zITHQ6RnOjjFlJsXH3+C1n+ieS7xEcvlbnOu13+9atIb1inxOZUfC"
    @"SqqvgQt/bvHV5wAx3r2PzQX+kJFIuEk53ZZjwIlQLAuYIr84FBT8zF8F0DJu5LEIBZY8cSEcLo01Xf5Y2EdgtDl67xMQp5k4Zs/rYGK2iUuW"
    @"bidqQ6uEFuR5K44yOImnBxEDNWqXrodxZaZkGbl1jPi1t7xOuIyy40bH73nLEGkqyw7U50NHjSuReRRMdSMlhQsk2hb8U23+dQB4G1XlNHne"
    @"R5T6JhA2xEDHxVnTFqN7DK3TyLxblFlpR0Y/Z3Y4Jb5H02sNWWcf3BvnNfsiJP+cVfj1d+xMeuDtvSzecZfkLTPJfeSjBDjHgm0bAu0Yr/a2"
    @"zpmLx3+pUy3IVu6rpXPVuzxQUE+5VEc1UR+8P6ou3KMwggVyBgkqhkiG9w0BBwGgggVjBIIFXzCCBVswggVXBgsqhkiG9w0BDAoBAqCCBO4w"
    @"ggTqMBwGCiqGSIb3DQEMAQMwDgQIVqddf2BPPeECAggABIIEyBVwI72TUBs+k1koZgO3MzRZRbQYh/UzyheuicgCKqP1xvnhiuJKcHdql1hc"
    @"vCasLYxct5fSrmREo6OYZzb3cWe3FzNAZGg/Y58aMKbFAaZMFs49yP1dDstLY81B2lkuKRDR8cHjB/nT8GkhwEx/EXT8A8zn18bNCdUAYUKh"
    @"4XFOLwQ6C2lhxoTL4H7PTX0DW1xYxvYEcxkJHl9b4j5SnZiOsfHtKiLTztR4Ge0mwhlzXQdPXBeqHY1uWzvVpB+wKgTbuQWcUCZPsoVk3fuZ"
    @"jAC6TSdCelA1/P8oao+ZvtdbR09ROvWy+S9yCHTDLd1HmfknKf0CuynR2/oUSmzpi9Kj/O5to5ZrCCtPDO9D1I+tDxgizJ/vplYNoD/J+HSE"
    @"EGkZUPlQuGItxsZg6GxIUQr8YTU6v9Z83whyAXINJlswoveSs/F32i8lsA4pyvPlT/f8fZHq/mIV6/PQ5dxXEgj4BJ9G/BlAC11Y4nS56EGt"
    @"l/n2S6rNtXcADSyf20ovOSsQjtPxulQOiPeGsPoyo6TZj4TJqNkjkdHaRvuVwvKejAEGCk6RMuVOB++qNkFfPdhOkyhTD4DxZf9sglofnbNB"
    @"ZsO5vOM7rE3HY08/K64s1Zs5RdzdEiqKUjpI2+INK5EjMygMjE2KgghdDD2Li77wlDgy+sNXDTrvXlWecsXuV1YAOxBUPIQkpvOns95/MEu4"
    @"oyNFOSm1kZOJJXId4b7XmEZWC0dkqdmb5vulswbUDgBmxPKRncNpMoJIGQGre8Zdzf/JdcC1uvCQgro1vxEDRWd7xkhO00yGHPp5mRYPkjma"
    @"jybmBWGNVa4NG5I42DMfDQEbgouCvskVaVXlJe5sIzRuoOIbD+KerwPLETRpvbgT+9LxlJIKz1B5ojrupwh8a3GfmnKoUXvP1zpnP/Er4HGS"
    @"Xt1OnQuHbaQbdgyF1+anTGUJMTYppZ699wuyvRbP9fWwd79+Kk+Ll+0BGVtylY2Ix47ob75b2rSQne1RIMYqTH6xAuym/LNTCGxfWu9RW7N1"
    @"ol3GfxA/KXDh9LURrI29sz6AU2ZR2VXg12bcGKzs2u0t3y2oNI8C/KbvGQYQpo5Biza81y8tX9tzrZVXP21CJ1mvkfSqrppZ+YKpIgC6CTs1"
    @"ByPDQ639NfP1P6m11+B1zGWrqj4I8Jl4GvBqXnrV605Noonolxn7VSIeX7BmO8RscORx4WyfLDZPhyTCIagcFoZNXIKrI6AS0fMC5u3HaBiL"
    @"GOfElKK8cna5yfkosFlNBbI5FnOXHeFeOnCCgMUXGc4ef82HQ0O0VXi7L9p3pTiM/Y2/F+c3vt9pAjiSauopRV5NZbg+CLf6gKGIuwZE5ORn"
    @"qMcUSzQyCaXAAy28lhu0h/ND3ks02fySiHIAs9IIKGJgPSdnBYWuDORjzsEzituYeumAH36WoyK32ka+IbvJInm4EZMV1c6PBr5uppfPBgku"
    @"kUC5w3RlECx96RDc53Me6LeXwRYLZEB0EgG7Dc7fjXwLHSOcCVwMbsrA+CdaMRp/gzSJ4pKuO6dUibkLM2w3mh+rNBovzg7xEnrXXgCOEMEj"
    @"L382+0lX7ZRwf2i1Fmi41hoAOnvGg0J28x3k6j26FpqOJo6fDU/LQ4qVvCHCYjFWMCMGCSqGSIb3DQEJFTEWBBTTpdmGvK9+rK7P1Z32Gpkh"
    @"9IKTJzAvBgkqhkiG9w0BCRQxIh4gAGIAYQBkAGMAZQByAHQALgBiAG8AdwAuAHQAZQBzAHQwMTAhMAkGBSsOAwIaBQAEFA4XoqrGggJ0HLee"
    @"qK7YUXlC20WYBAhoAXCjxgFMJwICCAA=";
NSString* const kIdentityPassword = @"bow-e2e";

NSString* const kAuthUser = @"bow";
NSString* const kAuthPassword = @"bow-e2e-password";

const NSTimeInterval kStartTimeout = 5;
const NSTimeInterval kStopTimeout = 3;
// A request's head larger than this is refused (the fixtures' requests are a few hundred bytes).
const NSUInteger kMaxHead = 64 * 1024;

NSError* FixtureError(NSString* message) {
  return [NSError errorWithDomain:@"BowLoopbackFixtures" code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}

NSString* Describe(nw_error_t error) {
  if (!error) return @"unknown error";
  CFErrorRef cfError = nw_error_copy_cf_error(error);
  NSString* text = [(__bridge NSError*)cfError localizedDescription] ?: @"unknown error";
  if (cfError) CFRelease(cfError);
  return text;
}

// The identity from kIdentityPKCS12, imported into process memory only (kSecImportToMemoryOnly, macOS 15 and
// later), never into a keychain.
sec_identity_t MakeIdentity(NSError** error) {
  if (@available(macOS 15.0, *)) {
    NSData* data = [[NSData alloc] initWithBase64EncodedString:kIdentityPKCS12
                                                       options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!data) {
      if (error) *error = FixtureError(@"the fixture identity is not valid base64");
      return nil;
    }
    NSDictionary* options = @{
      (__bridge id)kSecImportExportPassphrase : kIdentityPassword,
      (__bridge id)kSecImportToMemoryOnly : @YES,
    };
    CFArrayRef items = NULL;
    OSStatus status = SecPKCS12Import((__bridge CFDataRef)data, (__bridge CFDictionaryRef)options, &items);
    NSArray* imported = CFBridgingRelease(items);
    if (status != errSecSuccess || imported.count == 0) {
      NSString* message = [NSString stringWithFormat:@"importing the fixture identity failed (%d)", (int)status];
      if (error) *error = FixtureError(message);
      return nil;
    }
    SecIdentityRef identity = (__bridge SecIdentityRef)imported[0][(__bridge id)kSecImportItemIdentity];
    if (!identity) {
      if (error) *error = FixtureError(@"the fixture PKCS#12 holds no identity");
      return nil;
    }
    return sec_identity_create(identity);
  }
  if (error) *error = FixtureError(@"the certificate fixture needs macOS 15 to keep its identity out of keychains");
  return nil;
}

// TCP parameters bound to 127.0.0.1 on a port the system picks, loopback only.
void BindToLoopback(nw_parameters_t parameters) {
  nw_parameters_set_local_endpoint(parameters, nw_endpoint_create_host("127.0.0.1", "0"));
  nw_parameters_set_required_interface_type(parameters, nw_interface_type_loopback);
}

NSData* Response(NSInteger status, NSString* reason, NSArray<NSString*>* extraHeaders, NSString* title) {
  NSString* body = [NSString
      stringWithFormat:@"<!doctype html><html><head><meta charset=\"utf-8\"><title>%@</title></head><body><h1>%@</h1>"
                       @"</body></html>",
                       title, title];
  NSData* bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
  NSMutableString* head = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n", (long)status, reason];
  for (NSString* header in extraHeaders) [head appendFormat:@"%@\r\n", header];
  [head appendFormat:@"Content-Type: text/html; charset=utf-8\r\nContent-Length: %lu\r\nCache-Control: no-store\r\n"
                     @"Connection: close\r\n\r\n",
                     (unsigned long)bodyData.length];
  NSMutableData* data = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  [data appendData:bodyData];
  return data;
}

// The realm the sign in listener names for `path`: `<name>` for a path under `/realm/<name>/` whose name is letters
// and digits only, else "bow". Each test signs in to a realm of its own, since the engine remembers a realm's
// credentials for the session and would answer a second question for it without asking.
NSString* RealmForPath(NSString* path) {
  NSArray<NSString*>* parts = [path componentsSeparatedByString:@"/"];
  if (parts.count < 4 || ![parts[1] isEqualToString:@"realm"] || parts[2].length == 0) return @"bow";
  NSCharacterSet* allowed = [NSCharacterSet alphanumericCharacterSet];
  if ([parts[2] rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return @"bow";
  return parts[2];
}

// The value of the request head's header `name` (compared ignoring case), or nil.
NSString* HeaderValue(NSString* head, NSString* name) {
  for (NSString* line in [head componentsSeparatedByString:@"\r\n"]) {
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) continue;
    NSString* key = [line substringToIndex:colon.location];
    if ([key caseInsensitiveCompare:name] != NSOrderedSame) continue;
    return [[line substringFromIndex:colon.location + 1]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  }
  return nil;
}

enum class Listener { auth, certificate };

}  // namespace

sec_identity_t BowLoopbackFixtureIdentity(NSError** error) {
  return MakeIdentity(error);
}

@implementation BowLoopbackFixtures {
  // Every listener and connection callback runs here.
  dispatch_queue_t _queue;
  nw_listener_t _authListener;
  nw_listener_t _certificateListener;
  // Open connections, touched on _queue only.
  NSMutableArray<nw_connection_t>* _connections;
  // Left once per listener when it reaches the cancelled state, so stop can wait for both sockets to close.
  dispatch_group_t _cancelled;
  NSString* _expectedAuthorization;
  std::atomic<NSInteger> _unauthorized;
  std::atomic<NSInteger> _authorized;
  std::atomic<NSInteger> _certificate;
  std::atomic<bool> _stopped;
  NSString* _certificateFailure;
}

@synthesize certificateFailure = _certificateFailure;

+ (NSString*)authUser {
  return kAuthUser;
}

+ (NSString*)authPassword {
  return kAuthPassword;
}

+ (instancetype)startWithError:(NSError**)error {
  BowLoopbackFixtures* fixtures = [[BowLoopbackFixtures alloc] initPrivate];
  NSError* startError = nil;
  if (![fixtures startAuth:&startError]) {
    [fixtures stop];
    if (error) *error = startError;
    return nil;
  }
  // The certificate listener is optional: without it the sign in fixture still serves.
  if (![fixtures startCertificate:&startError]) {
    fixtures->_certificateFailure = startError.localizedDescription ?: @"unknown error";
  }
  return fixtures;
}

- (instancetype)initPrivate {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("bow.e2e.loopback-fixtures", DISPATCH_QUEUE_SERIAL);
    _connections = [NSMutableArray array];
    _cancelled = dispatch_group_create();
    NSString* pair = [NSString stringWithFormat:@"%@:%@", kAuthUser, kAuthPassword];
    NSString* encoded = [[pair dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    _expectedAuthorization = [@"Basic " stringByAppendingString:encoded];
  }
  return self;
}

// The runner always calls stop first. Without it, still close the sockets, but never wait on _queue here: the last
// reference can go on _queue itself, from a callback that held it.
- (void)dealloc {
  if (_stopped.exchange(true)) return;
  if (_authListener) nw_listener_cancel(_authListener);
  if (_certificateListener) nw_listener_cancel(_certificateListener);
  NSMutableArray<nw_connection_t>* connections = _connections;
  dispatch_async(_queue, ^{
    for (nw_connection_t connection in [connections copy]) nw_connection_force_cancel(connection);
  });
}

- (NSInteger)unauthorizedRequests {
  return _unauthorized.load();
}

- (NSInteger)authorizedRequests {
  return _authorized.load();
}

- (NSInteger)certificateRequests {
  return _certificate.load();
}

- (BOOL)startAuth:(NSError**)error {
  nw_parameters_t plain = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                          NW_PARAMETERS_DEFAULT_CONFIGURATION);
  BindToLoopback(plain);
  uint16_t port = 0;
  _authListener = [self listenerWith:plain kind:Listener::auth port:&port error:error];
  _authPort = port;
  return _authListener != nil;
}

- (BOOL)startCertificate:(NSError**)error {
  sec_identity_t identity = MakeIdentity(error);
  if (!identity) return NO;
  nw_parameters_t secure = nw_parameters_create_secure_tcp(
      ^(nw_protocol_options_t tlsOptions) {
        sec_protocol_options_t options = nw_tls_copy_sec_protocol_options(tlsOptions);
        sec_protocol_options_set_local_identity(options, identity);
        // HTTP/1.1 only: this server does not speak HTTP/2.
        sec_protocol_options_add_tls_application_protocol(options, "http/1.1");
      },
      NW_PARAMETERS_DEFAULT_CONFIGURATION);
  BindToLoopback(secure);
  uint16_t port = 0;
  _certificateListener = [self listenerWith:secure kind:Listener::certificate port:&port error:error];
  _certificatePort = port;
  return _certificateListener != nil;
}

// Starts a listener and waits until it is ready or failed. Returns it with its port, or nil (cancelled) and an error.
- (nw_listener_t)listenerWith:(nw_parameters_t)parameters
                         kind:(Listener)kind
                         port:(uint16_t*)port
                        error:(NSError**)error {
  nw_listener_t listener = nw_listener_create(parameters);
  if (!listener) {
    if (error) *error = FixtureError(@"cannot create a loopback listener");
    return nil;
  }
  NSString* name = kind == Listener::auth ? @"sign in" : @"certificate";
  dispatch_semaphore_t settled = dispatch_semaphore_create(0);
  __block nw_error_t failure = nil;
  __block bool ready = false;
  __block bool signalled = false;
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
  __weak BowLoopbackFixtures* weakSelf = self;
  nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
    BowLoopbackFixtures* fixtures = weakSelf;
    if (fixtures) {
      [fixtures accept:connection kind:kind];
    } else {
      nw_connection_cancel(connection);
    }
  });
  nw_listener_start(listener);
  long waited =
      dispatch_semaphore_wait(settled, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStartTimeout * NSEC_PER_SEC)));
  __block bool isReady = false;
  __block NSString* reason = nil;
  dispatch_sync(_queue, ^{
    isReady = ready;
    if (!ready) reason = waited != 0 ? @"it did not start in time" : Describe(failure);
  });
  if (!isReady) {
    nw_listener_cancel(listener);
    if (error) *error = FixtureError([NSString stringWithFormat:@"the %@ listener could not start: %@", name, reason]);
    return nil;
  }
  *port = nw_listener_get_port(listener);
  return listener;
}

- (void)accept:(nw_connection_t)connection kind:(Listener)kind {
  if (_stopped.load()) {
    nw_connection_cancel(connection);
    return;
  }
  [_connections addObject:connection];
  __weak BowLoopbackFixtures* weakSelf = self;
  nw_connection_set_queue(connection, _queue);
  nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
    if (state == nw_connection_state_failed) nw_connection_cancel(connection);
    BowLoopbackFixtures* fixtures = weakSelf;
    if (fixtures && state == nw_connection_state_cancelled) [fixtures->_connections removeObject:connection];
  });
  nw_connection_start(connection);
  [self receiveOn:connection kind:kind head:[NSMutableData data]];
}

// Reads until the request head is complete, then answers it.
- (void)receiveOn:(nw_connection_t)connection kind:(Listener)kind head:(NSMutableData*)head {
  __weak BowLoopbackFixtures* weakSelf = self;
  nw_connection_receive(connection, 1, (uint32_t)kMaxHead,
                        ^(dispatch_data_t content, nw_content_context_t context, bool isComplete, nw_error_t error) {
                          BowLoopbackFixtures* fixtures = weakSelf;
                          if (!fixtures) {
                            nw_connection_cancel(connection);
                            return;
                          }
                          if (content) {
                            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset,
                                                               const void* buffer, size_t size) {
                              [head appendBytes:buffer length:size];
                              return true;
                            });
                          }
                          NSData* end = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
                          NSRange found = [head rangeOfData:end options:0 range:NSMakeRange(0, head.length)];
                          if (found.location != NSNotFound) {
                            NSData* headData = [head subdataWithRange:NSMakeRange(0, found.location)];
                            [fixtures answer:connection
                                        kind:kind
                                        head:[[NSString alloc] initWithData:headData encoding:NSUTF8StringEncoding]];
                            return;
                          }
                          if (error || isComplete || head.length > kMaxHead) {
                            nw_connection_cancel(connection);
                            return;
                          }
                          [fixtures receiveOn:connection kind:kind head:head];
                        });
}

- (void)answer:(nw_connection_t)connection kind:(Listener)kind head:(NSString*)head {
  NSData* response;
  NSArray<NSString*>* requestLine = [[head componentsSeparatedByString:@"\r\n"].firstObject
      componentsSeparatedByString:@" "];
  NSString* path = requestLine.count > 1 ? requestLine[1] : @"/";
  if ([path isEqualToString:@"/favicon.ico"]) {
    // The browser's own icon request: never a second sign in question for the page.
    response = Response(404, @"Not Found", @[], @"Not found");
  } else if (kind == Listener::certificate) {
    _certificate++;
    response = Response(200, @"OK", @[], @"Bad certificate");
  } else if ([HeaderValue(head ?: @"", @"Authorization") isEqualToString:_expectedAuthorization]) {
    _authorized++;
    response = Response(200, @"OK", @[], @"Signed in");
  } else {
    _unauthorized++;
    NSString* challenge = [NSString stringWithFormat:@"WWW-Authenticate: Basic realm=\"%@\"", RealmForPath(path)];
    response = Response(401, @"Unauthorized", @[ challenge ], @"Sign in required");
  }
  dispatch_data_t data =
      dispatch_data_create(response.bytes, response.length, _queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  nw_connection_send(connection, data, NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
    nw_connection_cancel(connection);
  });
}

- (void)stop {
  if (_stopped.exchange(true)) return;
  NSMutableArray<nw_listener_t>* listeners = [NSMutableArray array];
  if (_authListener) [listeners addObject:_authListener];
  if (_certificateListener) [listeners addObject:_certificateListener];
  NSMutableArray<nw_connection_t>* connections = _connections;
  dispatch_sync(_queue, ^{
    // Connections that still arrive are refused (accept: checks _stopped); the ones open now are closed at once.
    for (nw_listener_t listener in listeners) nw_listener_cancel(listener);
    for (nw_connection_t connection in [connections copy]) nw_connection_force_cancel(connection);
  });
  // Both listeners left the group when they reached cancelled (or never entered it). A listener whose creation
  // failed was cancelled already.
  dispatch_group_wait(_cancelled, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStopTimeout * NSEC_PER_SEC)));
}

@end
