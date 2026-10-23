#pragma once

#import "BowDownloads.h"

NS_ASSUME_NONNULL_BEGIN

/// Keeping a closed tab's browser alive while it downloads. CEF aborts every request of a browser it destroys,
/// which cancels its downloads, so a tab closing with downloads running or paused hides at once but leaves its
/// browser parked until they end. Main thread only.
@interface BowDownloads ()

/// YES while a download reported through the browser `browserID` is running or paused (or waiting for its
/// destination): destroying that browser now would cancel it.
- (BOOL)hasActiveDownloadsForBrowser:(int)browserID;
/// Runs `block` once, on a later main thread task, when the browser `browserID` has had no download running or
/// paused for a second (each finished, was cancelled, failed or was removed, and none resumed on its own). Also runs,
/// at once, when quitting releases kept browsers (BowDownloadsReleaseKeptBrowsers). Never runs once the engine has
/// stopped or the browser has closed.
- (void)whenDownloadsOfBrowserEnd:(int)browserID run:(dispatch_block_t)block;

@end

/// YES while a profile's downloads keep the browser `browserID` alive (whenDownloadsOfBrowserEnd:run: is waiting).
bool BowDownloadsKeepsBrowserAlive(int browserID);
/// Runs every waiting whenDownloadsOfBrowserEnd:run: block now (on a later main thread task), so quitting closes the
/// browsers they keep, which cancels their downloads.
void BowDownloadsReleaseKeptBrowsers();
/// YES while any profile's downloads keep a browser alive (BowEngine keepsClosedTabsForDownloads).
bool BowDownloadsKeepAnyBrowser();
/// Runs `block` once no profile's downloads keep a browser alive: on a later main thread task when none does now.
/// Never runs once the engine has stopped.
void BowDownloadsWhenNoBrowserKept(dispatch_block_t block);
/// OnBeforeClose of any browser: its downloads that are still running are followed on disk from now on.
void BowDownloadsBrowserClosed(int browserID);
/// Called once when the engine's message loop has ended, before CefShutdown. Every profile's downloads stop
/// following their files and let go of the browsers and controls they hold, and ignore later reports, so nothing
/// reaches Chromium or the app during shutdown. Main thread only; does no work that could slow quitting.
void BowDownloadsEngineDidStop();

NS_ASSUME_NONNULL_END
