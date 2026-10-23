// App entry point. Chromium has to load and start before AppKit runs, so main lives in the engine.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

#import "BowEngine.h"
#import "BowEngineConfiguration.h"
#import "Bow-Swift.h"
#include "BowEngine+Internal.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/wrapper/cef_library_loader.h"

// Chromium needs NSApplication to report when it is dispatching an event.
@interface BowApplication : NSApplication <CefAppProtocol> {
  BOOL _handlingSendEvent;
}
@end

@implementation BowApplication

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}

// Every way of quitting (Cmd+Q, closing the last window, smoke runs) ends here. The engine closes the browsers
// first, then ends the message loop and main returns. Calling it again while quitting is harmless.
- (void)terminate:(id)sender {
  [BowEngine quit];
}

@end

class BowCefApp : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit BowCefApp(BowEngineConfiguration* configuration) : configuration_(configuration) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  void OnBeforeCommandLineProcessing(const CefString& processType,
                                     CefRefPtr<CefCommandLine> commandLine) override {
    // Keep Chromium out of the login keychain until saved passwords are designed.
    commandLine->AppendSwitch("use-mock-keychain");
    // Sign in requests go to the tab's GetAuthCredentials (and so to the app). Without this switch CEF hands them to
    // Chrome's own login prompt instead, which never calls the handler, fails the load with
    // ERR_INVALID_AUTH_CREDENTIALS and leaves a Chrome window behind that crashes the app when it quits.
    commandLine->AppendSwitch("disable-chrome-login-prompt");
    // Bow has no on-device AI. Chromium's optimization guide still classifies the device 3 minutes after startup by
    // launching the on-device model service, which probes the GPU (logging "Unable to get gpu adapter" as an ERROR
    // when it cannot) and then exits. Pinning the performance class (8 is kGpuBlocked, the value Chrome for Testing
    // assumes) makes the classifier skip that launch, so nothing starts the utility process.
    commandLine->AppendSwitchWithValue("optimization-guide-performance-class", "8");
    [configuration_.extraSwitches enumerateKeysAndObjectsUsingBlock:^(NSString* name, NSString* value, BOOL*) {
      if (value.length == 0) {
        commandLine->AppendSwitch(name.UTF8String);
      } else {
        commandLine->AppendSwitchWithValue(name.UTF8String, value.UTF8String);
      }
    }];
  }

  void OnContextInitialized() override {
    [(AppDelegate*)NSApp.delegate engineDidStart];
  }

 private:
  BowEngineConfiguration* configuration_;

  IMPLEMENT_REFCOUNTING(BowCefApp);
};

int main(int argc, char* argv[]) {
  CefScopedLibraryLoader libraryLoader;
  if (!libraryLoader.LoadInMain()) return 1;

  CefMainArgs mainArgs(argc, argv);
  int exitCode = 0;
  @autoreleasepool {
    [BowApplication sharedApplication];
    AppDelegate* delegate = [[AppDelegate alloc] init];
    NSApp.delegate = delegate;

    // The delegate reads the launch switches and says how to start the engine; nil means it cannot start.
    BowEngineConfiguration* configuration = [delegate engineConfiguration];
    if (!configuration) return BowEngine.exitCode;
    BowEngineStart(configuration);

    NSString* root = configuration.rootDataDirectory;
    CefSettings settings;
    CefString(&settings.root_cache_path) = root.UTF8String;
    CefString(&settings.cache_path) = [root stringByAppendingPathComponent:@"Default"].UTF8String;
    if (configuration.keychainServiceName) {
      CefString(&settings.keychain_service_name) = configuration.keychainServiceName.UTF8String;
    }

    CefRefPtr<BowCefApp> app(new BowCefApp(configuration));
    if (!CefInitialize(mainArgs, settings, app.get(), nullptr)) return CefGetExitCode();
    CefRunMessageLoop();
    // Every page has closed, but quitting closes no window, and Chromium's shutdown below can take seconds on a busy
    // machine: take every window off screen now, so quitting looks done the moment the app stops taking input.
    // Ordering out sends no close callbacks, so nothing reaches the engine or the stores after the loop ended. The main
    // and key windows go last, so AppKit has no other window to make key or main and calls no delegate for it. With
    // the loop gone nothing would finish AppKit's fade out animation, which leaves the window on screen, so it is off.
    NSMutableArray<NSWindow*>* windows = [NSApp.windows mutableCopy];
    for (NSWindow* last in @[ NSApp.mainWindow ?: NSNull.null, NSApp.keyWindow ?: NSNull.null ]) {
      if (![last isKindOfClass:NSWindow.class]) continue;
      [windows removeObject:last];
      [windows addObject:last];
    }
    for (NSWindow* window in windows) {
      window.animationBehavior = NSWindowAnimationBehaviorNone;
      [window orderOut:nil];
    }
    [CATransaction flush];
    BowEngineMessageLoopDidEnd();
    CefShutdown();
    BowEngineDidShutDown();
    [delegate engineDidStop];
    exitCode = BowEngine.exitCode;
  }
  return exitCode;
}
