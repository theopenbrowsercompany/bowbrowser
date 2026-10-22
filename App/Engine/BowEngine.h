#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// App-wide control of the Chromium engine.
@interface BowEngine : NSObject

/// The process exit code returned from `main` once the engine shuts down. Defaults to 0.
@property(class, nonatomic) int exitCode;

/// Closes every browser, then stops the engine's message loop so the app exits.
+ (void)quit;

@end

NS_ASSUME_NONNULL_END
