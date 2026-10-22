// App entry point. Chromium has to load and start before AppKit runs, so main lives in the engine.
#import <Cocoa/Cocoa.h>

#import "Bow-Swift.h"
#import "BowEngine.h"
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
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  void OnBeforeCommandLineProcessing(const CefString& processType,
                                     CefRefPtr<CefCommandLine> commandLine) override {
    // Keep Chromium out of the login keychain until saved passwords are designed.
    commandLine->AppendSwitch("use-mock-keychain");
  }

  void OnContextInitialized() override {
    [(AppDelegate*)NSApp.delegate engineDidStart];
  }

 private:
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

    NSString* support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)
                             .firstObject stringByAppendingPathComponent:@"Bow"];
    CefSettings settings;
    // Phase 0 runs without Chromium's sandbox; it must be enabled before any release.
    settings.no_sandbox = true;
    CefString(&settings.root_cache_path) = support.UTF8String;
    CefString(&settings.cache_path) = [support stringByAppendingPathComponent:@"Default"].UTF8String;

    CefRefPtr<BowCefApp> app(new BowCefApp);
    if (!CefInitialize(mainArgs, settings, app.get(), nullptr)) return CefGetExitCode();
    CefRunMessageLoop();
    CefShutdown();
    BowEngineDidShutDown();
    exitCode = BowEngine.exitCode;
  }
  return exitCode;
}
