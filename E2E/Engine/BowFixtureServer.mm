#import "BowFixtureServer.h"
#include "BowFixtureServer+Internal.h"

#include "BowE2EHooks.h"

#include <sys/stat.h>

#include <cstring>
#include <memory>
#include <string>

#include "include/cef_parser.h"
#include "include/cef_scheme.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_stream_resource_handler.h"

namespace {

const char kFixtureHost[] = "bow.test";

const char kNotFoundBody[] = "Not found";

CefRefPtr<CefResourceHandler> NotFound() {
  CefRefPtr<CefStreamReader> body =
      CefStreamReader::CreateForData(const_cast<char*>(kNotFoundBody), sizeof(kNotFoundBody) - 1);
  return new CefStreamResourceHandler(404, "Not Found", "text/plain", {}, body);
}

const char kRedirectPrefix[] = "/_redirect/";
const char kErrorPrefix[] = "/_error/";
const char kNoContentPrefix[] = "/_204/";
const char kSlowPrefix[] = "/_slow/";

// Calls a read callback later, from a delayed task, unless the request was cancelled meanwhile. Both run on the IO
// thread, so the flag needs no lock.
class ContinueReadTask : public CefTask {
 public:
  ContinueReadTask(CefRefPtr<CefResourceReadCallback> callback, int bytesRead, std::shared_ptr<bool> cancelled)
      : callback_(callback), bytesRead_(bytesRead), cancelled_(std::move(cancelled)) {}
  void Execute() override {
    if (!*cancelled_) callback_->Continue(bytesRead_);
  }

 private:
  CefRefPtr<CefResourceReadCallback> callback_;
  const int bytesRead_;
  const std::shared_ptr<bool> cancelled_;

  IMPLEMENT_REFCOUNTING(ContinueReadTask);
};

// A download that never finishes: an attachment named `fileName` of unknown length, sending a small chunk every
// few milliseconds until it is cancelled, so tests can pause, resume and cancel it while it runs.
class SlowDownloadHandler : public CefResourceHandler {
 public:
  explicit SlowDownloadHandler(std::string fileName) : fileName_(std::move(fileName)) {}

  bool Open(CefRefPtr<CefRequest> request, bool& handleRequest, CefRefPtr<CefCallback> callback) override {
    handleRequest = true;
    return true;
  }

  void GetResponseHeaders(CefRefPtr<CefResponse> response, int64_t& responseLength, CefString& redirectUrl) override {
    responseLength = -1;
    response->SetStatus(200);
    response->SetStatusText("OK");
    response->SetMimeType("application/octet-stream");
    response->SetHeaderByName("Cache-Control", "no-store", true);
    response->SetHeaderByName("Content-Disposition", "attachment; filename=\"" + fileName_ + "\"", true);
  }

  bool Read(void* dataOut, int bytesToRead, int& bytesRead, CefRefPtr<CefResourceReadCallback> callback) override {
    const int chunk = bytesToRead < kChunk ? bytesToRead : kChunk;
    memset(dataOut, 'x', chunk);
    // Asynchronous read: the buffer stays valid until the callback runs.
    bytesRead = 0;
    CefPostDelayedTask(TID_IO, new ContinueReadTask(callback, chunk, cancelled_), kDelayMs);
    return true;
  }

  // A read still waiting in a delayed task must not continue a cancelled request.
  void Cancel() override { *cancelled_ = true; }

 private:
  static constexpr int kChunk = 1024;
  static constexpr int64_t kDelayMs = 20;
  const std::string fileName_;
  const std::shared_ptr<bool> cancelled_ = std::make_shared<bool>(false);

  IMPLEMENT_REFCOUNTING(SlowDownloadHandler);
};

// Answers with no body: with `status` (a 302 redirect to `location`, or a 204), or, when `status` is 0, a failed
// connection (ERR_CONNECTION_REFUSED), which Chromium reports as a failed load.
class EmptyResponseHandler : public CefResourceHandler {
 public:
  explicit EmptyResponseHandler(int status, std::string location = "")
      : status_(status), location_(std::move(location)) {}

  bool Open(CefRefPtr<CefRequest> request, bool& handleRequest, CefRefPtr<CefCallback> callback) override {
    handleRequest = true;
    return true;
  }

  void GetResponseHeaders(CefRefPtr<CefResponse> response, int64_t& responseLength, CefString& redirectUrl) override {
    responseLength = 0;
    if (status_ == 0) {
      response->SetError(ERR_CONNECTION_REFUSED);
      return;
    }
    response->SetStatus(status_);
    // Without a MIME type Chromium treats the empty answer as a download instead of "no content" (harmless on the 302).
    response->SetMimeType("text/plain");
    response->SetStatusText(status_ == 302 ? "Found" : "No Content");
    response->SetHeaderByName("Cache-Control", "no-store", true);
    if (!location_.empty()) redirectUrl = location_;
  }

  bool Read(void* dataOut, int bytesToRead, int& bytesRead, CefRefPtr<CefResourceReadCallback> callback) override {
    bytesRead = 0;
    return false;
  }

  void Cancel() override {}

 private:
  const int status_;
  const std::string location_;

  IMPLEMENT_REFCOUNTING(EmptyResponseHandler);
};

const char kHangPrefix[] = "/_hang/";

// Never answers, so a page that loads it (an image, say) keeps loading until it is stopped or closed.
class HangingResponseHandler : public CefResourceHandler {
 public:
  bool Open(CefRefPtr<CefRequest> request, bool& handleRequest, CefRefPtr<CefCallback> callback) override {
    // Decided later, which never comes; Cancel() lets go of the callback.
    handleRequest = false;
    callback_ = callback;
    return true;
  }

  // Never called, since the callback is never continued; required by the interface.
  void GetResponseHeaders(CefRefPtr<CefResponse> response, int64_t& responseLength, CefString& redirectUrl) override {}
  bool Read(void* dataOut, int bytesToRead, int& bytesRead, CefRefPtr<CefResourceReadCallback> callback) override {
    return false;
  }

  void Cancel() override { callback_ = nullptr; }

 private:
  CefRefPtr<CefCallback> callback_;

  IMPLEMENT_REFCOUNTING(HangingResponseHandler);
};

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
    if (path.rfind(kRedirectPrefix, 0) == 0) {
      return new EmptyResponseHandler(
          302, std::string("https://") + kFixtureHost + "/" + path.substr(sizeof(kRedirectPrefix) - 1));
    }
    if (path.rfind(kErrorPrefix, 0) == 0) return new EmptyResponseHandler(0);
    if (path.rfind(kNoContentPrefix, 0) == 0) return new EmptyResponseHandler(204);
    if (path.rfind(kHangPrefix, 0) == 0) return new HangingResponseHandler();
    if (path.rfind(kSlowPrefix, 0) == 0) {
      std::string fileName = path.substr(sizeof(kSlowPrefix) - 1);
      if (fileName.empty() || fileName.find_first_of("/\"\\") != std::string::npos) return NotFound();
      return new SlowDownloadHandler(fileName);
    }
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
