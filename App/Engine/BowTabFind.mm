// The tab's CefFindHandler and find in page.
#import "BowTab+Internal.h"

void BowTabClient::OnFindResult(CefRefPtr<CefBrowser> browser,
                                int identifier,
                                int count,
                                const CefRect& selectionRect,
                                int activeMatchOrdinal,
                                bool finalUpdate) {
  if (!IsOwn(browser)) return;
  [tab_ findResultForSearch:identifier count:count activeMatch:activeMatchOrdinal finalUpdate:finalUpdate];
}

@implementation BowTab (Find)

- (void)findResultForSearch:(int)identifier
                      count:(int)count
                activeMatch:(int)activeMatch
                finalUpdate:(BOOL)finalUpdate {
  if (!_findText || identifier < _findIdentifier || identifier <= _findStoppedIdentifier) return;
  _findIdentifier = identifier;
  // Each report carries only what changed: -1 means the count or the position is as last reported.
  if (count >= 0) _findMatchCount = count;
  if (activeMatch >= 0) _findActiveMatch = activeMatch;
  BowFindResult* result = [[BowFindResult alloc] initWithMatchCount:_findMatchCount
                                                        activeMatch:_findActiveMatch
                                                        finalUpdate:finalUpdate];
  id<BowTabUIDelegate> delegate = self.uiDelegate;
  if ([delegate respondsToSelector:@selector(tab:didUpdateFindResult:)]) {
    [delegate tab:self didUpdateFindResult:result];
  }
}

@end
