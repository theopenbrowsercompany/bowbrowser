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

@implementation BowPopupWindowFeatures

- (instancetype)initWithX:(NSNumber*)x y:(NSNumber*)y width:(NSNumber*)width height:(NSNumber*)height isPopup:(BOOL)isPopup {
  self = [super init];
  if (self) {
    _x = x;
    _y = y;
    _width = width;
    _height = height;
    _isPopup = isPopup;
  }
  return self;
}

@end

@implementation BowPopupRequest

- (instancetype)initWithTargetURL:(NSURL*)targetURL
                      disposition:(BowPopupDisposition)disposition
                    isUserGesture:(BOOL)isUserGesture
                    requestedSize:(BowPopupSize*)requestedSize
                   windowFeatures:(BowPopupWindowFeatures*)windowFeatures
                   clickModifiers:(BowPopupClickModifiers)clickModifiers {
  self = [super init];
  if (self) {
    _targetURL = [targetURL copy];
    _disposition = disposition;
    _isUserGesture = isUserGesture;
    _requestedSize = requestedSize;
    _windowFeatures = windowFeatures;
    _clickModifiers = clickModifiers;
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
                      isEditable:(BOOL)isEditable
                       editFlags:(BowContextMenuEditFlags)editFlags
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
    _isEditable = isEditable;
    _editFlags = editFlags;
    _defaultItems = [defaultItems copy];
  }
  return self;
}

@end

@implementation BowKeyEvent

- (instancetype)initWithKind:(BowKeyEventKind)kind
                     keyCode:(NSInteger)keyCode
                  characters:(NSString*)characters
 charactersIgnoringModifiers:(NSString*)charactersIgnoringModifiers
                   modifiers:(BowKeyModifiers)modifiers
             inEditableField:(BOOL)inEditableField {
  self = [super init];
  if (self) {
    _kind = kind;
    _keyCode = keyCode;
    _characters = [characters copy];
    _charactersIgnoringModifiers = [charactersIgnoringModifiers copy];
    _modifiers = modifiers;
    _inEditableField = inEditableField;
  }
  return self;
}

@end

@implementation BowAuthChallenge

- (instancetype)initWithURL:(NSURL*)url
                       host:(NSString*)host
                       port:(NSInteger)port
                      realm:(NSString*)realm
                     scheme:(NSString*)scheme
                    fromProxy:(BOOL)fromProxy {
  self = [super init];
  if (self) {
    _url = [url copy];
    _host = [host copy];
    _port = port;
    _realm = [realm copy];
    _scheme = [scheme copy];
    _fromProxy = fromProxy;
  }
  return self;
}

@end

@implementation BowCertificateError

- (instancetype)initWithURL:(NSURL*)url code:(NSInteger)code {
  self = [super init];
  if (self) {
    _url = [url copy];
    _code = code;
  }
  return self;
}

@end
