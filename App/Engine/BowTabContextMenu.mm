// The tab's CefContextMenuHandler.
#import "BowTab+Internal.h"

namespace {

// A menu label without its keyboard mnemonic markers: "&Back" reads "Back", and "&&" is a literal ampersand.
NSString* MenuTitle(const CefString& label) {
  std::u16string text = label.ToString16();
  std::u16string plain;
  plain.reserve(text.size());
  for (size_t i = 0; i < text.size(); i++) {
    if (text[i] != u'&') {
      plain += text[i];
    } else if (i + 1 < text.size() && text[i + 1] == u'&') {
      plain += u'&';
      i++;
    }
  }
  return [NSString stringWithCharacters:reinterpret_cast<const unichar*>(plain.data()) length:plain.size()];
}

NSArray<BowContextMenuItem*>* MenuItems(CefRefPtr<CefMenuModel> model) {
  NSMutableArray<BowContextMenuItem*>* items = [NSMutableArray array];
  if (!model) return items;
  for (size_t i = 0; i < model->GetCount(); i++) {
    if (!model->IsVisibleAt(i)) continue;
    const cef_menu_item_type_t type = model->GetTypeAt(i);
    NSArray<BowContextMenuItem*>* submenu = type == MENUITEMTYPE_SUBMENU ? MenuItems(model->GetSubMenuAt(i)) : @[];
    [items addObject:[[BowContextMenuItem alloc] initWithCommandID:model->GetCommandIdAt(i)
                                                             title:MenuTitle(model->GetLabelAt(i))
                                                         isEnabled:model->IsEnabledAt(i)
                                                         isChecked:model->IsCheckedAt(i)
                                                       isSeparator:type == MENUITEMTYPE_SEPARATOR
                                                           submenu:submenu]];
  }
  return items;
}

BowContextMenuMediaType ToMediaType(cef_context_menu_media_type_t type) {
  switch (type) {
    case CM_MEDIATYPE_IMAGE:
      return BowContextMenuMediaTypeImage;
    case CM_MEDIATYPE_VIDEO:
      return BowContextMenuMediaTypeVideo;
    case CM_MEDIATYPE_AUDIO:
      return BowContextMenuMediaTypeAudio;
    case CM_MEDIATYPE_CANVAS:
      return BowContextMenuMediaTypeCanvas;
    case CM_MEDIATYPE_FILE:
      return BowContextMenuMediaTypeFile;
    case CM_MEDIATYPE_PLUGIN:
      return BowContextMenuMediaTypePlugin;
    default:
      return BowContextMenuMediaTypeNone;
  }
}

static_assert(BowContextMenuCommandUndo == MENU_ID_UNDO && BowContextMenuCommandRedo == MENU_ID_REDO &&
                  BowContextMenuCommandCut == MENU_ID_CUT && BowContextMenuCommandCopy == MENU_ID_COPY &&
                  BowContextMenuCommandPaste == MENU_ID_PASTE && BowContextMenuCommandSelectAll == MENU_ID_SELECT_ALL,
              "BowContextMenuCommand must match CEF's menu IDs");
static_assert(BowContextMenuEditFlagsCanUndo == CM_EDITFLAG_CAN_UNDO &&
                  BowContextMenuEditFlagsCanSelectAll == CM_EDITFLAG_CAN_SELECT_ALL,
              "BowContextMenuEditFlags must match CEF's edit flags");

BowContextMenuEditFlags ToEditFlags(int flags) {
  const int known = CM_EDITFLAG_CAN_UNDO | CM_EDITFLAG_CAN_REDO | CM_EDITFLAG_CAN_CUT | CM_EDITFLAG_CAN_COPY |
                    CM_EDITFLAG_CAN_PASTE | CM_EDITFLAG_CAN_DELETE | CM_EDITFLAG_CAN_SELECT_ALL;
  return static_cast<BowContextMenuEditFlags>(flags & known);
}

BowContextMenuTarget ToMenuTargets(int flags) {
  BowContextMenuTarget targets = 0;
  if (flags & CM_TYPEFLAG_PAGE) targets |= BowContextMenuTargetPage;
  if (flags & CM_TYPEFLAG_FRAME) targets |= BowContextMenuTargetFrame;
  if (flags & CM_TYPEFLAG_LINK) targets |= BowContextMenuTargetLink;
  if (flags & CM_TYPEFLAG_MEDIA) targets |= BowContextMenuTargetMedia;
  if (flags & CM_TYPEFLAG_SELECTION) targets |= BowContextMenuTargetSelection;
  if (flags & CM_TYPEFLAG_EDITABLE) targets |= BowContextMenuTargetEditable;
  return targets;
}

}  // namespace

bool BowTabClient::RunContextMenu(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefFrame> frame,
                                  CefRefPtr<CefContextMenuParams> params,
                                  CefRefPtr<CefMenuModel> model,
                                  CefRefPtr<CefRunContextMenuCallback> callback) {
  if (RefusesUIRequest(browser, "context menu")) {
    callback->Cancel();
    return true;
  }
  if (!IsOwn(browser) || ![tab_ takesUIRequest:@selector(tab:runContextMenu:completionHandler:)]) return false;
  // The params and model are valid only during this call, so everything is copied out now.
  BowContextMenuRequest* request =
      [[BowContextMenuRequest alloc] initWithLocation:CGPointMake(params->GetXCoord(), params->GetYCoord())
                                              targets:ToMenuTargets(params->GetTypeFlags())
                                            mediaType:ToMediaType(params->GetMediaType())
                                              pageURL:BowToNSURL(params->GetPageUrl())
                                             frameURL:BowToNSURL(params->GetFrameUrl())
                                              linkURL:BowToNSURL(params->GetLinkUrl())
                                            sourceURL:BowToNSURL(params->GetSourceUrl())
                                        selectionText:BowToNSString(params->GetSelectionText())
                                           isEditable:params->IsEditable()
                                            editFlags:ToEditFlags(params->GetEditStateFlags())
                                         defaultItems:MenuItems(model)];
  [tab_ runContextMenu:request callback:callback];
  return true;
}

@implementation BowTab (ContextMenu)

- (void)runContextMenu:(BowContextMenuRequest*)request callback:(CefRefPtr<CefRunContextMenuCallback>)callback {
  void (^answer)(NSInteger) = ^(NSInteger commandID) {
    if (commandID == BowContextMenuNoCommand) {
      callback->Cancel();
    } else {
      callback->Continue(static_cast<int>(commandID), EVENTFLAG_NONE);
    }
  };
  [self askUIDelegateLater:@selector(tab:runContextMenu:completionHandler:)
      ask:^(BowTab* tab, id<BowTabUIDelegate> delegate) {
        BowAnswerOnce* once = [[BowAnswerOnce alloc] initWithFallback:^{
          answer(BowContextMenuNoCommand);
        }];
        [delegate tab:tab
               runContextMenu:request
            completionHandler:^(NSInteger commandID) {
              if (![once claim]) return;
              BowRunOnMain(^{
                answer(commandID);
              });
            }];
      }
      otherwise:^{
        answer(BowContextMenuNoCommand);
      }];
}

@end
