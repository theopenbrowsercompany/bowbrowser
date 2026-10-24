// Bow's context menu target script. It runs in every frame, in Bow's own content world (BowContextMenu), so the
// page can neither see its message handler nor post to it. On each contextmenu event, in the capture phase on the
// window (before any listener of the page, which loads later), it posts what is under the pointer: the link and its
// text, the image, the frame's selection, and whether the target is a field the person can type in. WebKit posts it
// before it builds its menu, so the tab has it when the menu opens.
(() => {
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bowContextMenu;
  if (!handler) return;
  const typeable = new Set(["", "text", "search", "email", "url", "tel", "password", "number"]);
  const editable = (element) => {
    if (!element) return false;
    if (element.isContentEditable) return true;
    if (element instanceof HTMLTextAreaElement) return !element.disabled && !element.readOnly;
    if (element instanceof HTMLInputElement) {
      return typeable.has((element.getAttribute("type") || "").toLowerCase()) && !element.disabled && !element.readOnly;
    }
    return false;
  };
  window.addEventListener(
    "contextmenu",
    (event) => {
      const node = event.target;
      const element = node instanceof Element ? node : node && node.parentElement;
      const link = element ? element.closest("a[href], area[href]") : null;
      const image = element ? element.closest("img") : null;
      const text = link ? (link.innerText || link.textContent || "").trim() : "";
      handler.postMessage({
        frame: location.href,
        link: link ? link.href : "",
        linkText: text,
        image: image ? image.currentSrc || image.src || "" : "",
        selection: String(getSelection() || ""),
        editable: editable(element),
      });
    },
    true
  );
})();
