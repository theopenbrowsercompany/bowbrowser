#import "BowWebView.h"

#include "BowEngine+Internal.h"

@implementation BowWebView {
  BowTab* _tab;
}

- (instancetype)initWithFrame:(NSRect)frame {
  return [super initWithFrame:frame];
}

- (BowTab*)attachedTab {
  // A tab that closed while attached has already lost its view; forget it.
  if (_tab.isClosed) _tab = nil;
  return _tab;
}

- (void)attachTab:(BowTab*)tab {
  // A closing tab's view is being torn down; attaching it would keep its browser alive.
  if (tab.isClosed || tab.willClose || tab == self.attachedTab) return;
  [self detachTab];
  BowWebView* previousHost = (BowWebView*)tab.hostView;
  if (previousHost) [previousHost detachTab];

  _tab = tab;
  tab.hostView = self;
  // A tab whose browser is still being created moves its view here once it exists.
  NSView* browserView = tab.browserView;
  if (!browserView) return;
  // Moving Chromium's view into this one keeps the same page; nothing is created or reloaded.
  browserView.frame = self.bounds;
  browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self addSubview:browserView];
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self sizeParkingView];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self sizeParkingView];
}

// New tabs, until first shown, lay out at the size of the host view used last, so showing one does not reflow it.
// Parked tabs keep the size they were shown at (see detachTab).
- (void)sizeParkingView {
  if (!self.window || NSIsEmptyRect(self.bounds)) return;
  [BowEngineParkingView() setFrameSize:self.bounds.size];
}

- (void)detachTab {
  BowTab* tab = self.attachedTab;
  _tab = nil;
  if (!tab) return;
  tab.hostView = nil;
  // Parked out of every window, Chromium marks the page hidden. (CefBrowserHost::WasHidden only works for
  // windowless browsers, so moving the view out of the window is the signal.)
  // A parked tab keeps the size it was shown at, whatever another window later does to the parking view.
  NSView* browserView = tab.browserView;
  if (!browserView) return;
  browserView.autoresizingMask = NSViewNotSizable;
  [BowEngineParkingView() addSubview:browserView];
}

@end
