#import "BowComponentUpdaterProbe.h"

#include <vector>

#include "include/cef_component_updater.h"

namespace {

NSString* StateName(cef_component_state_t state) {
  switch (state) {
    case CEF_COMPONENT_STATE_NEW: return @"new";
    case CEF_COMPONENT_STATE_CHECKING: return @"checking";
    case CEF_COMPONENT_STATE_CAN_UPDATE: return @"can update";
    case CEF_COMPONENT_STATE_DOWNLOADING: return @"downloading";
    case CEF_COMPONENT_STATE_DECOMPRESSING: return @"decompressing";
    case CEF_COMPONENT_STATE_PATCHING: return @"patching";
    case CEF_COMPONENT_STATE_UPDATING: return @"updating";
    case CEF_COMPONENT_STATE_UPDATED: return @"updated";
    case CEF_COMPONENT_STATE_UP_TO_DATE: return @"up to date";
    case CEF_COMPONENT_STATE_UPDATE_ERROR: return @"update error";
    case CEF_COMPONENT_STATE_RUN: return @"run";
  }
  return [NSString stringWithFormat:@"state %d", static_cast<int>(state)];
}

NSString* ErrorName(cef_component_update_error_t error) {
  switch (error) {
    case CEF_COMPONENT_UPDATE_ERROR_NONE: return @"none";
    case CEF_COMPONENT_UPDATE_ERROR_UPDATE_IN_PROGRESS: return @"update in progress";
    case CEF_COMPONENT_UPDATE_ERROR_UPDATE_CANCELED: return @"update canceled";
    case CEF_COMPONENT_UPDATE_ERROR_RETRY_LATER: return @"retry later";
    case CEF_COMPONENT_UPDATE_ERROR_SERVICE_ERROR: return @"service error";
    case CEF_COMPONENT_UPDATE_ERROR_UPDATE_CHECK_ERROR: return @"update check error";
    case CEF_COMPONENT_UPDATE_ERROR_CRX_NOT_FOUND: return @"crx not found";
    case CEF_COMPONENT_UPDATE_ERROR_INVALID_ARGUMENT: return @"invalid argument";
    case CEF_COMPONENT_UPDATE_ERROR_BAD_CRX_DATA_CALLBACK: return @"bad crx data callback";
  }
  return [NSString stringWithFormat:@"error %d", static_cast<int>(error)];
}

NSString* String(const CefString& value) {
  return [NSString stringWithUTF8String:value.ToString().c_str()] ?: @"";
}

// Hands the result to the Objective-C block. CEF calls it once, on the UI thread, which is the main thread here.
class UpdateCallback : public CefComponentUpdateCallback {
 public:
  explicit UpdateCallback(void (^completion)(NSString*)) : completion_(completion) {}

  void OnComplete(const CefString&, cef_component_update_error_t error) override {
    if (completion_) completion_(ErrorName(error));
    completion_ = nil;
  }

 private:
  void (^completion_)(NSString*);

  IMPLEMENT_REFCOUNTING(UpdateCallback);
};

}  // namespace

@implementation BowE2EComponent

- (instancetype)initWithComponent:(CefRefPtr<CefComponent>)component {
  if ((self = [super init])) {
    _componentID = [String(component->GetID()) copy];
    _name = [String(component->GetName()) copy];
    _version = [String(component->GetVersion()) copy];
    _state = [StateName(component->GetState()) copy];
  }
  return self;
}

@end

@implementation BowComponentUpdaterProbe

+ (BOOL)isAvailable {
  return CefComponentUpdater::GetComponentUpdater() != nullptr;
}

+ (NSArray<BowE2EComponent*>*)registeredComponents {
  CefRefPtr<CefComponentUpdater> updater = CefComponentUpdater::GetComponentUpdater();
  if (!updater) return @[];
  std::vector<CefRefPtr<CefComponent>> components;
  updater->GetComponents(components);
  NSMutableArray<BowE2EComponent*>* result = [NSMutableArray arrayWithCapacity:components.size()];
  for (const auto& component : components) {
    if (component) [result addObject:[[BowE2EComponent alloc] initWithComponent:component]];
  }
  return result;
}

+ (void)checkForUpdateOf:(NSString*)componentID completion:(void (^)(NSString*))completion {
  CefRefPtr<CefComponentUpdater> updater = CefComponentUpdater::GetComponentUpdater();
  if (!updater) {
    completion(@"no updater");
    return;
  }
  updater->Update(componentID.UTF8String, CEF_COMPONENT_UPDATE_PRIORITY_FOREGROUND, new UpdateCallback(completion));
}

@end
