// The tab's CefPermissionHandler: media access and permission prompts.
#import "BowTab+Internal.h"

namespace {

BowPermissionKind MediaPermissionKinds(uint32_t permissions) {
  BowPermissionKind kinds = 0;
  if (permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) kinds |= BowPermissionKindCamera;
  if (permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) kinds |= BowPermissionKindMicrophone;
  if (permissions & (CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE)) {
    kinds |= BowPermissionKindScreenCapture;
  }
  return kinds ?: BowPermissionKindOther;
}

BowPermissionKind PromptPermissionKinds(uint32_t permissions) {
  const struct {
    uint32_t cef;
    BowPermissionKind kind;
  } known[] = {
      {CEF_PERMISSION_TYPE_CAMERA_STREAM, BowPermissionKindCamera},
      {CEF_PERMISSION_TYPE_MIC_STREAM, BowPermissionKindMicrophone},
      {CEF_PERMISSION_TYPE_GEOLOCATION, BowPermissionKindGeolocation},
      {CEF_PERMISSION_TYPE_NOTIFICATIONS, BowPermissionKindNotifications},
      {CEF_PERMISSION_TYPE_CLIPBOARD, BowPermissionKindClipboard},
      {CEF_PERMISSION_TYPE_MIDI_SYSEX, BowPermissionKindMIDISysex},
      {CEF_PERMISSION_TYPE_STORAGE_ACCESS, BowPermissionKindStorageAccess},
      {CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, BowPermissionKindStorageAccess},
      {CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, BowPermissionKindWindowManagement},
      {CEF_PERMISSION_TYPE_LOCAL_FONTS, BowPermissionKindLocalFonts},
  };
  BowPermissionKind kinds = 0;
  uint32_t unknown = permissions;
  for (const auto& entry : known) {
    if (permissions & entry.cef) kinds |= entry.kind;
    unknown &= ~entry.cef;
  }
  if (unknown || !kinds) kinds |= BowPermissionKindOther;
  return kinds;
}

}  // namespace

bool BowTabClient::OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser,
                                                  CefRefPtr<CefFrame> frame,
                                                  const CefString& requestingOrigin,
                                                  uint32_t requestedPermissions,
                                                  CefRefPtr<CefMediaAccessCallback> callback) {
  if (!IsOwn(browser) || ![tab_ takesUIRequest:@selector(tab:requestPermission:decisionHandler:)]) return false;
  BowPermissionRequest* request =
      [[BowPermissionRequest alloc] initWithRequestingOrigin:BowToNSURL(requestingOrigin)
                                                       kinds:MediaPermissionKinds(requestedPermissions)];
  [tab_ requestPermission:request
                   answer:^(BowPermissionDecision decision) {
                     if (decision == BowPermissionDecisionAllow) {
                       callback->Continue(requestedPermissions);
                     } else {
                       callback->Cancel();
                     }
                   }];
  return true;
}

bool BowTabClient::OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser,
                                          uint64_t promptID,
                                          const CefString& requestingOrigin,
                                          uint32_t requestedPermissions,
                                          CefRefPtr<CefPermissionPromptCallback> callback) {
  if (!IsOwn(browser) || ![tab_ takesUIRequest:@selector(tab:requestPermission:decisionHandler:)]) return false;
  BowPermissionRequest* request =
      [[BowPermissionRequest alloc] initWithRequestingOrigin:BowToNSURL(requestingOrigin)
                                                       kinds:PromptPermissionKinds(requestedPermissions)];
  [tab_ requestPermission:request
                   answer:^(BowPermissionDecision decision) {
                     cef_permission_request_result_t result = CEF_PERMISSION_RESULT_DISMISS;
                     if (decision == BowPermissionDecisionAllow) result = CEF_PERMISSION_RESULT_ACCEPT;
                     if (decision == BowPermissionDecisionDeny) result = CEF_PERMISSION_RESULT_DENY;
                     callback->Continue(result);
                   }];
  return true;
}

@implementation BowTab (Permissions)

- (void)requestPermission:(BowPermissionRequest*)request answer:(void (^)(BowPermissionDecision))answer {
  [self askUIDelegateLater:@selector(tab:requestPermission:decisionHandler:)
      ask:^(BowTab* tab, id<BowTabUIDelegate> delegate) {
        BowAnswerOnce* once = [[BowAnswerOnce alloc] initWithFallback:^{
          answer(BowPermissionDecisionDismiss);
        }];
        [delegate tab:tab
            requestPermission:request
              decisionHandler:^(BowPermissionDecision decision) {
                if (![once claim]) return;
                BowRunOnMain(^{
                  answer(decision);
                });
              }];
      }
      otherwise:^{
        answer(BowPermissionDecisionDismiss);
      }];
}

@end
