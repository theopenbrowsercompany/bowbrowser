// The render process side of the page signal channel (see BowPageSignalNames.h): a script installed in every
// frame's JavaScript context reports when the frame plays sound and when the person edits one of its form fields,
// through a native function that sends a process message to the browser.
//
// The script runs as each context is created, before the page's own scripts, so its listeners come first. It must
// stay invisible to the page, because a browser a site can tell apart from Chrome gets singled out by tamper and
// fingerprint checks (CAPTCHAs, blocks):
// - It changes no object the page can reach: no prototype, no method, no global. It only adds event listeners,
//   which a page cannot list.
// - Every built-in it uses later (listener registration, the media and event getters, the collections, timers) is
//   taken and bound while it installs, before any page script can replace one, so it never looks up a property the
//   page could have redefined to notice it.
// - Its listeners catch every error, so none reaches the page's error handlers.
// The native function is handed to the script as an argument and never set on the page's global object, so the
// page cannot call it.
#include "BowPageSignals.h"

#include "BowPageSignalNames.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_v8.h"

namespace {

// The script, evaluated to a function that takes the native signal function. Its rules:
// - Sound: the frame plays sound while a media element plays (not paused, not ended) unmuted at a volume above 0.
//   Elements are followed from their media events (play, playing, pause, ended, volumechange, emptied), which reach
//   the window in the capture phase while the element is in the frame's document; once followed, an element's own
//   events keep it looked at after it leaves the document. Followed elements are held weakly and let go once
//   stopped. Sound starting is reported at once; sound stopping only once the frame has stayed quiet for kQuietMs,
//   so the gap between two tracks does not turn it off.
//   Not seen, since that would take changing what the page sees: Web Audio, a media element that never was in the
//   document (new Audio().play()), and one inside a shadow tree (its media events do not leave the tree).
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
  // A built-in method as a plain function taking its receiver first, bound now so calling it later looks nothing up.
  const method = Function.prototype.call.bind(Function.prototype.bind, Function.prototype.call);
  const getter = (type, name) => method(Object.getOwnPropertyDescriptor(type.prototype, name).get);
  const later = setTimeout;
  const cancel = clearTimeout;
  const listen = method(EventTarget.prototype.addEventListener);
  const eventTarget = getter(Event, "target");
  const nodeType = getter(Node, "nodeType");
  const persisted = getter(PageTransitionEvent, "persisted");
  const WeakRefType = WeakRef;
  const deref = method(WeakRef.prototype.deref);
  const mapSet = method(Map.prototype.set);
  const mapDelete = method(Map.prototype.delete);
  const mapForEach = method(Map.prototype.forEach);
  const weakHas = method(WeakSet.prototype.has);
  const weakAdd = method(WeakSet.prototype.add);
  const weakDelete = method(WeakSet.prototype.delete);
  const MediaElement = window.HTMLMediaElement;
  const paused = MediaElement ? getter(MediaElement, "paused") : null;
  const ended = MediaElement ? getter(MediaElement, "ended") : null;
  const muted = MediaElement ? getter(MediaElement, "muted") : null;
  const volume = MediaElement ? getter(MediaElement, "volume") : null;
  const mediaEvents = ["play", "playing", "pause", "ended", "volumechange", "emptied"];

  // Elements that may be playing, by a number of their own, held weakly.
  const media = new Map();
  const listed = new WeakSet();
  // Elements carrying the script's own media listeners.
  const followed = new WeakSet();
  let nextID = 0;
  let audible = false;
  let quietTimer = 0;
  let edited = false;

  // `body` as a listener that lets no error reach the page.
  const quietly = (body) => (event) => {
    try { body(event); } catch (error) {}
  };
  const send = (kind, on) => {
    try { signal(kind, on); } catch (error) {}
  };
  // Whether a media element plays now. Visits every entry, letting go of elements that stopped or that the page let
  // go of, so the script keeps nothing alive the page no longer uses.
  const playingNow = () => {
    let playing = false;
    mapForEach(media, (reference, id) => {
      const element = deref(reference);
      if (!element) {
        mapDelete(media, id);
      } else if (paused(element) || ended(element)) {
        mapDelete(media, id);
        weakDelete(listed, element);
      } else if (!muted(element) && volume(element) > 0) {
        playing = true;
      }
    });
    return playing;
  };
  const update = () => {
    if (playingNow()) {
      if (quietTimer) { cancel(quietTimer); quietTimer = 0; }
      if (!audible) { audible = true; send("audible", true); }
    } else if (audible && !quietTimer) {
      quietTimer = later(quietly(() => {
        quietTimer = 0;
        if (!playingNow()) { audible = false; send("audible", false); }
        else { update(); }
      }), kQuietMs);
    }
  };
  const onElementEvent = quietly(update);
  // Whether `target` is a media element of this frame, asked of the native getter so nothing the page set answers.
  const isMedia = (target) => {
    try { paused(target); return true; } catch (error) { return false; }
  };
  const followElement = (element) => {
    if (!weakHas(followed, element)) {
      weakAdd(followed, element);
      for (let i = 0; i < mediaEvents.length; i++) listen(element, mediaEvents[i], onElementEvent);
    }
    if (!weakHas(listed, element)) {
      weakAdd(listed, element);
      mapSet(media, nextID++, new WeakRefType(element));
    }
    update();
  };
  if (MediaElement) {
    const onMediaEvent = quietly((event) => {
      const target = eventTarget(event);
      if (isMedia(target)) followElement(target);
    });
    for (let i = 0; i < mediaEvents.length; i++) listen(window, mediaEvents[i], onMediaEvent, true);
  }

  const edit = quietly((event) => {
    if (edited || !event.isTrusted) return;
    try { nodeType(eventTarget(event)); } catch (error) { return; }
    edited = true;
    send("form-edited", true);
  });
  listen(window, "input", edit, true);
  listen(window, "change", edit, true);

  // Back from the cache, sound is looked at afresh rather than resent as it was when the page left.
  listen(window, "pageshow", quietly((event) => {
    if (!persisted(event)) return;
    if (edited) send("form-edited", true);
    if (quietTimer) { cancel(quietTimer); quietTimer = 0; }
    audible = false;
    update();
  }), true);
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
