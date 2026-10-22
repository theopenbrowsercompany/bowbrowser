#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Everything the engine needs before Chromium starts. The app builds one per launch (normal, smoke or e2e) and
/// main hands it to the engine at startup; changing it after the engine has started has no effect.
@interface BowEngineConfiguration : NSObject

/// Where Chromium keeps its profiles, caches and lock file. The default profile lives in `Default` inside it.
/// Chromium allows one running engine per root, so test runs use a fresh root of their own.
- (instancetype)initWithRootDataDirectory:(NSString *)rootDataDirectory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly, copy) NSString *rootDataDirectory;

/// Extra Chromium command line switches for the browser process, by name without the leading dashes.
/// An empty value adds the switch without a value.
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *extraSwitches;

/// The macOS keychain service Chromium stores its keys under. Nil keeps Chromium's default.
@property(nonatomic, copy, nullable) NSString *keychainServiceName;

/// When above 0, quitting that has not finished this many seconds after it started prints a line to stderr
/// and exits the process with `BowEngineQuitTimeoutExitCode`. Smoke runs set it; defaults to 0 (wait forever).
@property(nonatomic) NSTimeInterval quitTimeout;

/// When YES, prints `quit: seconds=<time>` to stderr once the engine has shut down, timed from the start of the
/// quit clock. Defaults to NO.
@property(nonatomic) BOOL reportsQuitTime;

@end

NS_ASSUME_NONNULL_END
