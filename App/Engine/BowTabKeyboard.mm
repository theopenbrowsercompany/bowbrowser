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
  if (!IsOwn(browser)) return false;
  // The character and key up that follow a claimed key down are the same press: they never reach the page either.
  const bool isKeyDown = event.type == KEYEVENT_RAWKEYDOWN || event.type == KEYEVENT_KEYDOWN;
  if (!isKeyDown && claimedKeyCodes_.count(event.native_key_code) > 0) {
    if (event.type == KEYEVENT_KEYUP) claimedKeyCodes_.erase(event.native_key_code);
    return true;
  }
  if (![tab_ takesUIRequest:@selector(tab:handleKeyBeforePage:)]) return false;
  BowKeyEvent* keyEvent = [[BowKeyEvent alloc] initWithKind:ToKeyEventKind(event.type)
                                                    keyCode:event.native_key_code
                                                 characters:CharacterString(event.character)
                                charactersIgnoringModifiers:CharacterString(event.unmodified_character)
                                                  modifiers:ToKeyModifiers(event.modifiers)
                                            inEditableField:event.focus_on_editable_field];
  const bool claimed = [tab_ handleKeyBeforePage:keyEvent];
  if (isKeyDown) {
    if (claimed) {
      claimedKeyCodes_.insert(event.native_key_code);
    } else {
      claimedKeyCodes_.erase(event.native_key_code);
    }
  }
  return claimed;
}

@implementation BowTab (Keyboard)

- (BOOL)handleKeyBeforePage:(BowKeyEvent*)event {
  id<BowTabUIDelegate> delegate = self.uiDelegate;
  return [delegate respondsToSelector:@selector(tab:handleKeyBeforePage:)] &&
         [delegate tab:self handleKeyBeforePage:event];
}

@end
