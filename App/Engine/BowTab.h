#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// An immutable snapshot of a tab, as last pushed by the engine. Never computed on demand.
NS_SWIFT_SENDABLE
@interface BowTabState : NSObject

- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) uint64_t tabID;
/// The committed URL, or nil before anything has committed.
@property(nonatomic, readonly, copy, nullable) NSURL *url;
/// The page title, empty when the page has none yet.
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly, copy, nullable) NSURL *faviconURL;
@property(nonatomic, readonly, getter=isLoading) BOOL loading;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;

@end

/// One web page for its whole life, independent of any view that shows it. Created by `BowProfile`; shown by
/// attaching it to a `BowWebView`. The engine keeps the tab alive until it closes, so letting go of it does not
/// close the page: call `closeWithCompletion:`.
NS_SWIFT_UI_ACTOR
@interface BowTab : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// Assigned at creation and unique for the life of the engine.
@property(nonatomic, readonly) uint64_t tabID;
@property(nonatomic, readonly, copy) NSString *profileID;

/// The snapshot pushed last, also delivered to `onStateChange`.
@property(nonatomic, readonly) BowTabState *state;

/// YES once the page has been destroyed. Navigation calls then do nothing.
@property(nonatomic, readonly, getter=isClosed) BOOL closed;

- (void)loadURL:(NSURL *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stop;

/// Closes the tab after running the page's beforeunload handler. The completion runs on a later main thread task
/// with YES once the page is destroyed, or NO when the person chose to stay on the page.
- (void)closeWithCompletion:(void (^)(BOOL closed))completion NS_SWIFT_NAME(close(completion:));

/// Called with each new snapshot.
@property(nonatomic, copy, nullable) void (^onStateChange)(BowTabState *state);
/// Called when the main frame finishes loading, with its HTTP status code.
@property(nonatomic, copy, nullable) void (^onLoadEnd)(NSInteger httpStatusCode);
/// Called when the main frame fails to load.
@property(nonatomic, copy, nullable) void (^onLoadError)(NSInteger errorCode, NSString *errorText, NSString *failedURL);
/// Called once, on a later main thread task, after the page has been destroyed, whoever closed it (the app,
/// quitting, or the page itself).
@property(nonatomic, copy, nullable) void (^onClose)(void);

@end

NS_ASSUME_NONNULL_END
