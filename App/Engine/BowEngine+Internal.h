// C++ hooks shared by the engine's Objective-C++ files. Never import this from Swift.
#pragma once

#import <AppKit/AppKit.h>

#include <cstdint>

#import "BowDownloads.h"
#import "BowEngineConfiguration.h"
#import "BowProfile.h"
#import "BowTab.h"
#include "include/cef_browser.h"
#include "include/cef_download_handler.h"
#include "include/cef_request_context.h"

NS_ASSUME_NONNULL_BEGIN

/// Called by main before CefInitialize, with the configuration Chromium is started from.
void BowEngineStart(BowEngineConfiguration* configuration);
/// The configuration the engine was started with.
BowEngineConfiguration* BowEngineCurrentConfiguration();

/// Where detached tabs keep their browser view: a view in no window, so their pages count as hidden.
NSView* BowEngineParkingView();
/// Moves a new browser's view into the parking view so its page counts as hidden from the start, as a parked tab's
/// does. Chromium needs this for a page that was never shown; later parking only needs the view moved.
void BowEngineParkNewBrowserView(NSView* browserView);

// The engine tracks every browser from creation to destruction, tabs and the popups their pages open, so quitting
// waits for each one to close and ends the message loop exactly once, after the last OnBeforeClose.
// Tabs stay registered (and alive) until their browser closes. Call these on the main thread.

/// A tab's browser was requested and OnAfterCreated has not arrived yet. The engine keeps the tab alive from now on.
void BowEngineBrowserCreationStarted(BowTab* tab);
/// Creating a tab's browser failed after BowEngineBrowserCreationStarted.
void BowEngineBrowserCreationFailed(BowTab* tab);
/// OnAfterCreated. `tab` is the tab that owns the browser, or nil for a popup. If the app is quitting, the browser
/// is then closed.
void BowEngineBrowserCreated(CefRefPtr<CefBrowser> browser, BowTab* _Nullable tab);
/// Asks a browser to close, running its unload handlers. Does nothing once the browser has accepted closing
/// (DoClose), and nothing if a close was already requested unless `askAgain` is true, so a page's leave prompt is
/// not shown twice for one request.
void BowEngineCloseBrowser(CefRefPtr<CefBrowser> browser, bool askAgain);
/// YES once BowEngine.quit has started and no page has cancelled it: every browser is being closed.
bool BowEngineIsQuitting();
/// An unload's silent answer kept the page: the browser's pending close ends, but quitting is never cancelled.
void BowEngineBrowserUnloadRefused(CefRefPtr<CefBrowser> browser);
/// The person chose to stay at a page's leave prompt. A pending close of that browser is cancelled, and so is
/// quitting. Returns true when a close was pending.
bool BowEngineBrowserCloseCancelled(CefRefPtr<CefBrowser> browser);
/// DoClose: the browser's unload handlers have run and it can no longer cancel closing.
void BowEngineBrowserWillClose(CefRefPtr<CefBrowser> browser);
/// OnBeforeClose. Ends the message loop when the app is quitting and this was the last browser.
void BowEngineBrowserClosed(CefRefPtr<CefBrowser> browser);
/// Called by main when the message loop has ended, before CefShutdown.
void BowEngineMessageLoopDidEnd();
/// Called by main after CefShutdown returns.
void BowEngineDidShutDown();

/// The open tab with this ID, or nil.
BowTab* _Nullable BowEngineTabWithID(uint64_t tabID);

@interface BowProfile ()
- (instancetype)initWithProfileID:(NSString*)profileID
                       persistent:(BOOL)persistent
                   requestContext:(CefRefPtr<CefRequestContext>)requestContext;
/// The request context every tab of this profile is created in.
@property(nonatomic, readonly) CefRefPtr<CefRequestContext> requestContext;
@end

@interface BowDownloads ()
- (instancetype)initWithProfileID:(NSString*)profileID;
/// The download handler every tab of the profile hands to Chromium.
@property(nonatomic, readonly) CefRefPtr<CefDownloadHandler> handler;
@end

@interface BowTab ()
- (instancetype)initWithProfile:(BowProfile*)profile url:(NSURL*)url;
/// The tab's browser, or null once it has closed (or failed to open).
@property(nonatomic, readonly) CefRefPtr<CefBrowser> browser;
/// Chromium's view for the browser, or nil once it has closed.
@property(nonatomic, readonly, nullable) NSView* browserView;
/// YES once the browser has accepted closing (DoClose): its view is being torn down and must not be attached.
@property(nonatomic, readonly) BOOL willClose;
/// The host view showing the tab, set by BowWebView.
@property(nonatomic, weak, nullable) NSView* hostView;
@end

NS_ASSUME_NONNULL_END
