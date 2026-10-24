// Bow's edited form signal: posts once per document when the person first edits one of its form fields. Runs in
// every frame, in Bow's own content world, so the page can neither see it nor post to its message handler, and it
// changes nothing the page can reach: it only adds event listeners, which a page cannot list.
//
// The rule: the first trusted input or change event of the document. Only the browser fires trusted ones, for text
// fields, text areas, lists, check boxes, file inputs and editable text, whatever the means (typing, paste, drop,
// dictation, undo, autofill, a chosen file). A page setting a field's value fires no event, and an event the page
// dispatches itself is not trusted, so a page cannot mark itself edited by script.
(() => {
  const handler = window.webkit?.messageHandlers?.bowPageSignals;
  if (!handler) return;
  let edited = false;
  const post = () => {
    try {
      handler.postMessage({ kind: "edited" });
    } catch {}
  };
  const edit = (event) => {
    if (edited || !event.isTrusted || !(event.target instanceof Node)) return;
    edited = true;
    post();
  };
  window.addEventListener("input", edit, true);
  window.addEventListener("change", edit, true);
  // Back from the back and forward cache: the commit cleared the tab's signal, but the document kept its edits.
  window.addEventListener("pageshow", (event) => {
    if (event.persisted && edited) post();
  }, true);
})();
