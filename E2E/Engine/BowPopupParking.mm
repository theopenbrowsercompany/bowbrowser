#import "BowPopupParking.h"

#include "BowE2EHooks.h"

@implementation BowPopupParking

+ (void)start {
  BowEngineParkPopups();
}

+ (void)hostPopupsIn:(NSView* _Nullable (^_Nullable)(void))host {
  BowEngineHostPopups(host);
}

+ (BOOL)closePopupInView:(NSView*)view {
  return BowEngineClosePopupInView(view);
}

+ (nullable NSAlert*)dialogOnWindow:(NSWindow*)window {
  return BowEnginePopupDialogOnWindow(window);
}

@end
