// Bow's site icon signal: posts the address of the main frame's icon once the document is parsed, and again
// whenever it changes. Runs in the main frame, in Bow's own content world, so the page can neither see it nor post
// to its message handler.
//
// The icon is the first link whose rel lists "icon" ("icon", "shortcut icon") and that has an address; without
// one, an http or https page falls back to /favicon.ico on its own origin, and any other page has none (null).
(() => {
  const handler = window.webkit?.messageHandlers?.bowPageSignals;
  if (!handler) return;
  // Undefined, not null: the first report of a document is always posted.
  let last;
  const current = () => {
    for (const link of document.querySelectorAll("link[rel][href]")) {
      if (link.relList.contains("icon") && link.href) return link.href;
    }
    const { protocol, origin } = location;
    return protocol === "http:" || protocol === "https:" ? new URL("/favicon.ico", origin).href : null;
  };
  const report = () => {
    const url = current();
    if (url === last) return;
    last = url;
    try {
      handler.postMessage({ kind: "favicon", url });
    } catch {}
  };
  // Only a change that touches a link element can change the icon, so other changes cost one pass over the records.
  // A link counts inside an added or removed subtree too.
  const isLink = (node) =>
    node.nodeName === "LINK" || (node instanceof Element && node.querySelector("link") !== null);
  const touchesLink = (records) =>
    records.some((record) =>
      isLink(record.target) || [...record.addedNodes].some(isLink) || [...record.removedNodes].some(isLink));
  const start = () => {
    report();
    new MutationObserver((records) => {
      if (touchesLink(records)) report();
    }).observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ["rel", "href"] });
  };
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
  // Back from the back and forward cache, after another page's icon: report this one again.
  window.addEventListener("pageshow", (event) => {
    if (!event.persisted) return;
    last = undefined;
    report();
  }, true);
})();
