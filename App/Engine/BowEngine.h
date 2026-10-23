#import <Foundation/Foundation.h>

@class BowProfile;

NS_ASSUME_NONNULL_BEGIN

/// Exit code used when quitting takes longer than the configuration's `quitTimeout`.
extern const int BowEngineQuitTimeoutExitCode;

/// Error domain for engine calls that fail.
extern NSErrorDomain const BowEngineErrorDomain;

typedef NS_ERROR_ENUM(BowEngineErrorDomain, BowEngineError){
    /// A profile with the requested ID already exists.
    BowEngineErrorProfileExists = 1,
    /// The profile ID is empty or has characters other than letters, digits, `.`, `_` and `-`.
    BowEngineErrorInvalidProfileID = 2,
};

/// The ID of the persistent profile that wraps the engine's global storage. It always exists.
extern NSString *const BowDefaultProfileID;

/// The running Chromium engine: owns the profiles and shuts everything down. Main thread only.
///
/// App-wide lifetime (exit code, quit) is on the class. Profiles are on `shared`, which is usable once the engine
/// has started (`engineDidStart`).
NS_SWIFT_UI_ACTOR
@interface BowEngine : NSObject

/// The one engine of this process.
@property(class, nonatomic, readonly) BowEngine *shared;

- (instancetype)init NS_UNAVAILABLE;

/// The persistent profile `BowDefaultProfileID`, whose data lives in `Default` under the root data directory.
@property(nonatomic, readonly) BowProfile *defaultProfile;

/// Creates a profile with its own isolated storage. A persistent profile keeps cookies, cache and site data in
/// `Profile-<id>` in the root data directory; an ephemeral one keeps them in memory and loses them on quit.
/// Fails with `BowEngineErrorProfileExists` when the ID is taken (the default profile's included) and with
/// `BowEngineErrorInvalidProfileID` when the ID cannot name a folder.
- (nullable BowProfile *)createProfileWithID:(NSString *)profileID
                                  persistent:(BOOL)persistent
                                       error:(NSError **)error NS_SWIFT_NAME(createProfile(id:persistent:));

/// The profile with this ID, or nil. `BowDefaultProfileID` always returns the default profile.
- (nullable BowProfile *)profileWithID:(NSString *)profileID NS_SWIFT_NAME(profile(id:));

/// The process exit code returned from `main` once the engine shuts down. Defaults to 0.
@property(class, nonatomic) int exitCode;

/// Seconds from the start of the quit clock until the engine shut down, or 0 before then.
/// Read it once `main` has returned from the message loop, for example in `engineDidStop`.
@property(class, nonatomic, readonly) NSTimeInterval quitDuration;

/// Starts timing a quit (and the `quitTimeout` watchdog) without closing anything yet, for quits that begin by
/// closing a window. `quit` starts it too; only the first call counts until a page cancels the quit.
+ (void)startQuitClock;

/// Closes every tab, then stops the engine's message loop so `main` returns and the app exits.
/// Safe to call more than once: tabs already closing are left alone, and tabs whose page kept them open
/// (by asking the person to stay) are asked again. A page the person chooses to stay on cancels the quit.
+ (void)quit;

/// YES while the browsers of tabs that closed stay alive, out of sight, until their downloads end (destroying a
/// browser cancels its downloads). Quitting closes them, which cancels the downloads.
@property(class, nonatomic, readonly) BOOL keepsClosedTabsForDownloads;

/// Runs `block` on the main thread once no closed tab's browser is kept for its downloads any more: on a later
/// main thread task when none is now. Never runs once the engine has stopped.
+ (void)whenClosedTabsForDownloadsReleased:(dispatch_block_t)block
    NS_SWIFT_NAME(whenClosedTabsForDownloadsReleased(_:));

/// True from `quit` until the quit ends or a page the person stays on cancels it.
@property(class, nonatomic, readonly) BOOL isQuitting;

@end

NS_ASSUME_NONNULL_END
