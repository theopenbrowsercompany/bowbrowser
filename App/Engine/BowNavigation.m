#import "BowNavigation.h"

@implementation BowNavigation

- (instancetype)initWithURL:(NSURL*)url
                 transition:(BowNavigationTransition)transition
              isUserGesture:(BOOL)isUserGesture
                 isRedirect:(BOOL)isRedirect {
  self = [super init];
  if (self) {
    _url = [url copy];
    _transition = transition;
    _isUserGesture = isUserGesture;
    _isRedirect = isRedirect;
  }
  return self;
}

- (instancetype)initWithURL:(NSURL*)url transition:(BowNavigationTransition)transition isUserGesture:(BOOL)isUserGesture {
  return [self initWithURL:url transition:transition isUserGesture:isUserGesture isRedirect:NO];
}

@end

@implementation BowNavigationError

- (instancetype)initWithCode:(NSInteger)code errorText:(NSString*)errorText {
  self = [super init];
  if (self) {
    _code = code;
    _errorText = [errorText copy];
  }
  return self;
}

- (NSString*)description {
  return [NSString stringWithFormat:@"<BowNavigationError %ld %@>", (long)_code, _errorText];
}

@end
