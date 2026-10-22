#import "BowFixtureServer.h"
#include "BowFixtureServer+Internal.h"

#include "BowE2EHooks.h"

#include <sys/stat.h>

#include <string>

#include "include/cef_parser.h"
#include "include/cef_scheme.h"
#include "include/wrapper/cef_stream_resource_handler.h"

namespace {

const char kFixtureHost[] = "bow.test";

const char kNotFoundBody[] = "Not found";

CefRefPtr<CefResourceHandler> NotFound() {
  CefRefPtr<CefStreamReader> body =
      CefStreamReader::CreateForData(const_cast<char*>(kNotFoundBody), sizeof(kNotFoundBody) - 1);
  return new CefStreamResourceHandler(404, "Not Found", "text/plain", {}, body);
}

// Creates a handler for each request to https://bow.test/. Runs on Chromium's IO thread, so it keeps only an
// immutable copy of the directory path.
class FixtureHandlerFactory : public CefSchemeHandlerFactory {
 public:
  explicit FixtureHandlerFactory(std::string directory) : directory_(std::move(directory)) {}

  CefRefPtr<CefResourceHandler> Create(CefRefPtr<CefBrowser> browser,
                                       CefRefPtr<CefFrame> frame,
                                       const CefString& schemeName,
                                       CefRefPtr<CefRequest> request) override {
    CefURLParts parts;
    if (!CefParseURL(request->GetURL(), parts)) return NotFound();
    std::string path =
        CefURIDecode(CefString(&parts.path), true,
                     static_cast<cef_uri_unescape_rule_t>(UU_SPACES | UU_URL_SPECIAL_CHARS_EXCEPT_PATH_SEPARATORS))
            .ToString();
    // Never leave the fixture directory.
    if (path.empty() || path[0] != '/' || path.find("..") != std::string::npos) return NotFound();
    if (path.back() == '/') path += "index.html";

    const std::string file = directory_ + path;
    struct stat info;
    if (stat(file.c_str(), &info) != 0 || !S_ISREG(info.st_mode)) return NotFound();
    CefRefPtr<CefStreamReader> stream = CefStreamReader::CreateForFile(file);
    if (!stream) return NotFound();

    const size_t dot = path.find_last_of('.');
    std::string mimeType = dot == std::string::npos ? "" : CefGetMimeType(path.substr(dot + 1)).ToString();
    if (mimeType.empty()) mimeType = "application/octet-stream";
    CefResponse::HeaderMap headers;
    headers.insert({"Cache-Control", "no-store"});
    return new CefStreamResourceHandler(200, "OK", mimeType, headers, stream);
  }

 private:
  const std::string directory_;

  IMPLEMENT_REFCOUNTING(FixtureHandlerFactory);
};

}  // namespace

void BowServeFixtures(CefRefPtr<CefRequestContext> context, NSString* directory) {
  std::string root = directory.stringByStandardizingPath.UTF8String;
  context->RegisterSchemeHandlerFactory("https", kFixtureHost, new FixtureHandlerFactory(root));
}

@implementation BowFixtureServer

+ (void)serveDirectory:(NSString*)directory {
  NSString* root = [directory copy];
  BowEngineObserveProfileContexts([root](CefRefPtr<CefRequestContext> context) { BowServeFixtures(context, root); });
}

@end
