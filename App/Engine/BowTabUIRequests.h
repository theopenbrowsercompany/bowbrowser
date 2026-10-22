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

/// A page asked to open a new tab or window. Immutable. Mirrors BowCore's `PopupRequest`.
NS_SWIFT_SENDABLE
__attribute__((objc_subclassing_restricted))
@interface BowPopupRequest : NSObject

- (instancetype)initWithTargetURL:(nullable NSURL *)targetURL
                      disposition:(BowPopupDisposition)disposition
                    isUserGesture:(BOOL)isUserGesture
                    requestedSize:(nullable BowPopupSize *)requestedSize NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// The URL the page asked to open, or nil for a blank popup (for example `window.open()` with no URL).
@property(nonatomic, readonly, copy, nullable) NSURL *targetURL;
@property(nonatomic, readonly) BowPopupDisposition disposition;
@property(nonatomic, readonly) BOOL isUserGesture;
/// The size the page asked for, when it asked for one.
@property(nonatomic, readonly, nullable) BowPopupSize *requestedSize;

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

NS_ASSUME_NONNULL_END
