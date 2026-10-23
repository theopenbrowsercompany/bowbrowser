#import "BowDownloads.h"

#include <map>
#include <set>
#include <string>

#include "BowEngine+Internal.h"
#include "include/cef_download_handler.h"

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

- (void)dealloc {
  if (_callback) dispatch_async(dispatch_get_main_queue(), _onCancel);
}

@end

#pragma mark - BowDownloads

@interface BowDownloads ()
- (BOOL)allowsDownloadFromURL:(NSString*)url;
- (BOOL)downloadWillBegin:(CefRefPtr<CefDownloadItem>)item
            suggestedName:(NSString*)suggestedName
                 callback:(CefRefPtr<CefBeforeDownloadCallback>)callback;
- (void)downloadUpdated:(CefRefPtr<CefDownloadItem>)item callback:(CefRefPtr<CefDownloadItemCallback>)callback;
@end

// Chromium's download callbacks for every browser of one profile, forwarded to its BowDownloads. They run on the
// main thread because the app uses CefRunMessageLoop.
class BowDownloadHandler : public CefDownloadHandler {
 public:
  explicit BowDownloadHandler(BowDownloads* downloads) : downloads_(downloads) {}

  bool CanDownload(CefRefPtr<CefBrowser> browser, const CefString& url, const CefString& requestMethod) override {
    return [downloads_ allowsDownloadFromURL:ToNSString(url)];
  }

  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> item,
                        const CefString& suggestedName,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    return [downloads_ downloadWillBegin:item suggestedName:ToNSString(suggestedName) callback:callback];
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    [downloads_ downloadUpdated:item callback:callback];
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
}

- (instancetype)initWithProfileID:(NSString*)profileID {
  self = [super init];
  if (self) {
    _profileID = [profileID copy];
    _items = [NSMutableArray array];
    _handler = new BowDownloadHandler(self);
  }
  return self;
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
            suggestedName:(NSString*)suggestedName
                 callback:(CefRefPtr<CefBeforeDownloadCallback>)callback {
  id<BowDownloadsDelegate> delegate = self.delegate;
  // Returning false cancels the download in Alloy style.
  if (!delegate) return NO;
  const uint32_t downloadID = cefItem->GetId();
  // Chromium may report an update first, which already announced the download.
  BOOL isNew = [self indexOf:downloadID] == NSNotFound;
  BowDownloadItem* item = [self store:[self snapshot:cefItem]];
  if (isNew) {
    [delegate downloads:self didCreateItem:item];
  } else {
    [delegate downloads:self didUpdateItem:item];
  }

  __weak BowDownloads* weakSelf = self;
  BowDestinationAnswer* answer = [[BowDestinationAnswer alloc] initWithCallback:callback
                                                                       onCancel:^{
                                                                         [weakSelf destinationRefused:downloadID];
                                                                       }];
  [delegate downloads:self
      chooseDestinationForItem:item
                 suggestedName:suggestedName
             completionHandler:^(NSString* path) {
               dispatch_block_t apply = ^{
                 BowDownloads* strongSelf = weakSelf;
                 if (strongSelf && path.length > 0) strongSelf->_destinations[downloadID] = path.UTF8String;
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
  _cancelled.insert(downloadID);
  auto control = _controls.find(downloadID);
  if (control != _controls.end()) control->second->Cancel();
}

- (void)downloadUpdated:(CefRefPtr<CefDownloadItem>)cefItem callback:(CefRefPtr<CefDownloadItemCallback>)callback {
  const uint32_t downloadID = cefItem->GetId();
  if (_removed.count(downloadID)) return;
  BowDownloadItem* item = [self snapshot:cefItem];
  if (IsFinal(item.state)) {
    _controls.erase(downloadID);
    _cancelled.erase(downloadID);
  } else {
    _controls[downloadID] = callback;
    if (_cancelled.count(downloadID)) callback->Cancel();
  }
  BOOL isNew = [self indexOf:downloadID] == NSNotFound;
  [self store:item];
  id<BowDownloadsDelegate> delegate = self.delegate;
  if (isNew) {
    [delegate downloads:self didCreateItem:item];
  } else {
    [delegate downloads:self didUpdateItem:item];
  }
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
  if (control != _controls.end()) control->second->Pause();
}

- (void)resumeDownload:(uint32_t)downloadID {
  auto control = _controls.find(downloadID);
  if (control != _controls.end()) control->second->Resume();
}

- (void)cancelDownload:(uint32_t)downloadID {
  auto control = _controls.find(downloadID);
  if (control != _controls.end()) control->second->Cancel();
}

- (void)removeDownload:(uint32_t)downloadID {
  NSUInteger index = [self indexOf:downloadID];
  if (index == NSNotFound) return;
  BowDownloadItem* item = _items[index];
  if (item.state == BowDownloadStateInProgress || item.state == BowDownloadStatePaused) return;
  // An interrupted download could still resume; removing it ends it for good.
  if (item.state == BowDownloadStateInterrupted) [self cancelDownload:downloadID];
  [_items removeObjectAtIndex:index];
  _removed.insert(downloadID);
  _controls.erase(downloadID);
  _destinations.erase(downloadID);
  [self.delegate downloads:self didRemoveItem:item];
}

@end
