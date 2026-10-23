// App entry point. Chromium has to load and start before AppKit runs, so main lives in the engine.
#import <Cocoa/Cocoa.h>

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
    BowEngineMessageLoopDidEnd();
    CefShutdown();
    BowEngineDidShutDown();
    [delegate engineDidStop];
    exitCode = BowEngine.exitCode;
  }
  return exitCode;
}
