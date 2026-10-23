#import "BowEngine.h"

#include <unistd.h>

#include <cstdio>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "BowDownloads+Internal.h"
#include "BowEngine+Internal.h"
#if BOW_E2E
#include "BowE2EHooks.h"  // E2E seam
#endif
#include "include/cef_app.h"

const int BowEngineQuitTimeoutExitCode = 3;
NSErrorDomain const BowEngineErrorDomain = @"BowEngineErrorDomain";
NSString* const BowDefaultProfileID = @"Default";

namespace {

struct BrowserEntry {
  CefRefPtr<CefBrowser> browser;
  // The tab that owns the browser, kept alive until the browser closes; nil for a popup.
  BowTab* tab = nil;
  // True once DoClose has run: the close can no longer be cancelled and OnBeforeClose follows.
  bool willClose = false;
  // True once CloseBrowser has been called. Until willClose the page may still cancel (its leave prompt).
  bool closeRequested = false;
};

// Open browsers by identifier, plus the tabs whose browser was requested but not created yet. Both hold their tabs
// strongly, so a tab lives from creation until its browser closes even if the app lets go of it.
std::map<int, BrowserEntry> gBrowsers;
NSMutableArray<BowTab*>* gOpeningTabs = [NSMutableArray array];

bool gQuitting = false;
bool gMessageLoopQuit = false;
CFAbsoluteTime gQuitStart = 0;
dispatch_source_t gQuitWatchdog = nil;

int gExitCode = 0;
NSTimeInterval gQuitDuration = 0;
BowEngineConfiguration* gConfiguration = nil;

#if BOW_E2E  // E2E seam
NSTimeInterval gQuitCloseDuration = 0;
std::vector<std::function<void(CefRefPtr<CefRequestContext>)>> gProfileContextObservers;
bool gParkPopups = false;
NSView* (^gPopupHost)(void) = nil;
std::map<std::string, size_t> gParkedRequestsRefused;
#endif

void QuitMessageLoopIfDone() {
  if (!gQuitting || gMessageLoopQuit || gOpeningTabs.count > 0) return;
  if (!gBrowsers.empty()) {
    // Once only closed tabs' browsers kept alive for their downloads are left, quitting closes them, which cancels
    // the downloads. Not sooner, so a quit a page cancels (staying at its leave prompt) leaves them running.
    for (const auto& [identifier, entry] : gBrowsers) {
      if (!BowDownloadsKeepsBrowserAlive(identifier)) return;
    }
    BowDownloadsReleaseKeptBrowsers();
    return;
  }
  // CEF requires every OnBeforeClose before the loop ends; an empty map guarantees that.
  gMessageLoopQuit = true;
  CefQuitMessageLoop();
}

void StartQuitWatchdog() {
  NSTimeInterval timeout = gConfiguration.quitTimeout;
  if (timeout <= 0) return;
  // Runs off the main thread so it still fires if the main thread is stuck, for example inside CefShutdown.
  gQuitWatchdog =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
  dispatch_source_set_timer(gQuitWatchdog, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                            DISPATCH_TIME_FOREVER, 0);
  dispatch_source_set_event_handler(gQuitWatchdog, ^{
    fprintf(stderr, "quit: timed out after %.1f seconds\n", timeout);
    fflush(stderr);
    _exit(BowEngineQuitTimeoutExitCode);
  });
  dispatch_resume(gQuitWatchdog);
}

void StopQuitWatchdog() {
  if (!gQuitWatchdog) return;
  dispatch_source_cancel(gQuitWatchdog);
  gQuitWatchdog = nil;
}

// A profile ID names a folder, so it is limited to characters that are safe in one.
bool IsValidProfileID(NSString* profileID) {
  if (profileID.length == 0 || [profileID isEqualToString:@"."] || [profileID isEqualToString:@".."]) return false;
  NSCharacterSet* allowed =
      [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
                                                         @"0123456789._-"];
  return [profileID rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

NSError* EngineError(BowEngineError code, NSString* message) {
  return [NSError errorWithDomain:BowEngineErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

}  // namespace

void BowEngineStart(BowEngineConfiguration* configuration) {
  gConfiguration = configuration;
}

BowEngineConfiguration* BowEngineCurrentConfiguration() {
  return gConfiguration;
}

NSView* BowEngineParkingView() {
  static NSView* parkingView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  return parkingView;
}

void BowEngineParkNewBrowserView(NSView* browserView) {
  // Chromium trusts a new page's starting visibility, which CEF sets to visible for windowed browsers, and ignores
  // every hidden signal until the page has really been visible once (WebContentsImpl::UpdateWebContentsVisibility).
  // A browser created in the parking view (in no window) would so stay visible and keep painting until first shown.
  // Passing its view through a window gives Chromium that first visible state, and leaving the window marks the page
  // hidden, both at once. The window is never put on screen, so nothing shows and the occlusion checker, which only
  // looks at windows on screen, never marks it occluded.
  static NSWindow* firstVisibleWindow = [] {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.releasedWhenClosed = NO;
    window.excludedFromWindowsMenu = YES;
    return window;
  }();
  NSView* parkingView = BowEngineParkingView();
  [firstVisibleWindow setContentSize:parkingView.bounds.size];
  [firstVisibleWindow.contentView addSubview:browserView];
  [parkingView addSubview:browserView];
}


BowTab* BowEngineTabWithID(uint64_t tabID) {
  for (const auto& [identifier, entry] : gBrowsers) {
    // A closed tab whose browser stays alive for its downloads is gone for the app.
    if (entry.tab && !entry.tab.closed && entry.tab.tabID == tabID) return entry.tab;
  }
  return nil;
}

void BowEngineBrowserCreationStarted(BowTab* tab) {
  [gOpeningTabs addObject:tab];
}

void BowEngineBrowserCreationFailed(BowTab* tab) {
  [gOpeningTabs removeObjectIdenticalTo:tab];
  QuitMessageLoopIfDone();
}

void BowEngineBrowserCreated(CefRefPtr<CefBrowser> browser, BowTab* tab) {
  // Popups are created by CEF, not requested through BowEngineBrowserCreationStarted.
  if (tab) [gOpeningTabs removeObjectIdenticalTo:tab];
  gBrowsers[browser->GetIdentifier()] = BrowserEntry{browser, tab};
  if (gQuitting) {
    // Not from inside OnAfterCreated: close on a later main thread task.
    dispatch_async(dispatch_get_main_queue(), ^{
      BowEngineCloseBrowser(browser, false);
    });
  }
}

void BowEngineCloseBrowser(CefRefPtr<CefBrowser> browser, bool askAgain) {
  auto it = gBrowsers.find(browser->GetIdentifier());
  if (it == gBrowsers.end() || it->second.willClose) return;
  if (it->second.closeRequested && !askAgain) return;
  it->second.closeRequested = true;
  browser->GetHost()->CloseBrowser(false);
}

bool BowEngineIsQuitting() {
  return gQuitting;
}

void BowEngineBrowserUnloadRefused(CefRefPtr<CefBrowser> browser) {
  auto it = gBrowsers.find(browser->GetIdentifier());
  if (it != gBrowsers.end() && !it->second.willClose) it->second.closeRequested = false;
}

bool BowEngineBrowserCloseCancelled(CefRefPtr<CefBrowser> browser) {
  auto it = gBrowsers.find(browser->GetIdentifier());
  if (it == gBrowsers.end() || it->second.willClose || !it->second.closeRequested) return false;
  it->second.closeRequested = false;
  if (!gMessageLoopQuit && (gQuitting || gQuitStart > 0)) {
    // Staying on a page cancels the quit, including one that began by closing a window, as in other browsers;
    // the next quit starts over, clock and watchdog included, and asks every page again (a popup that stayed
    // through Chromium's own prompt never reports back here, so its close request would otherwise stand).
    gQuitting = false;
    gQuitStart = 0;
    StopQuitWatchdog();
    for (auto& [identifier, entry] : gBrowsers) {
      if (!entry.willClose) entry.closeRequested = false;
    }
  }
  return true;
}

void BowEngineBrowserWillClose(CefRefPtr<CefBrowser> browser) {
  auto it = gBrowsers.find(browser->GetIdentifier());
  if (it != gBrowsers.end()) it->second.willClose = true;
}

void BowEngineBrowserClosed(CefRefPtr<CefBrowser> browser) {
  gBrowsers.erase(browser->GetIdentifier());
  QuitMessageLoopIfDone();
}

void BowEngineMessageLoopDidEnd() {
  BowDownloadsEngineDidStop();
#if BOW_E2E  // E2E seam: the e2e run times the app's part of quitting apart from Chromium's shutdown.
  if (gQuitStart > 0) gQuitCloseDuration = CFAbsoluteTimeGetCurrent() - gQuitStart;
#endif
}

void BowEngineDidShutDown() {
  StopQuitWatchdog();
  if (gQuitStart > 0) gQuitDuration = CFAbsoluteTimeGetCurrent() - gQuitStart;
  if (gConfiguration.reportsQuitTime && gQuitStart > 0) {
    fprintf(stderr, "quit: seconds=%.2f\n", gQuitDuration);
    fflush(stderr);
  }
}

@interface BowEngine ()
- (instancetype)initEngine NS_DESIGNATED_INITIALIZER;
@end

@implementation BowEngine {
  BowProfile* _defaultProfile;
  NSMutableDictionary<NSString*, BowProfile*>* _profiles;
}

+ (BowEngine*)shared {
  static BowEngine* engine = [[BowEngine alloc] initEngine];
  return engine;
}

- (instancetype)initEngine {
  self = [super init];
  if (self) _profiles = [NSMutableDictionary dictionary];
  return self;
}

- (BowProfile*)defaultProfile {
  if (!_defaultProfile) {
    // The global context keeps its data in CefSettings.cache_path, `Default` under the root (set in main).
    _defaultProfile = [[BowProfile alloc] initWithProfileID:BowDefaultProfileID
                                                 persistent:YES
                                             requestContext:CefRequestContext::GetGlobalContext()];
    _profiles[BowDefaultProfileID] = _defaultProfile;
  }
  return _defaultProfile;
}

- (BowProfile*)createProfileWithID:(NSString*)profileID persistent:(BOOL)persistent error:(NSError**)error {
  [self defaultProfile];
  if (!IsValidProfileID(profileID)) {
    if (error) *error = EngineError(BowEngineErrorInvalidProfileID, [NSString stringWithFormat:@"\"%@\" is not a valid profile ID", profileID]);
    return nil;
  }
  // Folder names are case insensitive on a default macOS volume, so IDs differing only in case would share one.
  for (NSString* existing in _profiles) {
    if ([existing caseInsensitiveCompare:profileID] == NSOrderedSame) {
      if (error) *error = EngineError(BowEngineErrorProfileExists, [NSString stringWithFormat:@"the profile \"%@\" exists", existing]);
      return nil;
    }
  }

  CefRequestContextSettings settings;
  if (persistent) {
    // Chromium needs a profile's cache_path to be a direct child of root_cache_path: deeper paths fail to create
    // ("Cannot create profile at path") and the profile silently keeps its data in memory. The prefix keeps
    // profile folders apart from Chromium's own folders in the root (Default, Crashpad, ShaderCache and others).
    NSString* path = [gConfiguration.rootDataDirectory
        stringByAppendingPathComponent:[@"Profile-" stringByAppendingString:profileID]];
    CefString(&settings.cache_path) = path.UTF8String;
  }
  // An empty cache_path keeps everything in memory.
  CefRefPtr<CefRequestContext> context = CefRequestContext::CreateContext(settings, nullptr);
  BowProfile* profile = [[BowProfile alloc] initWithProfileID:profileID persistent:persistent requestContext:context];
  _profiles[profileID] = profile;
#if BOW_E2E  // E2E seam
  for (const auto& observer : gProfileContextObservers) observer(context);
#endif
  return profile;
}

- (BowProfile*)profileWithID:(NSString*)profileID {
  if ([profileID isEqualToString:BowDefaultProfileID]) return self.defaultProfile;
  return _profiles[profileID];
}

- (NSArray<BowProfile*>*)allProfiles {
  [self defaultProfile];
  return _profiles.allValues;
}

+ (int)exitCode {
  return gExitCode;
}

+ (void)setExitCode:(int)exitCode {
  gExitCode = exitCode;
}

+ (NSTimeInterval)quitDuration {
  return gQuitDuration;
}

+ (void)startQuitClock {
  if (gQuitStart > 0) return;
  gQuitStart = CFAbsoluteTimeGetCurrent();
  StartQuitWatchdog();
}

+ (void)quit {
  [self startQuitClock];
  // A second quit means the person asked again (for example after staying on a page that asked to be kept),
  // so browsers that have not accepted closing yet are asked again.
  const bool askAgain = gQuitting;
  gQuitting = true;
  // Copy first, so a browser reporting back during the loop cannot change what is being iterated.
  const std::map<int, BrowserEntry> browsers = gBrowsers;
  for (const auto& [identifier, entry] : browsers) {
    BowEngineCloseBrowser(entry.browser, askAgain);
  }
  QuitMessageLoopIfDone();
}

+ (BOOL)keepsClosedTabsForDownloads {
  return BowDownloadsKeepAnyBrowser();
}

+ (void)whenClosedTabsForDownloadsReleased:(dispatch_block_t)block {
  BowDownloadsWhenNoBrowserKept(block);
}

+ (BOOL)isQuitting {
  return gQuitting;
}

@end

#if BOW_E2E  // E2E seam: the hooks declared in BowE2EHooks.h.
CefRefPtr<CefBrowser> BowEngineBrowserForTabID(uint64_t tabID) {
  BowTab* tab = BowEngineTabWithID(tabID);
  return tab ? tab.browser : nullptr;
}

NSTimeInterval BowEngineQuitCloseDuration() {
  return gQuitCloseDuration;
}

size_t BowEngineOpenBrowserCount() {
  return gBrowsers.size() + gOpeningTabs.count;
}

void BowEngineNoteParkedRequestRefused(const char* kind) {
  gParkedRequestsRefused[kind] += 1;
}

size_t BowEngineParkedRequestsRefused(const char* kind) {
  auto found = gParkedRequestsRefused.find(kind);
  return found == gParkedRequestsRefused.end() ? 0 : found->second;
}

bool BowEngineTabIsOpening(uint64_t tabID) {
  for (BowTab* tab in gOpeningTabs) {
    if (tab.tabID == tabID) return true;
  }
  return false;
}

void BowEngineObserveProfileContexts(std::function<void(CefRefPtr<CefRequestContext>)> observer) {
  for (BowProfile* profile in [BowEngine.shared allProfiles]) observer(profile.requestContext);
  gProfileContextObservers.push_back(std::move(observer));
}

void BowEngineParkPopups() {
  gParkPopups = true;
}

bool BowEngineParksPopups() {
  return gParkPopups;
}

void BowEngineHostPopups(NSView* (^host)(void)) {
  gPopupHost = [host copy];
}

NSView* BowEngineHostedPopupView() {
  return gPopupHost ? gPopupHost() : nil;
}

bool BowEngineClosePopupInView(NSView* view) {
  for (const auto& [identifier, entry] : gBrowsers) {
    if (entry.tab) continue;
    NSView* browserView = (__bridge NSView*)entry.browser->GetHost()->GetWindowHandle();
    if (browserView && [browserView isDescendantOf:view]) {
      // Already closing, or asked to before: nothing new would be sent.
      if (entry.willClose || entry.closeRequested) return false;
      // The same request quitting makes of every browser.
      BowEngineCloseBrowser(entry.browser, false);
      return true;
    }
  }
  return false;
}
#endif
