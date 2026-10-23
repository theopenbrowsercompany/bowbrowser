// The page signal channel's message, shared by the render process that sends it (BowPageSignals.mm) and the browser
// process that receives it (App/Engine/BowTabPageSignals.mm).
//
// One process message per change, from the frame it concerns: its name is kBowPageSignalMessage, its first argument
// the signal's kind (a string) and its second whether the signal is now on (a bool).
#pragma once

/// The process message's name.
inline constexpr const char* kBowPageSignalMessage = "bow.page-signal";
/// The frame plays sound now: a media element plays with sound, or a running AudioContext is connected to its
/// output. Turned off a short while after the last sound stopped, so a gap between tracks does not turn it off.
inline constexpr const char* kBowPageSignalAudible = "audible";
/// The person edited a form field in the frame's document. Sent once per document, and again when the document
/// comes back from the back/forward cache.
inline constexpr const char* kBowPageSignalFormEdited = "form-edited";
