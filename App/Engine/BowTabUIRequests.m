#import "BowTabUIRequests.h"

@implementation BowPopupSize

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height {
  self = [super init];
  if (self) {
    _width = width;
    _height = height;
  }
  return self;
}

@end

@implementation BowPopupRequest

- (instancetype)initWithTargetURL:(NSURL*)targetURL
                      disposition:(BowPopupDisposition)disposition
                    isUserGesture:(BOOL)isUserGesture
                    requestedSize:(BowPopupSize*)requestedSize {
  self = [super init];
  if (self) {
    _targetURL = [targetURL copy];
    _disposition = disposition;
    _isUserGesture = isUserGesture;
    _requestedSize = requestedSize;
  }
  return self;
}

@end

@implementation BowJSDialogRequest

- (instancetype)initWithKind:(BowJSDialogKind)kind
                   originURL:(NSURL*)originURL
                     message:(NSString*)message
           defaultPromptText:(NSString*)defaultPromptText
                    isReload:(BOOL)isReload {
  self = [super init];
  if (self) {
    _kind = kind;
    _originURL = [originURL copy];
    _message = [message copy];
    _defaultPromptText = [defaultPromptText copy];
    _isReload = isReload;
  }
  return self;
}

@end

@implementation BowPermissionRequest

- (instancetype)initWithRequestingOrigin:(NSURL*)requestingOrigin kinds:(BowPermissionKind)kinds {
  self = [super init];
  if (self) {
    _requestingOrigin = [requestingOrigin copy];
    _kinds = kinds;
  }
  return self;
}

@end

@implementation BowContextMenuItem

- (instancetype)initWithCommandID:(NSInteger)commandID
                            title:(NSString*)title
                        isEnabled:(BOOL)isEnabled
                        isChecked:(BOOL)isChecked
                      isSeparator:(BOOL)isSeparator
                          submenu:(NSArray<BowContextMenuItem*>*)submenu {
  self = [super init];
  if (self) {
    _commandID = commandID;
    _title = [title copy];
    _isEnabled = isEnabled;
    _isChecked = isChecked;
    _isSeparator = isSeparator;
    _submenu = [submenu copy];
  }
  return self;
}

@end

@implementation BowContextMenuRequest

- (instancetype)initWithLocation:(CGPoint)location
                         targets:(BowContextMenuTarget)targets
                       mediaType:(BowContextMenuMediaType)mediaType
                         pageURL:(NSURL*)pageURL
                        frameURL:(NSURL*)frameURL
                         linkURL:(NSURL*)linkURL
                       sourceURL:(NSURL*)sourceURL
                   selectionText:(NSString*)selectionText
                    defaultItems:(NSArray<BowContextMenuItem*>*)defaultItems {
  self = [super init];
  if (self) {
    _location = location;
    _targets = targets;
    _mediaType = mediaType;
    _pageURL = [pageURL copy];
    _frameURL = [frameURL copy];
    _linkURL = [linkURL copy];
    _sourceURL = [sourceURL copy];
    _selectionText = [selectionText copy];
    _defaultItems = [defaultItems copy];
  }
  return self;
}

@end
