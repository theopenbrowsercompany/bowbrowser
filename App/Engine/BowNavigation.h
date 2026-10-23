// Values that describe a tab's main frame navigations. Swift visible: plain Objective-C only, never C++ or CEF.
// Names and values mirror BowCore's engine contract (EngineNavigation, NavigationTransition, NavigationPolicy and
// NavigationError) so the Swift adapter over the bridge maps them one to one.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Why a navigation started. Mirrors BowCore's `NavigationTransition`.
typedef NS_CLOSED_ENUM(NSInteger, BowNavigationTransition) {
  /// A link click or script navigation in the page.
  BowNavigationTransitionLink,
  /// Typed or chosen from the address bar or command bar, or loaded by the app.
  BowNavigationTransitionTyped,
  BowNavigationTransitionFormSubmit,
  BowNavigationTransitionReload,
  BowNavigationTransitionBackForward,
  BowNavigationTransitionOther,
} NS_SWIFT_NAME(BowNavigation.Transition);

/// The answer to a navigation policy question. Mirrors BowCore's `NavigationPolicy`.
typedef NS_CLOSED_ENUM(NSInteger, BowNavigationPolicy) {
  BowNavigationPolicyAllow,
  BowNavigationPolicyCancel,
} NS_SWIFT_NAME(BowNavigation.Policy);

/// One main frame navigation as the engine reports it. Immutable. Mirrors BowCore's `EngineNavigation`.
NS_SWIFT_SENDABLE
__attribute__((objc_subclassing_restricted))
@interface BowNavigation : NSObject

- (instancetype)initWithURL:(NSURL *)url
                 transition:(BowNavigationTransition)transition
              isUserGesture:(BOOL)isUserGesture
                 isRedirect:(BOOL)isRedirect NS_DESIGNATED_INITIALIZER;
/// A navigation's first ask (`isRedirect` NO).
- (instancetype)initWithURL:(NSURL *)url
                 transition:(BowNavigationTransition)transition
              isUserGesture:(BOOL)isUserGesture;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// The URL being navigated to. For a redirect, the URL redirected to.
@property(nonatomic, readonly, copy) NSURL *url;
@property(nonatomic, readonly) BowNavigationTransition transition;
/// YES when the navigation followed a user action in the page, such as a click.
@property(nonatomic, readonly) BOOL isUserGesture;
/// YES when the engine asks about a server redirect of a navigation already under way, NO for a navigation's first
/// ask. A redirect keeps the transition and gesture of the navigation it belongs to.
@property(nonatomic, readonly) BOOL isRedirect;

@end

/// A failed navigation: the engine's network error code (a negative Chromium net error, for example -105 for a
/// name that does not resolve) and its readable text. Immutable. Mirrors BowCore's `NavigationError`, whose
/// `description` is `errorText` here (NSObject's `description` stays the object's debug text).
NS_SWIFT_SENDABLE
__attribute__((objc_subclassing_restricted))
@interface BowNavigationError : NSObject

- (instancetype)initWithCode:(NSInteger)code errorText:(NSString *)errorText NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property(nonatomic, readonly) NSInteger code;
/// The engine's readable text for `code`, for example `ERR_NAME_NOT_RESOLVED`.
@property(nonatomic, readonly, copy) NSString *errorText;

@end

NS_ASSUME_NONNULL_END
