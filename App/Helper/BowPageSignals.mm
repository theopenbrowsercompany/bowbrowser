// The render process side of the page signal channel (see BowPageSignalNames.h): a script installed in every
// frame's JavaScript context reports when the frame plays sound and when the person edits one of its form fields,
// through a native function that sends a process message to the browser.
//
// The script runs as each context is created, before the page's own scripts, so its listeners come first and the
// media and Web Audio methods it wraps are the ones the page gets. The native function is handed to the script as an
// argument and never set on the page's global object, so the page cannot call it.
#include "BowPageSignals.h"

#include "BowPageSignalNames.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_v8.h"

namespace {

// The script, evaluated to a function that takes the native signal function. Its rules:
// - Sound: the frame plays sound while a media element plays (not paused, not ended) unmuted at a volume above 0, or
//   while an AudioContext connected to its output runs. Elements are followed from their media events, which reach
//   the window in the capture phase when they are in a document, and from play() for those that are not; contexts
//   from AudioNode.connect to their destination. Sound starting is reported at once; sound stopping only once the
//   frame has stayed quiet for kQuietMs, so the gap between two tracks does not turn it off.
// - Form edit: the first trusted input or change event of the document. Only the browser fires trusted ones, and
//   only for text fields, text areas, lists, check boxes, file inputs and editable text (a field inside a shadow tree
//   reaches the window as its host), whatever the means: typing, paste, drop, dictation, undo, autofill, a chosen
//   file. The page's own synthetic events are not trusted, so a page cannot mark itself edited by script.
// - A document restored from the back/forward cache reports both again, since the browser forgets a frame that
//   leaves for that cache.
constexpr const char* kScript = R"JS(
(function (signal) {
  "use strict";
  const kQuietMs = 2000;
  const later = setTimeout;
  const cancel = clearTimeout;
  const listen = EventTarget.prototype.addEventListener;
  const MediaElement = window.HTMLMediaElement;
  const AudioContextType = window.AudioContext;
  const DestinationNode = window.AudioDestinationNode;
  const media = new Set();
  const followed = new WeakSet();
  // Contexts connected to their output, held weakly: a context the page dropped is not kept for its sound.
  const contexts = new Set();
  const followedContexts = new WeakSet();
  let audible = false;
  let quietTimer = 0;
  let edited = false;

  const send = (kind, on) => {
    try { signal(kind, on); } catch (error) {}
  };
  // Whether anything plays now. Visits every entry, letting go of elements that stopped and contexts that closed or
  // that the page let go of, so the script keeps nothing alive the page no longer uses.
  const playingNow = () => {
    let playing = false;
    for (const element of media) {
      if (element.paused || element.ended) {
        media.delete(element);
      } else if (!element.muted && element.volume > 0) {
        playing = true;
      }
    }
    for (const reference of contexts) {
      const context = reference.deref();
      if (!context || context.state === "closed") {
        contexts.delete(reference);
      } else if (context.state === "running") {
        playing = true;
      }
    }
    return playing;
  };
  const update = () => {
    if (playingNow()) {
      if (quietTimer) { cancel(quietTimer); quietTimer = 0; }
      if (!audible) { audible = true; send("audible", true); }
    } else if (audible && !quietTimer) {
      quietTimer = later(() => {
        quietTimer = 0;
        if (!playingNow()) { audible = false; send("audible", false); }
        else { update(); }
      }, kQuietMs);
    }
  };
  const mediaEvents = ["play", "playing", "pause", "ended", "volumechange", "emptied"];
  const followElement = (element) => {
    if (!followed.has(element)) {
      followed.add(element);
      for (const type of mediaEvents) listen.call(element, type, update);
    }
    media.add(element);
    update();
  };
  if (MediaElement) {
    for (const type of mediaEvents) {
      listen.call(window, type, (event) => {
        if (event.target instanceof MediaElement) followElement(event.target);
      }, true);
    }
    const play = MediaElement.prototype.play;
    MediaElement.prototype.play = function () {
      const result = play.apply(this, arguments);
      followElement(this);
      return result;
    };
  }
  if (AudioContextType && DestinationNode && window.AudioNode) {
    const connect = AudioNode.prototype.connect;
    AudioNode.prototype.connect = function (target) {
      const result = connect.apply(this, arguments);
      const context = target instanceof DestinationNode ? target.context : null;
      if (context instanceof AudioContextType && !followedContexts.has(context)) {
        followedContexts.add(context);
        contexts.add(new WeakRef(context));
        listen.call(context, "statechange", update);
      }
      update();
      return result;
    };
  }

  const edit = (event) => {
    if (edited || !event.isTrusted || !(event.target instanceof Node)) return;
    edited = true;
    send("form-edited", true);
  };
  listen.call(window, "input", edit, true);
  listen.call(window, "change", edit, true);

  // Back from the cache, sound is looked at afresh rather than resent as it was when the page left.
  listen.call(window, "pageshow", (event) => {
    if (!event.persisted) return;
    if (edited) send("form-edited", true);
    if (quietTimer) { cancel(quietTimer); quietTimer = 0; }
    audible = false;
    update();
  }, true);
})
)JS";

// Sends one signal to the browser from `frame`.
void Send(CefRefPtr<CefFrame> frame, const CefString& kind, bool on) {
  if (!frame || !frame->IsValid()) return;
  CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kBowPageSignalMessage);
  CefRefPtr<CefListValue> values = message->GetArgumentList();
  values->SetString(0, kind);
  values->SetBool(1, on);
  frame->SendProcessMessage(PID_BROWSER, message);
}

// The native function the script calls as signal(kind, on): sends the change to the browser from the frame whose
// context is running the script.
class SignalHandler : public CefV8Handler {
 public:
  bool Execute(const CefString& name,
               CefRefPtr<CefV8Value> object,
               const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>& retval,
               CefString& exception) override {
    if (arguments.size() != 2 || !arguments[0]->IsString() || !arguments[1]->IsBool()) return true;
    CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
    Send(context ? context->GetFrame() : nullptr, arguments[0]->GetStringValue(), arguments[1]->GetBoolValue());
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(SignalHandler);
};

class HelperApp : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    CefRefPtr<CefV8Value> install;
    CefRefPtr<CefV8Exception> exception;
    if (!context->Eval(kScript, CefString(), 0, install, exception) || !install || !install->IsFunction()) return;
    CefV8ValueList arguments{CefV8Value::CreateFunction("signal", new SignalHandler())};
    install->ExecuteFunctionWithContext(context, nullptr, arguments);
  }

  // The document is going: whatever it reported ends with it, even when its frame keeps its identifier for the next
  // document, and even mid sound (its quiet timer goes with it). Messages from one frame arrive in order, so this
  // reaches the browser before anything the next document reports.
  void OnContextReleased(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override {
    Send(frame, kBowPageSignalReleased, false);
  }

 private:
  IMPLEMENT_REFCOUNTING(HelperApp);
};

}  // namespace

CefRefPtr<CefApp> BowHelperApp() {
  return new HelperApp();
}
