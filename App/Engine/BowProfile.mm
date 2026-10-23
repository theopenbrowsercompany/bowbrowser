#import "BowProfile.h"

#include "BowEngine+Internal.h"

@implementation BowProfile {
  CefRefPtr<CefRequestContext> _requestContext;
}

- (instancetype)initWithProfileID:(NSString*)profileID
                       persistent:(BOOL)persistent
                   requestContext:(CefRefPtr<CefRequestContext>)requestContext {
  self = [super init];
  if (self) {
    _profileID = [profileID copy];
    _isPersistent = persistent;
    _requestContext = requestContext;
  }
  return self;
}

- (CefRefPtr<CefRequestContext>)requestContext {
  return _requestContext;
}

- (BowTab*)createTabWithURL:(NSURL*)url {
  return [[BowTab alloc] initWithProfile:self url:url];
}

- (void)setPermissionAllowed:(BOOL)allowed forKinds:(BowPermissionKind)kinds origin:(NSURL*)origin {
  static const struct {
    BowPermissionKind kind;
    cef_content_setting_types_t type;
  } kSettings[] = {
      {BowPermissionKindCamera, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA},
      {BowPermissionKindMicrophone, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC},
      {BowPermissionKindGeolocation, CEF_CONTENT_SETTING_TYPE_GEOLOCATION},
      {BowPermissionKindNotifications, CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS},
      {BowPermissionKindClipboard, CEF_CONTENT_SETTING_TYPE_CLIPBOARD_READ_WRITE},
      {BowPermissionKindMIDISysex, CEF_CONTENT_SETTING_TYPE_MIDI_SYSEX},
      {BowPermissionKindStorageAccess, CEF_CONTENT_SETTING_TYPE_STORAGE_ACCESS},
      {BowPermissionKindWindowManagement, CEF_CONTENT_SETTING_TYPE_WINDOW_MANAGEMENT},
      {BowPermissionKindLocalFonts, CEF_CONTENT_SETTING_TYPE_LOCAL_FONTS},
  };
  const CefString url(origin.absoluteString.UTF8String);
  const cef_content_setting_values_t value = allowed ? CEF_CONTENT_SETTING_VALUE_ALLOW : CEF_CONTENT_SETTING_VALUE_BLOCK;
  for (const auto& entry : kSettings) {
    // Requesting and top level URL are the same: the app asks per site, and Chromium scopes each type itself.
    if (kinds & entry.kind) _requestContext->SetContentSetting(url, url, entry.type, value);
  }
}

@end
