// The tab's CefKeyboardHandler: key events the app may claim before the page sees them.
#import "BowTab+Internal.h"

namespace {

NSString* CharacterString(char16_t character) {
  if (character == 0) return @"";
  const unichar value = character;
  return [NSString stringWithCharacters:&value length:1];
}

BowKeyModifiers ToKeyModifiers(uint32_t flags) {
  BowKeyModifiers modifiers = 0;
  if (flags & EVENTFLAG_SHIFT_DOWN) modifiers |= BowKeyModifierShift;
  if (flags & EVENTFLAG_CONTROL_DOWN) modifiers |= BowKeyModifierControl;
  if (flags & EVENTFLAG_ALT_DOWN) modifiers |= BowKeyModifierOption;
  if (flags & EVENTFLAG_COMMAND_DOWN) modifiers |= BowKeyModifierCommand;
  return modifiers;
}

BowKeyEventKind ToKeyEventKind(cef_key_event_type_t type) {
  switch (type) {
    case KEYEVENT_KEYUP:
      return BowKeyEventKindKeyUp;
    case KEYEVENT_CHAR:
      return BowKeyEventKindCharacter;
    default:
      return BowKeyEventKindKeyDown;
  }
}

}  // namespace

bool BowTabClient::OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                                 const CefKeyEvent& event,
                                 CefEventHandle osEvent,
                                 bool* isKeyboardShortcut) {
  if (!IsOwn(browser) || ![tab_ takesUIRequest:@selector(tab:handleKeyBeforePage:)]) return false;
  BowKeyEvent* keyEvent = [[BowKeyEvent alloc] initWithKind:ToKeyEventKind(event.type)
                                                    keyCode:event.native_key_code
                                                 characters:CharacterString(event.character)
                                charactersIgnoringModifiers:CharacterString(event.unmodified_character)
                                                  modifiers:ToKeyModifiers(event.modifiers)
                                            inEditableField:event.focus_on_editable_field];
  return [tab_ handleKeyBeforePage:keyEvent];
}

@implementation BowTab (Keyboard)

- (BOOL)handleKeyBeforePage:(BowKeyEvent*)event {
  id<BowTabUIDelegate> delegate = self.uiDelegate;
  return [delegate respondsToSelector:@selector(tab:handleKeyBeforePage:)] &&
         [delegate tab:self handleKeyBeforePage:event];
}

@end
