#import <Foundation/Foundation.h>

#import "BowTabUIRequests.h"

@class BowDownloads;
@class BowTab;

NS_ASSUME_NONNULL_BEGIN

/// One isolated storage profile (cookies, cache, site data), wrapping one Chromium request context.
/// Created and looked up by ID on `BowEngine`. Tabs in different profiles never share storage or a render process.
NS_SWIFT_UI_ACTOR
@interface BowProfile : NSObject

- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly, copy) NSString *profileID;
@property(nonatomic, readonly) BOOL isPersistent;
/// Every download started in this profile's tabs.
@property(nonatomic, readonly) BowDownloads *downloads;

/// Creates a tab in this profile and starts loading `url`. The tab's ID is assigned now; it is not attached to
/// any view until a `BowWebView` attaches it, and it lives until it is closed or the engine quits.
- (BowTab *)createTabWithURL:(NSURL *)url NS_SWIFT_NAME(createTab(url:));

/// Stores an answer to a permission prompt in this profile's content settings: allowed or blocked for each of
/// `kinds` on the site `origin`. Chromium's own permission checks then agree with it (a page's
/// `navigator.permissions.query` reads it, and Chromium does not prompt again for that kind). Kinds the app never
/// remembers (screen capture, storage access, other) are skipped. An in-memory profile keeps the setting only while it runs.
- (void)setPermissionAllowed:(BOOL)allowed
                    forKinds:(BowPermissionKind)kinds
                      origin:(NSURL *)origin NS_SWIFT_NAME(setPermission(allowed:kinds:origin:));

@end

NS_ASSUME_NONNULL_END
