// Bow's status text where WebKit lacks its hover callback: posts the address of the link under the pointer, or ""
// once the pointer has left every link, whenever it changes. Runs in every frame, in Bow's own content world, so
// the page can neither see nor post to its message handler.
(() => {
  const handler = window.webkit?.messageHandlers?.bowHoverStatus;
  if (!handler) return;
  // Null, not "": the first report of a new document is always posted, so a status left by the page before is
  // cleared by the first move over this one.
  let last = null;
  const post = (text) => {
    if (text === last) return;
    last = text;
    handler.postMessage(text);
  };
  const linkAddress = (node) => {
    const link = node instanceof Element ? node.closest("a[href], area[href]") : null;
    if (!link) return "";
    if (typeof link.href === "string") return link.href;
    // An SVG link's href is an animated string: resolve it as the browser would follow it.
    try {
      return new URL(link.href.baseVal, document.baseURI).href;
    } catch {
      return "";
    }
  };
  document.addEventListener("mouseover", (event) => post(linkAddress(event.target)), true);
  // The pointer left the document (relatedTarget is null): no link is under it in this frame.
  document.addEventListener("mouseout", (event) => {
    if (!event.relatedTarget) post("");
  }, true);
})();
