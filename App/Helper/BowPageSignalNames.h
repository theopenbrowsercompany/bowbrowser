// The page signal channel's message, shared by the render process that sends it (BowPageSignals.mm) and the browser
// process that receives it (App/Engine/BowTabPageSignals.mm).
//
// One process message per change, from the frame it concerns: its name is kBowPageSignalMessage, its first argument
// the signal's kind (a string) and its second whether the signal is now on (a bool).
#pragma once

/// The process message's name.
inline constexpr const char* kBowPageSignalMessage = "bow.page-signal";
/// The frame plays sound now: one of its media elements plays with sound (Web Audio is not seen). Turned off a
/// short while after the last sound stopped, so a gap between tracks does not turn it off.
inline constexpr const char* kBowPageSignalAudible = "audible";
/// The person edited a form field in the frame's document. Sent once per document, and again when the document
/// comes back from the back/forward cache.
inline constexpr const char* kBowPageSignalFormEdited = "form-edited";
/// The frame's document is going (its JavaScript context is released): every signal of the frame ends, sent with
/// `on` false. A frame that keeps its identifier for its next document (a same-site navigation in the same frame)
/// sends it before the next document's own signals, so the old document's never outlive it.
inline constexpr const char* kBowPageSignalReleased = "released";
