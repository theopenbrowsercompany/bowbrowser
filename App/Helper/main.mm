// Entry point for Chromium's helper processes (renderer, GPU, plugin, alerts).
#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  // Start Chromium's macOS sandbox before anything else runs. It loads libcef_sandbox.dylib from the
  // framework and must stay alive for the life of the process. Processes the browser launches without
  // a sandbox (no --seatbelt-client switch) pass through unchanged.
  CefScopedSandboxContext sandboxContext;
  if (!sandboxContext.Initialize(argc, argv)) return 1;

  CefScopedLibraryLoader libraryLoader;
  if (!libraryLoader.LoadInHelper()) return 1;

  CefMainArgs mainArgs(argc, argv);
  return CefExecuteProcess(mainArgs, nullptr, nullptr);
}
