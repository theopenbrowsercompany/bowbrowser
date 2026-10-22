#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Exit code used when quitting takes longer than `quitTimeout`.
extern const int BowEngineQuitTimeoutExitCode;

/// App-wide control of the Chromium engine.
@interface BowEngine : NSObject

/// The process exit code returned from `main` once the engine shuts down. Defaults to 0.
@property(class, nonatomic) int exitCode;

/// When above 0, quitting that has not finished this many seconds after it started prints a line to stderr
/// and exits the process with `BowEngineQuitTimeoutExitCode`. Test runs set it; defaults to 0 (wait forever).
@property(class, nonatomic) NSTimeInterval quitTimeout;

/// When YES, prints `quit: seconds=<time>` to stderr once the engine has shut down, timed from the start of the
/// quit clock. Defaults to NO.
@property(class, nonatomic) BOOL reportsQuitTime;

/// Starts timing a quit (and the `quitTimeout` watchdog) without closing anything yet, for quits that begin by
/// closing a window. `quit` starts it too; only the first call counts.
+ (void)startQuitClock;

/// Closes every browser, then stops the engine's message loop so `main` returns and the app exits.
/// Safe to call more than once: browsers already closing are left alone, and browsers whose page kept them open
/// (by asking the person to stay) are asked again.
+ (void)quit;

@end

NS_ASSUME_NONNULL_END
