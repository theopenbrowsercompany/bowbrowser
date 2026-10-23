#import <Foundation/Foundation.h>

@class BowDownloads;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BowDownloadState) {
  /// Receiving bytes, or waiting for its destination.
  BowDownloadStateInProgress,
  BowDownloadStatePaused,
  /// Every byte is saved. Final.
  BowDownloadStateComplete,
  /// Cancelled, or refused a destination. Final.
  BowDownloadStateCancelled,
  /// Stopped by an error; it may resume.
  BowDownloadStateInterrupted,
  /// The tab that started it closed, so Chromium no longer reports it, and its file has stopped changing (or is
  /// gone) without finishing. It may still be stalled, failed or running. It can be removed, which cancels it.
  BowDownloadStateUnknown,
} NS_SWIFT_NAME(BowDownloadItem.State);

/// An immutable snapshot of one download, copied out of Chromium's download item when it changed.
NS_SWIFT_SENDABLE
@interface BowDownloadItem : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// Unique within its profile for the life of the engine.
@property(nonatomic, readonly) uint32_t downloadID;
@property(nonatomic, readonly, copy, nullable) NSURL *url;
/// The name the server or page suggested.
@property(nonatomic, readonly, copy) NSString *suggestedFileName;
/// The file being written, or nil until its destination is chosen.
@property(nonatomic, readonly, copy, nullable) NSString *fullPath;
@property(nonatomic, readonly) BowDownloadState state;
@property(nonatomic, readonly) int64_t receivedBytes;
/// The full size, or a value of 0 or less when unknown.
@property(nonatomic, readonly) int64_t totalBytes;
@property(nonatomic, readonly) int64_t currentSpeed;

@end

/// Receives one profile's download events, on the main thread. The engine asks it where each download goes.
NS_SWIFT_UI_ACTOR
@protocol BowDownloadsDelegate <NSObject>

- (void)downloads:(BowDownloads *)downloads didCreateItem:(BowDownloadItem *)item NS_SWIFT_NAME(downloads(_:didCreate:));
- (void)downloads:(BowDownloads *)downloads didUpdateItem:(BowDownloadItem *)item NS_SWIFT_NAME(downloads(_:didUpdate:));
- (void)downloads:(BowDownloads *)downloads didRemoveItem:(BowDownloadItem *)item NS_SWIFT_NAME(downloads(_:didRemove:));

/// Asked once for each new download, after `didCreateItem:`. Call `completionHandler` once, from any thread, with
/// the full path to save to, or nil to cancel the download. A handler released uncalled cancels it.
- (void)downloads:(BowDownloads *)downloads
    chooseDestinationForItem:(BowDownloadItem *)item
               suggestedName:(NSString *)suggestedName
           completionHandler:(void (^)(NSString *_Nullable path))completionHandler
    NS_SWIFT_NAME(downloads(_:chooseDestinationFor:suggestedName:completionHandler:));

@optional
/// Asked before a download starts. NO refuses it before it exists. Defaults to YES.
- (BOOL)downloads:(BowDownloads *)downloads shouldAllowDownloadFromURL:(NSURL *)url
    NS_SWIFT_NAME(downloads(_:shouldAllowDownloadFrom:));

@end

/// One profile's downloads, over Chromium's download handler. Every tab of the profile reports its downloads here.
/// Without a delegate, downloads are refused (the Alloy runtime has no download UI of its own).
///
/// Chromium reports a download only through the tab that started it: once that tab closes, Chromium says nothing
/// more about it (and CEF, which aborts every request of a closed browser, cancels it). From then on this object
/// follows the download's file on disk instead, a few times a second: the file's size is the progress, the file
/// reaching its known size means it completed, and the file disappearing means it was cancelled. Pause, resume and
/// cancel still reach Chromium and show at once.
NS_SWIFT_UI_ACTOR
@interface BowDownloads : NSObject

- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly, copy) NSString *profileID;
/// Held weakly.
@property(nonatomic, weak, nullable) id<BowDownloadsDelegate> delegate;
/// The latest snapshot of every download not removed, oldest first.
@property(nonatomic, readonly) NSArray<BowDownloadItem *> *items;

/// Each does nothing when the download cannot take it now, or before Chromium has reported the download once.
- (void)pauseDownload:(uint32_t)downloadID NS_SWIFT_NAME(pause(_:));
- (void)resumeDownload:(uint32_t)downloadID NS_SWIFT_NAME(resume(_:));
- (void)cancelDownload:(uint32_t)downloadID NS_SWIFT_NAME(cancel(_:));
/// Takes a download that is complete, cancelled, interrupted or unknown out of `items`, reporting `didRemoveItem:`. The file
/// stays on disk. Running and paused downloads stay.
- (void)removeDownload:(uint32_t)downloadID NS_SWIFT_NAME(remove(_:));

@end

NS_ASSUME_NONNULL_END
