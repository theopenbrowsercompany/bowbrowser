// The tab's download handler: the profile's downloads handle downloads from every tab and popup of the profile.
#import "BowTab+Internal.h"

CefRefPtr<CefDownloadHandler> BowTabClient::GetDownloadHandler() {
  return downloadHandler_;
}
