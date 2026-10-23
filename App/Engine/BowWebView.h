#import <AppKit/AppKit.h>

@class BowTab;

NS_ASSUME_NONNULL_BEGIN

/// A view that shows whichever tab is attached to it. Switching tabs is detaching one and attaching another;
/// the pages keep running and are never reloaded. A detached tab is kept by the engine out of every window, so the
/// page counts as hidden until it is attached again.
NS_SWIFT_UI_ACTOR
@interface BowWebView : NSView

- (instancetype)initWithFrame:(NSRect)frame NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// The tab shown now, or nil.
@property(nonatomic, readonly, nullable) BowTab *attachedTab;

/// Shows `tab`, detaching the tab shown before. A tab attached to another host view is moved here; moving a tab
/// between windows is not supported yet. Does nothing for a closed tab.
- (void)attachTab:(BowTab *)tab NS_SWIFT_NAME(attach(_:));

/// Stops showing the attached tab, which keeps running hidden.
- (void)detachTab NS_SWIFT_NAME(detach());

/// Gives the keyboard to the attached tab's page, if its window allows. Does nothing while no page is shown.
- (void)focusAttachedTab;

@end

NS_ASSUME_NONNULL_END
