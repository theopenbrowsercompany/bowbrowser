// Values a tab hands its UI delegate: popups, JavaScript dialogs, permission prompts, context menus and render
// process exits. Swift visible: plain Objective-C only, never C++ or CEF. Where BowCore's engine contract has the
// same value (PopupRequest, PopupDisposition, PopupSize, ProcessGoneReason) the names and values mirror it.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark Popups

/// Where a page asked a new page to open. Mirrors BowCore's `PopupDisposition`.
typedef NS_CLOSED_ENUM(NSInteger, BowPopupDisposition) {
  BowPopupDispositionForegroundTab,
  BowPopupDispositionBackgroundTab,
  /// A sized popup window, such as an OAuth sign in.
  BowPopupDispositionPopup,
  BowPopupDispositionWindow,
} NS_SWIFT_NAME(BowPopupRequest.Disposition);

/// A window size in points that a page asked for when opening a popup. Immutable. Mirrors BowCore's `PopupSize`.
NS_SWIFT_SENDABLE
__attribute__((objc_subclassing_restricted))
@interface BowPopupSize : NSObject

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property(nonatomic, readonly) NSInteger width;
@property(nonatomic, readonly) NSInteger height;

@end

/// Where the app wants a new page the page opened to go. Mirrors BowCore's `PopupDecision`.
typedef NS_CLOSED_ENUM(NSInteger, BowPopupDecision) {
  /// A new tab, shown at once, handed to the UI delegate's `tab(_:didOpenPopup:request:)`.
  BowPopupDecisionForegroundTab,
  /// A new tab left in the background, handed over the same way.
  BowPopupDecisionBackgroundTab,
  /// A separate window the engine opens itself (the default).
  BowPopupDecisionWindow,
  /// Nothing opens.
  BowPopupDecisionBlock,
} NS_SWIFT_NAME(BowPopupRequest.Decision);

/// The window features a page passed to `window.open`; each number is nil when the page did not set it. Immutable.
/// Mirrors BowCore's `PopupWindowFeatures`.
NS_SWIFT_SENDABLE
__attribute__((objc_subclassing_restricted))
@interface BowPopupWindowFeatures : NSObject

- (instancetype)initWithX:(nullable NSNumber *)x
                        y:(nullable NSNumber *)y
                    width:(nullable NSNumber *)width
                   height:(nullable NSNumber *)height
                  isPopup:(BOOL)isPopup NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property(nonatomic, readonly, nullable) NSNumber *x;
@property(nonatomic, readonly, nullable) NSNumber *y;
@property(nonatomic, readonly, nullable) NSNumber *width;
@property(nonatomic, readonly, nullable) NSNumber *height;
@property(nonatomic, readonly) BOOL isPopup;

@end

/// The modifier keys held at the click that opened a new page. Mirrors BowCore's `PopupClickModifiers`.
typedef NS_OPTIONS(NSUInteger, BowPopupClickModifiers) {
  BowPopupClickModifierCommand = 1 << 0,
  BowPopupClickModifierShift = 1 << 1,
} NS_SWIFT_NAME(BowPopupRequest.ClickModifiers);

/// A page asked to open a new tab or window. Immutable. Mirrors BowCore's `PopupRequest`.
NS_SWIFT_SENDABLE
__attribute__((objc_subclassing_restricted))
@interface BowPopupRequest : NSObject

- (instancetype)initWithTargetURL:(nullable NSURL *)targetURL
                      disposition:(BowPopupDisposition)disposition
                    isUserGesture:(BOOL)isUserGesture
                    requestedSize:(nullable BowPopupSize *)requestedSize
                   windowFeatures:(BowPopupWindowFeatures *)windowFeatures
                   clickModifiers:(BowPopupClickModifiers)clickModifiers NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// The URL the page asked to open, or nil for a blank popup (for example `window.open()` with no URL).
@property(nonatomic, readonly, copy, nullable) NSURL *targetURL;
@property(nonatomic, readonly) BowPopupDisposition disposition;
@property(nonatomic, readonly) BOOL isUserGesture;
/// The size the page asked for, when it asked for one.
@property(nonatomic, readonly, nullable) BowPopupSize *requestedSize;
@property(nonatomic, readonly) BowPopupWindowFeatures *windowFeatures;
/// The modifiers held at the click, as far as the engine can tell (see BowTabLifeSpan.mm); empty without a click.
@property(nonatomic, readonly) BowPopupClickModifiers clickModifiers;

@end

#pragma mark JavaScript dialogs

/// Which JavaScript dialog a page asked for.
typedef NS_CLOSED_ENUM(NSInteger, BowJSDialogKind) {
  BowJSDialogKindAlert,
  BowJSDialogKindConfirm,
  BowJSDialogKindPrompt,
  /// The "leave this page?" question from a page's beforeunload handler.
  BowJSDialogKindBeforeUnload,
} NS_SWIFT_NAME(BowJSDialogRequest.Kind);

/// A page asked to show a JavaScript dialog. Immutable.
NS_SWIFT_SENDABLE
__attribute__((objc_subclassing_restricted))
@interface BowJSDialogRequest : NSObject

- (instancetype)initWithKind:(BowJSDialogKind)kind
                   originURL:(nullable NSURL *)originURL
                     message:(NSString *)message
           defaultPromptText:(NSString *)defaultPromptText
                    isReload:(BOOL)isReload NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property(nonatomic, readonly) BowJSDialogKind kind;
/// The origin of the frame that asked, or nil when the engine does not report one (beforeunload dialogs).
@property(nonatomic, readonly, copy, nullable) NSURL *originURL;
@property(nonatomic, readonly, copy) NSString *message;
/// The prompt field's starting text; empty unless `kind` is prompt.
@property(nonatomic, readonly, copy) NSString *defaultPromptText;
/// For a beforeunload dialog, YES when the page is being reloaded rather than left.
@property(nonatomic, readonly) BOOL isReload;

@end

#pragma mark Permissions

/// What a page asked to use. A single request can ask for several at once (camera and microphone together).
typedef NS_OPTIONS(NSUInteger, BowPermissionKind) {
  BowPermissionKindCamera = 1 << 0,
  BowPermissionKindMicrophone = 1 << 1,
  /// Capturing the screen, a window or the system's audio.
  BowPermissionKindScreenCapture = 1 << 2,
  BowPermissionKindGeolocation = 1 << 3,
  BowPermissionKindNotifications = 1 << 4,
  BowPermissionKindClipboard = 1 << 5,
  BowPermissionKindMIDISysex = 1 << 6,
  BowPermissionKindStorageAccess = 1 << 7,
  BowPermissionKindWindowManagement = 1 << 8,
  BowPermissionKindLocalFonts = 1 << 9,
  /// Anything the bridge has no kind for yet.
  BowPermissionKindOther = 1 << 15,
} NS_SWIFT_NAME(BowPermissionRequest.Kind);

/// The answer to a permission request.
typedef NS_CLOSED_ENUM(NSInteger, BowPermissionDecision) {
  /// Grant every kind in the request.
  BowPermissionDecisionAllow,
  BowPermissionDecisionDeny,
  /// The person closed the prompt without answering; the page may ask again later.
  BowPermissionDecisionDismiss,
} NS_SWIFT_NAME(BowPermissionRequest.Decision);

/// A page asked to use something that needs the person's permission. Immutable.
NS_SWIFT_SENDABLE
__attribute__((objc_subclassing_restricted))
@interface BowPermissionRequest : NSObject

- (instancetype)initWithRequestingOrigin:(nullable NSURL *)requestingOrigin
                                   kinds:(BowPermissionKind)kinds NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// The origin asking, or nil when it cannot be parsed as a URL.
@property(nonatomic, readonly, copy, nullable) NSURL *requestingOrigin;
@property(nonatomic, readonly) BowPermissionKind kinds;

@end

#pragma mark Context menus

/// What the person right clicked on. Several can be set at once (a link that is also an image).
typedef NS_OPTIONS(NSUInteger, BowContextMenuTarget) {
  BowContextMenuTargetPage = 1 << 0,
  BowContextMenuTargetFrame = 1 << 1,
  BowContextMenuTargetLink = 1 << 2,
  BowContextMenuTargetMedia = 1 << 3,
  BowContextMenuTargetSelection = 1 << 4,
  BowContextMenuTargetEditable = 1 << 5,
} NS_SWIFT_NAME(BowContextMenuRequest.Target);

/// The kind of media under the pointer, when there is any.
typedef NS_CLOSED_ENUM(NSInteger, BowContextMenuMediaType) {
  BowContextMenuMediaTypeNone,
  BowContextMenuMediaTypeImage,
  BowContextMenuMediaTypeVideo,
  BowContextMenuMediaTypeAudio,
  BowContextMenuMediaTypeCanvas,
  BowContextMenuMediaTypeFile,
  BowContextMenuMediaTypePlugin,
} NS_SWIFT_NAME(BowContextMenuRequest.MediaType);

/// The command ID that answers a context menu request without running any engine command.
static const NSInteger BowContextMenuNoCommand NS_SWIFT_NAME(BowContextMenuRequest.noCommand) = -1;

/// The engine's editing commands, as command IDs to answer a context menu request with. They run in the frame the
/// menu was asked in, whether or not the engine's default menu listed them.
typedef NS_ENUM(NSInteger, BowContextMenuCommand) {
  BowContextMenuCommandUndo = 110,
  BowContextMenuCommandRedo = 111,
  BowContextMenuCommandCut = 112,
  BowContextMenuCommandCopy = 113,
  BowContextMenuCommandPaste = 114,
  BowContextMenuCommandSelectAll = 117,
} NS_SWIFT_NAME(BowContextMenuRequest.Command);

/// What an editable field under the pointer can do now.
typedef NS_OPTIONS(NSUInteger, BowContextMenuEditFlags) {
  BowContextMenuEditFlagsCanUndo = 1 << 0,
  BowContextMenuEditFlagsCanRedo = 1 << 1,
  BowContextMenuEditFlagsCanCut = 1 << 2,
  BowContextMenuEditFlagsCanCopy = 1 << 3,
  BowContextMenuEditFlagsCanPaste = 1 << 4,
  BowContextMenuEditFlagsCanDelete = 1 << 5,
  BowContextMenuEditFlagsCanSelectAll = 1 << 6,
} NS_SWIFT_NAME(BowContextMenuRequest.EditFlags);

/// One item of the engine's default context menu. Immutable.
NS_SWIFT_SENDABLE
__attribute__((objc_subclassing_restricted))
@interface BowContextMenuItem : NSObject

- (instancetype)initWithCommandID:(NSInteger)commandID
                            title:(NSString *)title
                        isEnabled:(BOOL)isEnabled
                        isChecked:(BOOL)isChecked
                      isSeparator:(BOOL)isSeparator
                          submenu:(NSArray<BowContextMenuItem *> *)submenu NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// The engine command this item runs when chosen. Meaningless for separators and submenus.
@property(nonatomic, readonly) NSInteger commandID;
/// The item's title, with any keyboard mnemonic markers removed.
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly) BOOL isEnabled;
@property(nonatomic, readonly) BOOL isChecked;
@property(nonatomic, readonly) BOOL isSeparator;
/// The items of this item's submenu, empty when it has none.
@property(nonatomic, readonly, copy) NSArray<BowContextMenuItem *> *submenu;

@end

/// The person asked for a context menu in a page. Immutable.
NS_SWIFT_SENDABLE
__attribute__((objc_subclassing_restricted))
@interface BowContextMenuRequest : NSObject

- (instancetype)initWithLocation:(CGPoint)location
                         targets:(BowContextMenuTarget)targets
                       mediaType:(BowContextMenuMediaType)mediaType
                         pageURL:(nullable NSURL *)pageURL
                        frameURL:(nullable NSURL *)frameURL
                         linkURL:(nullable NSURL *)linkURL
                       sourceURL:(nullable NSURL *)sourceURL
                   selectionText:(NSString *)selectionText
                      isEditable:(BOOL)isEditable
                       editFlags:(BowContextMenuEditFlags)editFlags
                    defaultItems:(NSArray<BowContextMenuItem *> *)defaultItems NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Where the menu was asked for, in points from the top left of the view showing the tab.
@property(nonatomic, readonly) CGPoint location;
@property(nonatomic, readonly) BowContextMenuTarget targets;
@property(nonatomic, readonly) BowContextMenuMediaType mediaType;
@property(nonatomic, readonly, copy, nullable) NSURL *pageURL;
@property(nonatomic, readonly, copy, nullable) NSURL *frameURL;
/// The link under the pointer, when `targets` contains link.
@property(nonatomic, readonly, copy, nullable) NSURL *linkURL;
/// The source of the image, video or audio under the pointer, when `targets` contains media.
@property(nonatomic, readonly, copy, nullable) NSURL *sourceURL;
/// The selected text, empty when nothing is selected.
@property(nonatomic, readonly, copy) NSString *selectionText;
/// YES when the pointer is over a field the person can type in; `editFlags` then says what it can do.
@property(nonatomic, readonly) BOOL isEditable;
@property(nonatomic, readonly) BowContextMenuEditFlags editFlags;
/// The menu the engine would show by default, so the app can reuse its items and command IDs.
@property(nonatomic, readonly, copy) NSArray<BowContextMenuItem *> *defaultItems;

@end

#pragma mark Render process exits

/// Why a tab's render process ended. Mirrors BowCore's `ProcessGoneReason`.
typedef NS_CLOSED_ENUM(NSInteger, BowProcessGoneReason) {
  BowProcessGoneReasonCrashed,
  BowProcessGoneReasonKilled,
  BowProcessGoneReasonOutOfMemory,
  BowProcessGoneReasonLaunchFailed,
  BowProcessGoneReasonOther,
};

#pragma mark Keys before the page

/// Which key event is on its way to the page. Mirrors BowCore's `EngineKeyEvent.Kind`.
typedef NS_CLOSED_ENUM(NSInteger, BowKeyEventKind) {
  BowKeyEventKindKeyDown,
  BowKeyEventKindKeyUp,
  BowKeyEventKindCharacter,
} NS_SWIFT_NAME(BowKeyEvent.Kind);

/// Modifier keys held during a key event. Mirrors BowCore's `KeyModifiers`.
typedef NS_OPTIONS(NSUInteger, BowKeyModifiers) {
  BowKeyModifierShift = 1 << 0,
  BowKeyModifierControl = 1 << 1,
  BowKeyModifierOption = 1 << 2,
  BowKeyModifierCommand = 1 << 3,
} NS_SWIFT_NAME(BowKeyEvent.Modifiers);

/// A key event on its way to the page. Immutable. Mirrors BowCore's `EngineKeyEvent`.
NS_SWIFT_SENDABLE
__attribute__((objc_subclassing_restricted))
@interface BowKeyEvent : NSObject

- (instancetype)initWithKind:(BowKeyEventKind)kind
                     keyCode:(NSInteger)keyCode
                  characters:(NSString *)characters
 charactersIgnoringModifiers:(NSString *)charactersIgnoringModifiers
                   modifiers:(BowKeyModifiers)modifiers
             inEditableField:(BOOL)inEditableField NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property(nonatomic, readonly) BowKeyEventKind kind;
/// The macOS virtual key code.
@property(nonatomic, readonly) NSInteger keyCode;
@property(nonatomic, readonly, copy) NSString *characters;
@property(nonatomic, readonly, copy) NSString *charactersIgnoringModifiers;
@property(nonatomic, readonly) BowKeyModifiers modifiers;
@property(nonatomic, readonly, getter=isInEditableField) BOOL inEditableField;

@end

#pragma mark Sign in and certificates

/// A server or proxy asked for a user name and password. Immutable. Mirrors BowCore's `AuthChallenge`.
NS_SWIFT_SENDABLE
__attribute__((objc_subclassing_restricted))
@interface BowAuthChallenge : NSObject

- (instancetype)initWithURL:(nullable NSURL *)url
                       host:(NSString *)host
                       port:(NSInteger)port
                      realm:(NSString *)realm
                     scheme:(NSString *)scheme
                    fromProxy:(BOOL)fromProxy NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property(nonatomic, readonly, copy, nullable) NSURL *url;
@property(nonatomic, readonly, copy) NSString *host;
@property(nonatomic, readonly) NSInteger port;
@property(nonatomic, readonly, copy) NSString *realm;
@property(nonatomic, readonly, copy) NSString *scheme;
/// YES when a proxy asked rather than the server.
@property(nonatomic, readonly) BOOL fromProxy;

@end

/// A page's certificate failed to verify. Immutable. Mirrors BowCore's `CertificateError`.
NS_SWIFT_SENDABLE
__attribute__((objc_subclassing_restricted))
@interface BowCertificateError : NSObject

- (instancetype)initWithURL:(nullable NSURL *)url code:(NSInteger)code NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property(nonatomic, readonly, copy, nullable) NSURL *url;
/// The engine's network error code.
@property(nonatomic, readonly) NSInteger code;

@end

NS_ASSUME_NONNULL_END
