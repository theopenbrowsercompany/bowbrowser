#import <Foundation/Foundation.h>

@class BowTab;

NS_ASSUME_NONNULL_BEGIN

/// One isolated storage profile (cookies, cache, site data), wrapping one Chromium request context.
/// Created and looked up by ID on `BowEngine`. Tabs in different profiles never share storage or a render process.
NS_SWIFT_UI_ACTOR
@interface BowProfile : NSObject

- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly, copy) NSString *profileID;
@property(nonatomic, readonly) BOOL isPersistent;

/// Creates a tab in this profile and starts loading `url`. The tab's ID is assigned now; it is not attached to
/// any view until a `BowWebView` attaches it, and it lives until it is closed or the engine quits.
- (BowTab *)createTabWithURL:(NSURL *)url NS_SWIFT_NAME(createTab(url:));

@end

NS_ASSUME_NONNULL_END
