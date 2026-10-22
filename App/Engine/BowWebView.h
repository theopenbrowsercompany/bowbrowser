#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A view that shows one Chromium browser. Create it after the engine has started.
@interface BowWebView : NSView

- (instancetype)initWithFrame:(NSRect)frame url:(NSString *)url NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

- (void)loadURL:(NSString *)url;

/// Call from the window's `windowShouldClose:`. Returns YES when the window may close now.
/// Otherwise it starts closing the browser, and the window is asked again once the browser is ready.
- (BOOL)shouldCloseWindow;

@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly, copy) NSString *currentURL;

@property(nonatomic, copy, nullable) void (^onTitleChange)(NSString *title);
@property(nonatomic, copy, nullable) void (^onAddressChange)(NSString *url);
/// Called when the main frame finishes loading, with its HTTP status code.
@property(nonatomic, copy, nullable) void (^onLoadEnd)(NSInteger httpStatusCode);
/// Called when the main frame fails to load.
@property(nonatomic, copy, nullable) void (^onLoadError)(NSInteger errorCode, NSString *errorText, NSString *failedURL);

@end

NS_ASSUME_NONNULL_END
