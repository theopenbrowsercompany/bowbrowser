#import "BowFixtureServer.h"
#include "BowFixtureServer+Internal.h"

#include "BowE2EHooks.h"

#include <sys/stat.h>

#include <algorithm>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "include/cef_parser.h"
#include "include/cef_scheme.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_stream_resource_handler.h"

namespace {

const char kFixtureHost[] = "bow.test";
// The same files at a second host, another site than bow.test, for tests of links that leave a site (Peek).
const char kOtherSiteHost[] = "other.bow.test";

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

// A slow download: an attachment named `fileName`, sending a small chunk every few milliseconds. With a `length`
// of 0 or less it has no length and never finishes until it is cancelled, so tests can pause, resume and cancel it
// while it runs; otherwise it declares and sends `length` bytes, then ends.
class SlowDownloadHandler : public CefResourceHandler {
 public:
  SlowDownloadHandler(std::string fileName, int64_t length) : fileName_(std::move(fileName)), length_(length) {}

  bool Open(CefRefPtr<CefRequest> request, bool& handleRequest, CefRefPtr<CefCallback> callback) override {
    handleRequest = true;
    return true;
  }

  void GetResponseHeaders(CefRefPtr<CefResponse> response, int64_t& responseLength, CefString& redirectUrl) override {
    responseLength = length_ > 0 ? length_ : -1;
    response->SetStatus(200);
    response->SetStatusText("OK");
    response->SetMimeType("application/octet-stream");
    response->SetHeaderByName("Cache-Control", "no-store", true);
    response->SetHeaderByName("Content-Disposition", "attachment; filename=\"" + fileName_ + "\"", true);
  }

  bool Read(void* dataOut, int bytesToRead, int& bytesRead, CefRefPtr<CefResourceReadCallback> callback) override {
    int chunk = bytesToRead < kChunk ? bytesToRead : kChunk;
    if (length_ > 0) {
      const int64_t left = length_ - sent_;
      if (left <= 0) {
        bytesRead = 0;
        return false;
      }
      if (left < chunk) chunk = static_cast<int>(left);
      sent_ += chunk;
    }
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
  const int64_t length_;
  // Bytes handed out so far, for a download with a length. Read runs on the IO thread only.
  int64_t sent_ = 0;
  const std::shared_ptr<bool> cancelled_ = std::make_shared<bool>(false);

  IMPLEMENT_REFCOUNTING(SlowDownloadHandler);
};

const char kHeldPrefix[] = "/_held/";

class HeldDownloadHandler;

// The held downloads still running and the keys released so far. Open and Read run on a worker sequence while Cancel
// and the releases run on the IO thread (cef_resource_handler.h), so `mutex` guards these and every handler's state.
struct HeldDownloads {
  std::mutex mutex;
  std::vector<CefRefPtr<HeldDownloadHandler>> live;
  std::set<std::string> releasedKeys;
};
HeldDownloads& Held() {
  static auto* held = new HeldDownloads();
  return *held;
}

// A held download: an attachment named `fileName` that declares `length` bytes, sends its first chunk at once, then
// sends nothing more until its `key` is released (BowFixtureServer releaseHeld:), and then sends the rest at full
// speed. So a test sees it provably in progress for as long as it needs, and its end comes when the test says.
class HeldDownloadHandler : public CefResourceHandler {
 public:
  HeldDownloadHandler(std::string key, std::string fileName, int64_t length)
      : key_(std::move(key)), fileName_(std::move(fileName)), length_(length) {}

  const std::string& key() const { return key_; }

  bool Open(CefRefPtr<CefRequest> request, bool& handleRequest, CefRefPtr<CefCallback> callback) override {
    {
      std::lock_guard<std::mutex> lock(Held().mutex);
      released_ = Held().releasedKeys.count(key_) > 0;
      Held().live.push_back(this);
    }
    handleRequest = true;
    return true;
  }

  void GetResponseHeaders(CefRefPtr<CefResponse> response, int64_t& responseLength, CefString& redirectUrl) override {
    responseLength = length_;
    response->SetStatus(200);
    response->SetStatusText("OK");
    response->SetMimeType("application/octet-stream");
    response->SetHeaderByName("Cache-Control", "no-store", true);
    response->SetHeaderByName("Content-Disposition", "attachment; filename=\"" + fileName_ + "\"", true);
  }

  bool Read(void* dataOut, int bytesToRead, int& bytesRead, CefRefPtr<CefResourceReadCallback> callback) override {
    bytesRead = 0;
    std::lock_guard<std::mutex> lock(Held().mutex);
    if (sent_ >= length_) {
      ForgetLocked();
      return false;
    }
    if (sent_ > 0 && !released_) {
      // Held: the buffer stays valid until the callback runs, which ReleaseHold does. Checked and parked under one
      // lock, so a release cannot slip in between and miss it.
      pendingData_ = dataOut;
      pendingSize_ = bytesToRead;
      pendingCallback_ = callback;
      return true;
    }
    bytesRead = FillLocked(dataOut, sent_ == 0 && bytesToRead > kFirstChunk ? kFirstChunk : bytesToRead);
    return true;
  }

  // Lets the download finish: a read waiting for the release continues now. The buffer is filled under the lock, so
  // a Cancel cannot come first, and the callback runs outside it, since it may call Read again.
  void ReleaseHold() {
    CefRefPtr<CefResourceReadCallback> callback;
    int bytes = 0;
    {
      std::lock_guard<std::mutex> lock(Held().mutex);
      released_ = true;
      if (!pendingCallback_) return;
      callback = pendingCallback_;
      pendingCallback_ = nullptr;
      bytes = FillLocked(pendingData_, pendingSize_);
    }
    callback->Continue(bytes);
  }

  void Cancel() override {
    std::lock_guard<std::mutex> lock(Held().mutex);
    pendingCallback_ = nullptr;
    ForgetLocked();
  }

 private:
  static constexpr int kFirstChunk = 1024;

  int FillLocked(void* dataOut, int size) {
    const int64_t left = length_ - sent_;
    const int chunk = left < size ? static_cast<int>(left) : size;
    memset(dataOut, 'x', chunk);
    sent_ += chunk;
    return chunk;
  }

  // Leaves the live list once the download has ended or was cancelled, so nothing keeps the handler. The caller holds
  // the lock, and CEF still holds the handler, so this never drops its last reference.
  void ForgetLocked() {
    auto& live = Held().live;
    live.erase(std::remove(live.begin(), live.end(), CefRefPtr<HeldDownloadHandler>(this)), live.end());
  }

  const std::string key_;
  const std::string fileName_;
  const int64_t length_;
  // Guarded by Held().mutex.
  int64_t sent_ = 0;
  bool released_ = false;
  void* pendingData_ = nullptr;
  int pendingSize_ = 0;
  CefRefPtr<CefResourceReadCallback> pendingCallback_;

  IMPLEMENT_REFCOUNTING(HeldDownloadHandler);
};

// Runs a function on the thread it is posted to.
class FunctionTask : public CefTask {
 public:
  explicit FunctionTask(std::function<void()> function) : function_(std::move(function)) {}
  void Execute() override { function_(); }

 private:
  const std::function<void()> function_;

  IMPLEMENT_REFCOUNTING(FunctionTask);
};

// Releases the held downloads with `key`, and those that start with it later.
void ReleaseHeldOnIO(const std::string& key) {
  std::vector<CefRefPtr<HeldDownloadHandler>> live;
  {
    std::lock_guard<std::mutex> lock(Held().mutex);
    Held().releasedKeys.insert(key);
    live = Held().live;
  }
  for (const auto& handler : live) {
    if (handler->key() == key) handler->ReleaseHold();
  }
}

// Releases every held download and forgets the released keys, so the next test starts with none.
void ReleaseAllHeldOnIO() {
  std::vector<CefRefPtr<HeldDownloadHandler>> live;
  {
    std::lock_guard<std::mutex> lock(Held().mutex);
    Held().releasedKeys.clear();
    live = Held().live;
  }
  for (const auto& handler : live) handler->ReleaseHold();
}

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
      // `/_slow/<name>` never ends; `/_slow/<bytes>/<name>` sends that many bytes, then ends.
      std::string fileName = path.substr(sizeof(kSlowPrefix) - 1);
      int64_t length = 0;
      const size_t slash = fileName.find('/');
      if (slash != std::string::npos) {
        const std::string bytes = fileName.substr(0, slash);
        if (bytes.empty() || bytes.size() > 12 || bytes.find_first_not_of("0123456789") != std::string::npos) {
          return NotFound();
        }
        length = std::stoll(bytes);
        if (length <= 0) return NotFound();
        fileName = fileName.substr(slash + 1);
      }
      if (fileName.empty() || fileName.find_first_of("/\"\\") != std::string::npos) return NotFound();
      return new SlowDownloadHandler(fileName, length);
    }
    if (path.rfind(kHeldPrefix, 0) == 0) {
      // `/_held/<key>/<bytes>/<name>`: sends its first chunk, then holds the rest until `key` is released.
      const std::string rest = path.substr(sizeof(kHeldPrefix) - 1);
      const size_t first = rest.find('/');
      const size_t second = first == std::string::npos ? first : rest.find('/', first + 1);
      if (first == 0 || second == std::string::npos) return NotFound();
      const std::string key = rest.substr(0, first);
      const std::string bytes = rest.substr(first + 1, second - first - 1);
      const std::string fileName = rest.substr(second + 1);
      if (bytes.empty() || bytes.size() > 12 || bytes.find_first_not_of("0123456789") != std::string::npos) {
        return NotFound();
      }
      const int64_t length = std::stoll(bytes);
      if (length <= 0 || fileName.empty() || fileName.find_first_of("/\"\\") != std::string::npos) return NotFound();
      return new HeldDownloadHandler(key, fileName, length);
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
  context->RegisterSchemeHandlerFactory("https", kOtherSiteHost, new FixtureHandlerFactory(root));
}

@implementation BowFixtureServer

+ (void)serveDirectory:(NSString*)directory {
  NSString* root = [directory copy];
  BowEngineObserveProfileContexts([root](CefRefPtr<CefRequestContext> context) { BowServeFixtures(context, root); });
}

+ (void)releaseHeld:(NSString*)key {
  const std::string held = key.UTF8String;
  CefPostTask(TID_IO, new FunctionTask([held] { ReleaseHeldOnIO(held); }));
}

+ (void)releaseAllHeld {
  CefPostTask(TID_IO, new FunctionTask([] { ReleaseAllHeldOnIO(); }));
}

@end
