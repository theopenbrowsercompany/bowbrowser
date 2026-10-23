#import "BowSpikeContexts.h"

#include <libproc.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <unistd.h>

#include <map>
#include <string>
#include <vector>

#include "BowE2EHooks.h"

namespace {

struct ProfileRecord {
  CFAbsoluteTime created = 0;
  double initialized = -1;
  std::vector<std::string> urls;
};

std::map<std::string, ProfileRecord> gRecords;

class SpikeHandler : public CefRequestContextHandler {
 public:
  explicit SpikeHandler(std::string profileID) : profileID_(std::move(profileID)) {}

  void OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override {
    ProfileRecord& record = gRecords[profileID_];
    record.initialized = CFAbsoluteTimeGetCurrent() - record.created;
  }

  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser> browser,
                                                                 CefRefPtr<CefFrame> frame,
                                                                 CefRefPtr<CefRequest> request,
                                                                 bool is_navigation,
                                                                 bool is_download,
                                                                 const CefString& request_initiator,
                                                                 bool& disable_default_handling) override {
    // Called on the IO thread; hop to the main thread so the record is only touched there.
    std::string profileID = profileID_;
    std::string url = request->GetURL().ToString();
    dispatch_async(dispatch_get_main_queue(), ^{
      gRecords[profileID].urls.push_back(url);
    });
    return nullptr;
  }

 private:
  std::string profileID_;
  IMPLEMENT_REFCOUNTING(SpikeHandler);
};

uint64_t Footprint(pid_t pid) {
  rusage_info_v4 info;
  if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t*)&info) != 0) return 0;
  return info.ri_phys_footprint;
}

}  // namespace

@implementation BowSpikeContexts

+ (double)createProfileWithID:(NSString*)profileID cachePath:(NSString*)cachePath sharedWith:(NSString*)sharedWith {
  std::string key = profileID.UTF8String;
  gRecords[key] = ProfileRecord();
  gRecords[key].created = CFAbsoluteTimeGetCurrent();
  BowProfile* profile = BowEngineCreateSpikeProfile(profileID, cachePath, sharedWith, new SpikeHandler(key));
  if (!profile) return -1;
  return CFAbsoluteTimeGetCurrent() - gRecords[key].created;
}

+ (double)initializationSecondsForProfile:(NSString*)profileID {
  auto it = gRecords.find(profileID.UTF8String);
  return it == gRecords.end() ? -1 : it->second.initialized;
}

+ (NSArray<NSString*>*)requestURLsForProfile:(NSString*)profileID {
  NSMutableArray* urls = [NSMutableArray array];
  auto it = gRecords.find(profileID.UTF8String);
  if (it != gRecords.end()) {
    for (const auto& url : it->second.urls) [urls addObject:@(url.c_str())];
  }
  return urls;
}

+ (NSString*)cachePathOfProfile:(NSString*)profileID {
  CefRefPtr<CefRequestContext> context = BowEngineRequestContextForProfile(profileID);
  return context ? @(context->GetCachePath().ToString().c_str()) : @"";
}

+ (BOOL)profile:(NSString*)profileID sharesStorageWith:(NSString*)otherID {
  CefRefPtr<CefRequestContext> a = BowEngineRequestContextForProfile(profileID);
  CefRefPtr<CefRequestContext> b = BowEngineRequestContextForProfile(otherID);
  return a && b && a->IsSharingWith(b);
}

+ (NSDictionary<NSString*, NSNumber*>*)memorySnapshot {
  static const int kMax = 512;
  pid_t pids[kMax];
  // Returns the number of child pids written.
  int count = proc_listchildpids(getpid(), pids, sizeof(pids));
  if (count < 0) count = 0;
  if (count > kMax) count = kMax;
  uint64_t children = 0;
  int alive = 0;
  for (int i = 0; i < count; i++) {
    uint64_t footprint = Footprint(pids[i]);
    if (footprint > 0) {
      children += footprint;
      alive++;
    }
  }
  double load[3] = {0, 0, 0};
  getloadavg(load, 3);
  return @{
    @"browser" : @(Footprint(getpid())),
    @"children" : @(children),
    @"childCount" : @(alive),
    @"load1" : @(load[0]),
  };
}

@end
