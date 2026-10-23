#import "BowDownloads+Internal.h"

#include <sys/stat.h>

#include <map>
#include <set>
#include <string>
#include <vector>

#include "BowEngine+Internal.h"
#include "include/cef_download_handler.h"

#if BOW_E2E
#include "BowE2EHooks.h"  // E2E seam
#endif

namespace {

NSString* ToNSString(const CefString& value) {
  return [NSString stringWithUTF8String:value.ToString().c_str()] ?: @"";
}

BowDownloadState ToState(CefRefPtr<CefDownloadItem> item) {
  if (item->IsComplete()) return BowDownloadStateComplete;
  if (item->IsCanceled()) return BowDownloadStateCancelled;
  if (item->IsInterrupted()) return BowDownloadStateInterrupted;
  if (item->IsPaused()) return BowDownloadStatePaused;
  return BowDownloadStateInProgress;
}

bool IsFinal(BowDownloadState state) {
  return state == BowDownloadStateComplete || state == BowDownloadStateCancelled;
}

// How often downloads whose browser closed are read from disk, and how long their file may stay unchanged before their
// status is unknown.
constexpr NSTimeInterval kWatchInterval = 0.25;
constexpr CFAbsoluteTime kStallSeconds = 15;
// How long a kept browser stays after its last download ended, in case Chromium resumes an interrupted one on its
// own (which it does for some network errors), since destroying the browser would cancel it.
constexpr NSTimeInterval kReleaseGraceSeconds = 1;
// How long an orphaned download with no file on disk yet is given before it counts as cancelled.
constexpr CFAbsoluteTime kNoFileSeconds = 2;

// The size of the file at `path`, or -1 when there is none, and when `modified` is given, its last change in
// seconds since 1970.
int64_t FileSize(const std::string& path, double* modified = nullptr) {
  struct stat info;
  if (stat(path.c_str(), &info) != 0 || !S_ISREG(info.st_mode)) return -1;
  if (modified) *modified = info.st_mtimespec.tv_sec + info.st_mtimespec.tv_nsec / 1e9;
  return info.st_size;
}

// Running or paused: destroying the download's browser would cancel it.
bool IsActive(BowDownloadState state) {
  return state == BowDownloadStateInProgress || state == BowDownloadStatePaused;
}

bool NeedsReading(BowDownloadState state) {
  // An interrupted download changes only when it is resumed, which is reported or done through resumeDownload:.
  return state == BowDownloadStateInProgress || state == BowDownloadStatePaused || state == BowDownloadStateUnknown;
}

// True once the engine's message loop has ended: downloads hold nothing of Chromium's and ignore its reports.
bool gEngineStopped = false;

// Blocks waiting for no closed tab's browser to be kept for its downloads (BowEngine
// whenClosedTabsForDownloadsReleased:).
NSMutableArray<dispatch_block_t>* gReleaseWaiters;

bool AnyBrowserKept();

// Runs the waiting blocks once no browser is kept any more.
void RunReleaseWaitersIfNoneKept() {
  if (gEngineStopped || gReleaseWaiters.count == 0 || AnyBrowserKept()) return;
  NSArray<dispatch_block_t>* waiters = [gReleaseWaiters copy];
  [gReleaseWaiters removeAllObjects];
  for (dispatch_block_t waiter in waiters) waiter();
}

// What is known about a running download apart from its snapshot: the browser Chromium reports it through, and,
// once that browser has closed (a crash, a quit, or a popup window closing), what its file on disk last looked like.
struct Watch {
  CefRefPtr<CefBrowser> browser;
  // The browser closed, so the download is read from disk.
  bool orphaned = false;
  // Paused through `pauseDownload:` since it was orphaned; Chromium's pause is asynchronous.
  bool paused = false;
  // Chromium's partial file (`<path>.crdownload`) was seen, so the chosen file appearing alone means it completed.
  bool sawPartial = false;
  // The download's file was on disk, so its disappearing means Chromium cancelled it.
  bool sawFile = false;
  // The chosen file was seen growing after the browser closed, so this download is writing it.
  bool sawGrowth = false;
  // When the destination was chosen, in seconds since 1970, or 0 before; a file changed since was written by
  // this download, and one that has not was already there (a file the person chose to replace).
  double chosenAt = 0;
  // The state when the browser closed.
  BowDownloadState stateAtOrphan = BowDownloadStateInProgress;
  // The size of the chosen file at the last read, or -1 when there was none.
  int64_t lastFileSize = -1;
  // The size at the last read when the file looked complete then, else -1; it completes when the next read agrees.
  int64_t completeSize = -1;
  int64_t lastSize = 0;
  CFAbsoluteTime lastChange = 0;
  CFAbsoluteTime lastRead = 0;
  CFAbsoluteTime orphanedAt = 0;
};

}  // namespace

#pragma mark - BowDownloadItem

@interface BowDownloadItem ()
- (instancetype)initWithDownloadID:(uint32_t)downloadID
                               url:(nullable NSURL*)url
                 suggestedFileName:(NSString*)suggestedFileName
                          fullPath:(nullable NSString*)fullPath
                             state:(BowDownloadState)state
                     receivedBytes:(int64_t)receivedBytes
                        totalBytes:(int64_t)totalBytes
                      currentSpeed:(int64_t)currentSpeed NS_DESIGNATED_INITIALIZER;
@end

@implementation BowDownloadItem

- (instancetype)initWithDownloadID:(uint32_t)downloadID
                               url:(NSURL*)url
                 suggestedFileName:(NSString*)suggestedFileName
                          fullPath:(NSString*)fullPath
                             state:(BowDownloadState)state
                     receivedBytes:(int64_t)receivedBytes
                        totalBytes:(int64_t)totalBytes
                      currentSpeed:(int64_t)currentSpeed {
  self = [super init];
  if (self) {
    _downloadID = downloadID;
    _url = [url copy];
    _suggestedFileName = [suggestedFileName copy];
    _fullPath = [fullPath copy];
    _state = state;
    _receivedBytes = receivedBytes;
    _totalBytes = totalBytes;
    _currentSpeed = currentSpeed;
  }
  return self;
}

- (NSString*)description {
  return [NSString stringWithFormat:@"<BowDownloadItem %u %@ state=%ld %lld/%lld>", _downloadID,
                                    _fullPath ?: _suggestedFileName, (long)_state, _receivedBytes, _totalBytes];
}

@end

#pragma mark - BowDestinationAnswer

// Holds a download's pending destination question so it is answered once. Released unanswered, it cancels.
@interface BowDestinationAnswer : NSObject
- (instancetype)initWithCallback:(CefRefPtr<CefBeforeDownloadCallback>)callback onCancel:(dispatch_block_t)onCancel;
/// Main thread only. A nil or empty path cancels.
- (void)answer:(nullable NSString*)path;
/// Lets go of the callback without answering, once the engine has stopped. A later answer does nothing.
- (void)abandon;
@end

@implementation BowDestinationAnswer {
  CefRefPtr<CefBeforeDownloadCallback> _callback;
  dispatch_block_t _onCancel;
}

- (instancetype)initWithCallback:(CefRefPtr<CefBeforeDownloadCallback>)callback onCancel:(dispatch_block_t)onCancel {
  self = [super init];
  if (self) {
    _callback = callback;
    _onCancel = [onCancel copy];
  }
  return self;
}

- (void)answer:(NSString*)path {
  if (!_callback) return;
  CefRefPtr<CefBeforeDownloadCallback> callback = _callback;
  _callback = nullptr;
  if (path.length > 0) {
    callback->Continue(path.UTF8String, false);
  } else {
    // Releasing the callback without continuing cancels the download in CEF; onCancel makes sure of it.
    _onCancel();
  }
}

- (void)abandon {
  _callback = nullptr;
}

- (void)dealloc {
  if (_callback) dispatch_async(dispatch_get_main_queue(), _onCancel);
}

@end

#pragma mark - BowDownloads

@interface BowDownloads ()
- (BOOL)allowsDownloadFromURL:(NSString*)url;
- (BOOL)downloadWillBegin:(CefRefPtr<CefDownloadItem>)item
                  browser:(CefRefPtr<CefBrowser>)browser
            suggestedName:(NSString*)suggestedName
                 callback:(CefRefPtr<CefBeforeDownloadCallback>)callback;
- (void)downloadUpdated:(CefRefPtr<CefDownloadItem>)item
                browser:(CefRefPtr<CefBrowser>)browser
               callback:(CefRefPtr<CefDownloadItemCallback>)callback;
@end

@interface BowDownloadItem (Copy)
- (BowDownloadItem*)copyWithState:(BowDownloadState)state
                    receivedBytes:(int64_t)receivedBytes
                     currentSpeed:(int64_t)currentSpeed
                         fullPath:(nullable NSString*)fullPath;
@end

@implementation BowDownloadItem (Copy)
- (BowDownloadItem*)copyWithState:(BowDownloadState)state
                    receivedBytes:(int64_t)receivedBytes
                     currentSpeed:(int64_t)currentSpeed
                         fullPath:(NSString*)fullPath {
  return [[BowDownloadItem alloc] initWithDownloadID:self.downloadID
                                                 url:self.url
                                   suggestedFileName:self.suggestedFileName
                                            fullPath:fullPath
                                               state:state
                                       receivedBytes:receivedBytes
                                          totalBytes:self.totalBytes
                                        currentSpeed:currentSpeed];
}
@end

// Chromium's download callbacks for every browser of one profile, forwarded to its BowDownloads. They run on the
// main thread because the app uses CefRunMessageLoop.
class BowDownloadHandler : public CefDownloadHandler {
 public:
  explicit BowDownloadHandler(BowDownloads* downloads) : downloads_(downloads) {}

  bool CanDownload(CefRefPtr<CefBrowser> browser, const CefString& url, const CefString& requestMethod) override {
    // A closed tab's page kept for its downloads starts none, so it cannot keep itself alive.
    if (browser && BowDownloadsRefusesDownloadsFrom(browser->GetIdentifier())) {
#if BOW_E2E  // E2E seam: counts what a closed tab's page was refused.
      BowEngineNoteParkedRequestRefused("download");
#endif
      return false;
    }
    return [downloads_ allowsDownloadFromURL:ToNSString(url)];
  }

  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> item,
                        const CefString& suggestedName,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    return [downloads_ downloadWillBegin:item browser:browser suggestedName:ToNSString(suggestedName) callback:callback];
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    [downloads_ downloadUpdated:item browser:browser callback:callback];
  }

 private:
  __weak BowDownloads* downloads_;

  IMPLEMENT_REFCOUNTING(BowDownloadHandler);
};

@implementation BowDownloads {
  CefRefPtr<BowDownloadHandler> _handler;
  NSMutableArray<BowDownloadItem*>* _items;
  // The latest control callback of each download Chromium has reported; dropped once the download is final.
  std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> _controls;
  // The path the delegate chose for each download. Chromium writes to an intermediate file until it completes.
  std::map<uint32_t, std::string> _destinations;
  // Downloads refused a destination, cancelled at their next update in case CEF has not cancelled them yet.
  std::set<uint32_t> _cancelled;
  // Downloads taken out of the list; their late updates (a removed interrupted download's cancel) are ignored.
  std::set<uint32_t> _removed;
  // Every download that is not final or removed.
  std::map<uint32_t, Watch> _watches;
  // Reads orphaned downloads from disk while any of them can change. Downloads whose browser is alive are reported
  // by Chromium and never read.
  NSTimer* _watchTimer;
  // Browsers of closed tabs kept alive for their downloads, by browser ID, each with what to run once they end.
  std::map<int, dispatch_block_t> _keptBrowsers;
  // Kept browsers with no active download left, waiting out the release grace.
  std::set<int> _releaseChecks;
  // Kept browsers released and being torn down, until they close: their pages still run meanwhile, and start no
  // download either.
  std::set<int> _releasedBrowsers;
  // Destination questions not answered yet, abandoned when the engine stops.
  NSHashTable<BowDestinationAnswer*>* _answers;
}

// Every BowDownloads, so the engine stopping reaches each.
+ (NSHashTable<BowDownloads*>*)allDownloads {
  static NSHashTable<BowDownloads*>* all = [NSHashTable weakObjectsHashTable];
  return all;
}

- (void)engineDidStop {
  [_watchTimer invalidate];
  _watchTimer = nil;
  _keptBrowsers.clear();
  _releaseChecks.clear();
  _releasedBrowsers.clear();
  _watches.clear();
  _controls.clear();
  for (BowDestinationAnswer* answer in _answers) [answer abandon];
  [_answers removeAllObjects];
}

- (instancetype)initWithProfileID:(NSString*)profileID {
  self = [super init];
  if (self) {
    _profileID = [profileID copy];
    _items = [NSMutableArray array];
    _handler = new BowDownloadHandler(self);
    _answers = [NSHashTable weakObjectsHashTable];
    [BowDownloads.allDownloads addObject:self];
  }
  return self;
}

- (void)dealloc {
  [_watchTimer invalidate];
}

- (CefRefPtr<CefDownloadHandler>)handler {
  return _handler;
}

- (NSArray<BowDownloadItem*>*)items {
  return [_items copy];
}

#pragma mark Chromium

- (BOOL)allowsDownloadFromURL:(NSString*)url {
  id<BowDownloadsDelegate> delegate = self.delegate;
  if (!delegate) return NO;
  if (![delegate respondsToSelector:@selector(downloads:shouldAllowDownloadFromURL:)]) return YES;
  // A URL Chromium accepts but NSURL cannot parse is not the delegate's to judge.
  NSURL* parsed = [NSURL URLWithString:url];
  return parsed ? [delegate downloads:self shouldAllowDownloadFromURL:parsed] : YES;
}

- (BOOL)downloadWillBegin:(CefRefPtr<CefDownloadItem>)cefItem
                  browser:(CefRefPtr<CefBrowser>)browser
            suggestedName:(NSString*)suggestedName
                 callback:(CefRefPtr<CefBeforeDownloadCallback>)callback {
  id<BowDownloadsDelegate> delegate = self.delegate;
  // Returning false cancels the download in Alloy style.
  if (!delegate) return NO;
  const uint32_t downloadID = cefItem->GetId();
  [self watch:downloadID browser:browser];
  // Chromium may report an update first, which already announced the download.
  BOOL isNew = [self indexOf:downloadID] == NSNotFound;
  BowDownloadItem* item = [self store:[self snapshot:cefItem]];
  if (isNew) {
    [delegate downloads:self didCreateItem:item];
  } else {
    [delegate downloads:self didUpdateItem:item];
  }
  [self followIfBrowserClosed:browser];

  __weak BowDownloads* weakSelf = self;
  BowDestinationAnswer* answer = [[BowDestinationAnswer alloc] initWithCallback:callback
                                                                       onCancel:^{
                                                                         [weakSelf destinationRefused:downloadID];
                                                                       }];
  [_answers addObject:answer];
  [delegate downloads:self
      chooseDestinationForItem:item
                 suggestedName:suggestedName
             completionHandler:^(NSString* path) {
               dispatch_block_t apply = ^{
                 BowDownloads* strongSelf = weakSelf;
                 if (strongSelf && path.length > 0) {
                   strongSelf->_destinations[downloadID] = path.UTF8String;
                   auto watch = strongSelf->_watches.find(downloadID);
                   if (watch != strongSelf->_watches.end()) watch->second.chosenAt = NSDate.date.timeIntervalSince1970;
                 }
                 [answer answer:path];
               };
               if (NSThread.isMainThread) {
                 apply();
               } else {
                 dispatch_async(dispatch_get_main_queue(), apply);
               }
             }];
  return YES;
}

- (void)destinationRefused:(uint32_t)downloadID {
  // A download that already ended (its tab closed first) or was removed has nothing left to cancel.
  NSUInteger index = [self indexOf:downloadID];
  if (index == NSNotFound || IsFinal(_items[index].state)) return;
  _cancelled.insert(downloadID);
  auto control = _controls.find(downloadID);
  if (control != _controls.end()) control->second->Cancel();
}

- (void)downloadUpdated:(CefRefPtr<CefDownloadItem>)cefItem
                browser:(CefRefPtr<CefBrowser>)browser
               callback:(CefRefPtr<CefDownloadItemCallback>)callback {
  const uint32_t downloadID = cefItem->GetId();
  if (gEngineStopped || _removed.count(downloadID)) return;
  BowDownloadItem* item = [self snapshot:cefItem];
  if (IsFinal(item.state)) {
    _controls.erase(downloadID);
    _cancelled.erase(downloadID);
    _watches.erase(downloadID);
  } else {
    _controls[downloadID] = callback;
    if (_cancelled.count(downloadID)) callback->Cancel();
    [self watch:downloadID browser:browser];
  }
  BOOL isNew = [self indexOf:downloadID] == NSNotFound;
  [self store:item];
  id<BowDownloadsDelegate> delegate = self.delegate;
  if (isNew) {
    [delegate downloads:self didCreateItem:item];
  } else {
    [delegate downloads:self didUpdateItem:item];
  }
  if (!IsFinal(item.state)) [self followIfBrowserClosed:browser];
  [self releaseIdleBrowsers];
}

- (BowDownloadItem*)snapshot:(CefRefPtr<CefDownloadItem>)item {
  const uint32_t downloadID = item->GetId();
  BowDownloadState state = ToState(item);
  // A finished download reports the file Chromium actually wrote, which can differ from the one chosen (Chromium
  // may number or rename it); until then, the chosen file.
  NSString* fullPath = state == BowDownloadStateComplete ? ToNSString(item->GetFullPath()) : nil;
  auto destination = _destinations.find(downloadID);
  if (fullPath.length == 0 && destination != _destinations.end()) {
    fullPath = [NSString stringWithUTF8String:destination->second.c_str()];
  }
  NSString* url = ToNSString(item->GetURL());
  return [[BowDownloadItem alloc] initWithDownloadID:downloadID
                                                 url:url.length > 0 ? [NSURL URLWithString:url] : nil
                                   suggestedFileName:ToNSString(item->GetSuggestedFileName())
                                            fullPath:fullPath.length > 0 ? fullPath : nil
                                               state:state
                                       receivedBytes:item->GetReceivedBytes()
                                          totalBytes:item->GetTotalBytes()
                                        currentSpeed:item->GetCurrentSpeed()];
}

- (NSUInteger)indexOf:(uint32_t)downloadID {
  return [_items indexOfObjectPassingTest:^BOOL(BowDownloadItem* item, NSUInteger, BOOL*) {
    return item.downloadID == downloadID;
  }];
}

- (BowDownloadItem*)store:(BowDownloadItem*)item {
  NSUInteger index = [self indexOf:item.downloadID];
  if (index == NSNotFound) {
    [_items addObject:item];
  } else {
    _items[index] = item;
  }
  return item;
}

#pragma mark Controls

- (void)pauseDownload:(uint32_t)downloadID {
  auto control = _controls.find(downloadID);
  if (control == _controls.end()) return;
  control->second->Pause();
  Watch* watch = [self orphanedWatch:downloadID];
  if (!watch) return;
  // Chromium no longer reports the pause, so it shows here.
  BowDownloadItem* item = _items[[self indexOf:downloadID]];
  if (item.state != BowDownloadStateInProgress && item.state != BowDownloadStateUnknown) return;
  watch->paused = true;
  [self update:[item copyWithState:BowDownloadStatePaused
                     receivedBytes:item.receivedBytes
                      currentSpeed:0
                          fullPath:item.fullPath]];
}

- (void)resumeDownload:(uint32_t)downloadID {
  auto control = _controls.find(downloadID);
  if (control == _controls.end()) return;
  control->second->Resume();
  Watch* watch = [self orphanedWatch:downloadID];
  if (!watch) return;
  BowDownloadItem* item = _items[[self indexOf:downloadID]];
  if (item.state != BowDownloadStatePaused && item.state != BowDownloadStateInterrupted) return;
  watch->paused = false;
  watch->lastChange = CFAbsoluteTimeGetCurrent();
  [self update:[item copyWithState:BowDownloadStateInProgress
                     receivedBytes:item.receivedBytes
                      currentSpeed:0
                          fullPath:item.fullPath]];
  [self startWatchTimer];
}

- (void)cancelDownload:(uint32_t)downloadID {
  auto control = _controls.find(downloadID);
  if (control != _controls.end()) control->second->Cancel();
  // Chromium no longer reports the cancel (which deletes the partial file), so it shows here. An orphan Chromium
  // never reported (its destination was still being chosen when its tab closed) has no control, and CEF aborted it
  // already, so it ends too.
  if ([self orphanedWatch:downloadID]) [self finishOrphan:downloadID state:BowDownloadStateCancelled fullPath:nil];
}

- (void)removeDownload:(uint32_t)downloadID {
  NSUInteger index = [self indexOf:downloadID];
  if (index == NSNotFound) return;
  BowDownloadItem* item = _items[index];
  if (item.state == BowDownloadStateInProgress || item.state == BowDownloadStatePaused) return;
  // An interrupted download could still resume, and one whose status is unknown may still be running; removing
  // either ends it for good.
  if (item.state == BowDownloadStateInterrupted || item.state == BowDownloadStateUnknown) {
    auto control = _controls.find(downloadID);
    if (control != _controls.end()) control->second->Cancel();
  }
  [_items removeObjectAtIndex:index];
  _removed.insert(downloadID);
  _controls.erase(downloadID);
  _destinations.erase(downloadID);
  _cancelled.erase(downloadID);
  _watches.erase(downloadID);
  [self.delegate downloads:self didRemoveItem:item];
  [self releaseIdleBrowsers];
}

#pragma mark Browsers kept alive

- (BOOL)hasActiveDownloadsForBrowser:(int)browserID {
  for (const auto& [downloadID, watch] : _watches) {
    // One whose save panel was answered Cancel is ending, so it keeps nothing alive.
    if (watch.orphaned || !watch.browser || watch.browser->GetIdentifier() != browserID ||
        _cancelled.count(downloadID)) {
      continue;
    }
    NSUInteger index = [self indexOf:downloadID];
    if (index != NSNotFound && IsActive(_items[index].state)) return YES;
  }
  return NO;
}

- (void)whenDownloadsOfBrowserEnd:(int)browserID run:(dispatch_block_t)block {
  if (gEngineStopped) return;
  _keptBrowsers[browserID] = [block copy];
  [self releaseIdleBrowsers];
}

- (BOOL)keepsBrowserAlive:(int)browserID {
  return _keptBrowsers.count(browserID) > 0;
}

- (BOOL)refusesDownloadsFrom:(int)browserID {
  return _keptBrowsers.count(browserID) > 0 || _releasedBrowsers.count(browserID) > 0;
}

- (BOOL)keepsAnyBrowser {
  return !_keptBrowsers.empty();
}

// Runs the block of every kept browser on a later main thread task, at once.
- (void)releaseAllBrowsers {
  for (auto& [browserID, block] : _keptBrowsers) {
    _releasedBrowsers.insert(browserID);
    dispatch_async(dispatch_get_main_queue(), block);
  }
  _keptBrowsers.clear();
  _releaseChecks.clear();
}

// Releases each kept browser with no active download left once the grace has passed and it still has none.
- (void)releaseIdleBrowsers {
  for (const auto& [browserID, block] : _keptBrowsers) {
    if (_releaseChecks.count(browserID) || [self hasActiveDownloadsForBrowser:browserID]) continue;
    _releaseChecks.insert(browserID);
    __weak BowDownloads* weakSelf = self;
    const int checked = browserID;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReleaseGraceSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     [weakSelf finishReleaseCheck:checked];
                   });
  }
}

- (void)finishReleaseCheck:(int)browserID {
  if (_releaseChecks.erase(browserID) == 0 || gEngineStopped) return;
  auto kept = _keptBrowsers.find(browserID);
  // A download running again keeps the browser; its next end checks again.
  if (kept == _keptBrowsers.end() || [self hasActiveDownloadsForBrowser:browserID]) return;
  dispatch_block_t block = kept->second;
  _keptBrowsers.erase(kept);
  _releasedBrowsers.insert(browserID);
  block();
  RunReleaseWaitersIfNoneKept();
}

#pragma mark Downloads whose browser closed

// Notes the browser reporting a running download.
- (void)watch:(uint32_t)downloadID browser:(CefRefPtr<CefBrowser>)browser {
  if (gEngineStopped) return;
  Watch& watch = _watches[downloadID];
  // A report from a live browser is the truth again.
  if (browser) {
    watch.browser = browser;
    watch.orphaned = false;
    watch.paused = false;
  }
}

// A download reported through a browser that has closed already is followed on disk at once. Called once its
// snapshot is stored, which reading it from disk needs.
- (void)followIfBrowserClosed:(CefRefPtr<CefBrowser>)browser {
  if (browser && !browser->IsValid()) [self browserClosed:browser->GetIdentifier()];
}

// The browser `browserID` closed: Chromium says nothing more about its downloads, which are read from disk now.
- (void)browserClosed:(int)browserID {
  _keptBrowsers.erase(browserID);
  _releasedBrowsers.erase(browserID);
  _releaseChecks.erase(browserID);
  RunReleaseWaitersIfNoneKept();
  std::vector<uint32_t> orphans;
  for (const auto& [downloadID, watch] : _watches) {
    if (!watch.orphaned && watch.browser && watch.browser->GetIdentifier() == browserID) orphans.push_back(downloadID);
  }
  if (orphans.empty()) return;
  const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  for (uint32_t downloadID : orphans) [self readOrphan:downloadID now:now];
  [self startWatchTimer];
}

// Starts the watch timer unless it runs. The next read stops it again when no watched download can change.
- (void)startWatchTimer {
  if (!_watchTimer && !gEngineStopped) {
    __weak BowDownloads* weakSelf = self;
    _watchTimer = [NSTimer timerWithTimeInterval:kWatchInterval
                                         repeats:YES
                                           block:^(NSTimer*) {
                                             [weakSelf readOrphans];
                                           }];
    [NSRunLoop.mainRunLoop addTimer:_watchTimer forMode:NSRunLoopCommonModes];
  }
}

// The watch of `downloadID` when its browser has closed and it is in the list, else NULL.
- (Watch*)orphanedWatch:(uint32_t)downloadID {
  auto watch = _watches.find(downloadID);
  if (watch == _watches.end() || !watch->second.orphaned || [self indexOf:downloadID] == NSNotFound) return nullptr;
  return &watch->second;
}

- (void)readOrphans {
  const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  std::vector<uint32_t> orphans;
  for (auto& [downloadID, watch] : _watches) {
    // A download reported without a browser has nothing to outlive, so Chromium keeps reporting it.
    if (watch.orphaned) orphans.push_back(downloadID);
  }
  for (uint32_t downloadID : orphans) [self readOrphan:downloadID now:now];
  // Only orphans are read, and those that cannot change (interrupted ones) do not keep the timer running.
  bool needed = false;
  for (auto& entry : _watches) {
    NSUInteger index = [self indexOf:entry.first];
    if (entry.second.orphaned && index != NSNotFound && NeedsReading(_items[index].state)) {
      needed = true;
      break;
    }
  }
  if (!needed) {
    [_watchTimer invalidate];
    _watchTimer = nil;
  }
}

// Reads one download whose browser closed from its file on disk. CEF has Chromium write straight into the chosen
// path (a `<path>.crdownload` partial file is read too, should Chromium use one, and renamed to the path once every
// byte is saved). Chromium deletes the file when the download is cancelled, which happens when CEF aborts every
// request of a browser it destroys, and keeps it when the download is interrupted.
- (void)readOrphan:(uint32_t)downloadID now:(CFAbsoluteTime)now {
  auto found = _watches.find(downloadID);
  if (found == _watches.end()) return;
  NSUInteger index = [self indexOf:downloadID];
  if (index == NSNotFound) {
    _watches.erase(found);
    return;
  }
  Watch& watch = found->second;
  BowDownloadItem* item = _items[index];
  if (!watch.orphaned) {
    watch.orphaned = true;
    watch.browser = nullptr;
    watch.lastSize = item.receivedBytes;
    watch.lastChange = now;
    watch.lastRead = now;
    watch.orphanedAt = now;
    watch.stateAtOrphan = item.state;
    // Chromium had written bytes, so its file was on disk.
    watch.sawFile = item.receivedBytes > 0;
  }
  // Refused a destination: cancelled, whether or not Chromium got to say so.
  if (_cancelled.count(downloadID)) {
    [self finishOrphan:downloadID state:BowDownloadStateCancelled fullPath:nil];
    return;
  }

  int64_t received = item.receivedBytes;
  auto destination = _destinations.find(downloadID);
  if (destination != _destinations.end()) {
    const std::string& path = destination->second;
    const int64_t partialSize = FileSize(path + ".crdownload");
    double modified = 0;
    const int64_t size = FileSize(path, &modified);
    if (size >= 0 && watch.lastFileSize >= 0 && size > watch.lastFileSize) watch.sawGrowth = true;
    watch.lastFileSize = size;
    if (partialSize >= 0) {
      watch.sawPartial = true;
      watch.sawFile = true;
      watch.completeSize = -1;
      received = partialSize;
    } else if (size >= 0) {
      watch.sawFile = true;
      received = size;
      // A file this download did not write (one already there that the person chose to replace, whose partial file
      // Chromium deleted on cancel) says nothing about it. One it wrote is complete once its partial file was renamed
      // to it or it reached the known size, and stayed so for two reads, since Chromium may still be finishing it.
      const bool written = watch.sawGrowth || (watch.chosenAt > 0 && modified >= watch.chosenAt);
      const bool looksComplete = written && (watch.sawPartial || (item.totalBytes > 0 && size >= item.totalBytes));
      if (looksComplete && watch.completeSize == size) {
        [self finishOrphan:downloadID
                     state:BowDownloadStateComplete
                  fullPath:[NSString stringWithUTF8String:path.c_str()]];
        return;
      }
      watch.completeSize = looksComplete ? size : -1;
    } else if (watch.sawFile) {
      // The file Chromium was writing is gone: it cancelled the download.
      [self finishOrphan:downloadID state:BowDownloadStateCancelled fullPath:nil];
      return;
    }
  }
  if (!watch.sawFile &&
      (watch.stateAtOrphan == BowDownloadStateInProgress || watch.stateAtOrphan == BowDownloadStatePaused) &&
      now - watch.orphanedAt >= kNoFileSeconds) {
    // Its browser closed before Chromium wrote anything (a save panel may still be open): CEF aborted its request
    // (a paused download keeps its request open), and an answer that comes later reaches a download that has
    // ended. One interrupted before its first byte has no request for CEF to abort and can still resume into its
    // file, so it stays as it was.
    [self finishOrphan:downloadID state:BowDownloadStateCancelled fullPath:nil];
    return;
  }

  BowDownloadState state = item.state;
  const CFAbsoluteTime elapsed = now - watch.lastRead;
  int64_t speed = 0;
  if (received != watch.lastSize) {
    if (received > watch.lastSize && elapsed > 0) speed = (int64_t)((received - watch.lastSize) / elapsed);
    watch.lastChange = now;
    // Growing means running, unless a pause asked of Chromium has not taken hold yet.
    if (!watch.paused) state = BowDownloadStateInProgress;
  } else if ((state == BowDownloadStateInProgress || state == BowDownloadStateUnknown) &&
             now - watch.lastChange >= kStallSeconds) {
    // Stalled, failed, or finished under another name: nothing on disk tells which.
    state = BowDownloadStateUnknown;
  }
  watch.lastSize = received;
  watch.lastRead = now;
  if (state == item.state && received == item.receivedBytes && speed == item.currentSpeed) return;
  [self update:[item copyWithState:state receivedBytes:received currentSpeed:speed fullPath:item.fullPath]];
}

// Ends an orphaned download in a final state.
- (void)finishOrphan:(uint32_t)downloadID state:(BowDownloadState)state fullPath:(nullable NSString*)fullPath {
  _watches.erase(downloadID);
  _controls.erase(downloadID);
  _cancelled.erase(downloadID);
  NSUInteger index = [self indexOf:downloadID];
  if (index == NSNotFound) return;
  BowDownloadItem* item = _items[index];
  int64_t received = item.receivedBytes;
  if (state == BowDownloadStateComplete) {
    const int64_t size = FileSize(fullPath.UTF8String ?: "");
    if (size >= 0) received = size;
  }
  [self update:[item copyWithState:state receivedBytes:received currentSpeed:0 fullPath:fullPath ?: item.fullPath]];
}

- (void)update:(BowDownloadItem*)item {
  [self store:item];
  [self.delegate downloads:self didUpdateItem:item];
  [self releaseIdleBrowsers];
}

@end

bool BowDownloadsRefusesDownloadsFrom(int browserID) {
  for (BowDownloads* downloads in BowDownloads.allDownloads) {
    if ([downloads refusesDownloadsFrom:browserID]) return true;
  }
  return false;
}

bool BowDownloadsKeepsBrowserAlive(int browserID) {
  for (BowDownloads* downloads in BowDownloads.allDownloads) {
    if ([downloads keepsBrowserAlive:browserID]) return true;
  }
  return false;
}

void BowDownloadsReleaseKeptBrowsers() {
  for (BowDownloads* downloads in BowDownloads.allDownloads) [downloads releaseAllBrowsers];
  RunReleaseWaitersIfNoneKept();
}

namespace {

bool AnyBrowserKept() {
  for (BowDownloads* downloads in BowDownloads.allDownloads) {
    if ([downloads keepsAnyBrowser]) return true;
  }
  return false;
}

}  // namespace

bool BowDownloadsKeepAnyBrowser() {
  return !gEngineStopped && AnyBrowserKept();
}

void BowDownloadsWhenNoBrowserKept(dispatch_block_t block) {
  if (gEngineStopped) return;
  if (!gReleaseWaiters) gReleaseWaiters = [NSMutableArray array];
  [gReleaseWaiters addObject:[block copy]];
  dispatch_async(dispatch_get_main_queue(), ^{
    RunReleaseWaitersIfNoneKept();
  });
}

void BowDownloadsBrowserClosed(int browserID) {
  if (gEngineStopped) return;
  for (BowDownloads* downloads in BowDownloads.allDownloads) [downloads browserClosed:browserID];
}

void BowDownloadsEngineDidStop() {
  gEngineStopped = true;
  for (BowDownloads* downloads in BowDownloads.allDownloads) [downloads engineDidStop];
}
