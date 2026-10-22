#import "BowProfile.h"

#include "BowEngine+Internal.h"

@implementation BowProfile {
  CefRefPtr<CefRequestContext> _requestContext;
}

- (instancetype)initWithProfileID:(NSString*)profileID
                       persistent:(BOOL)persistent
                   requestContext:(CefRefPtr<CefRequestContext>)requestContext {
  self = [super init];
  if (self) {
    _profileID = [profileID copy];
    _isPersistent = persistent;
    _requestContext = requestContext;
  }
  return self;
}

- (CefRefPtr<CefRequestContext>)requestContext {
  return _requestContext;
}

- (BowTab*)createTabWithURL:(NSURL*)url {
  return [[BowTab alloc] initWithProfile:self url:url];
}

@end
