// Objective-C engine API visible to Swift. Only plain Objective-C headers belong here, never C++ or CEF:
// scripts/check-swift-headers.sh (part of make verify) checks this file and everything it imports.
#import "BowDownloads.h"
#import "BowEngine.h"
#import "BowEngineConfiguration.h"
#import "BowNavigation.h"
#import "BowProfile.h"
#import "BowTab.h"  // Defines BowTab, which the delegate headers below use but only forward declare.
#import "BowTabNavigationDelegate.h"
#import "BowTabUIDelegate.h"
#import "BowTabUIRequests.h"
#import "BowWebView.h"

#if BOW_E2E
#import "BowDevToolsSession.h"  // E2E seam: the harness's engine helpers in E2E/Engine.
#import "BowFixtureServer.h"    // E2E seam
#import "BowChildProcess.h"     // E2E seam
#import "BowPopupParking.h"     // E2E seam
#import "BowLeavePrompts.h"     // E2E seam
#import "BowOpenBrowsers.h"     // E2E seam
#import "BowQuitTiming.h"       // E2E seam
#import "BowLoopbackFixtures.h"  // E2E seam
#import "BowS3Probe.h"          // E2E seam
#import "BowUnloadProbe.h"      // E2E seam
#endif
