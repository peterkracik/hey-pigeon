<script lang="ts">
  // Renders (mock) HTML mail. sandbox without allow-scripts blocks JS but
  // allow-same-origin keeps the height measurable from the parent.
  // ponytail: no sanitization yet — mock data only; ammonia in the Rust core
  // must sanitize before real mail ever reaches this frame (DESIGN.md Security).
  let { html }: { html: string } = $props();

  let frame: HTMLIFrameElement | undefined = $state();

  function resize() {
    if (frame?.contentWindow) {
      // Reset first: documentElement.scrollHeight is clamped to the viewport
      // (the iframe's current height), so a tall frame could never shrink.
      const prev = frame.style.height;
      try {
        frame.style.height = "0";
        frame.style.height = frame.contentWindow.document.documentElement.scrollHeight + "px";
      } catch {
        frame.style.height = prev; /* cross-origin — keep prior height */
      }
    }
  }

  // True when no visible content (text or images/rules) follows `el` in `body`.
  // Elements come from the iframe's own document, so `instanceof
  // Element`/`HTMLElement` always fails here — those globals are per-realm
  // and this script runs in the parent realm. Use nodeType/duck-typing instead.
  function isTrailing(el: Node, body: Node): boolean {
    let node: Node | null = el;
    while (node && node !== body) {
      let sib = node.nextSibling;
      while (sib) {
        if (sib.textContent?.trim()) return false;
        if (sib.nodeType === 1) {
          const elSib = sib as Element;
          if (elSib.querySelector("img,svg,hr")) return false;
          if (/^(img|svg|hr)$/i.test(elSib.tagName)) return false;
        }
        sib = sib.nextSibling;
      }
      node = node.parentNode;
    }
    return node === body;
  }

  // Outermost trailing quote container: div.gmail_quote or a trailing <blockquote>.
  function findTrailingQuote(body: HTMLElement): HTMLElement | null {
    const candidates: HTMLElement[] = [];
    // Outlook web/mobile wraps the quoted history in this id instead of
    // gmail_quote/blockquote — check it first since it's the outermost.
    const outlookRef = body.querySelector('div[id="mail-editor-reference-message-container"]');
    if (outlookRef) candidates.push(outlookRef as HTMLElement);
    const gq = body.querySelector("div.gmail_quote");
    if (gq) candidates.push(gq as HTMLElement);
    const bqs = body.querySelectorAll("blockquote");
    const lastBq = bqs[bqs.length - 1];
    if (lastBq) candidates.push(lastBq as HTMLElement);
    for (const el of candidates) {
      if (isTrailing(el, body)) return el;
    }
    return null;
  }

  // Scripts inside srcdoc are blocked by the sandbox, so quote-collapsing is
  // done from the parent reaching into the same-origin iframe document.
  function collapseQuote() {
    let doc: Document | undefined;
    try {
      doc = frame?.contentWindow?.document;
    } catch {
      return; /* cross-origin (frame navigated) — nothing to collapse */
    }
    const body = doc?.body;
    if (!doc || !body) return;
    const quote = findTrailingQuote(body);
    if (!quote) return;
    // Never hide everything: require *visible* non-quoted content before it.
    // innerText (unlike textContent) skips display:none preheaders etc.
    const quoteText = quote.innerText.trim();
    const bodyText = body.innerText.trim();
    if (!quoteText || bodyText.length <= quoteText.length) return;

    // No allow-scripts on the sandbox, so JS never runs inside this
    // document — not even listeners a parent script attaches to its
    // nodes. Toggle with a pure-CSS checkbox/label pair instead (native
    // browser behavior, not "scripting").
    const toggleId = "__pigeon_quote_toggle__";
    quote.classList.add("__pigeon_quote_target__");
    const style = doc.createElement("style");
    style.textContent = `
      #${toggleId} { display: none; }
      .__pigeon_quote_target__ { display: none; }
      #${toggleId}:checked ~ .__pigeon_quote_target__ { display: block; }
      .__pigeon_quote_label__ {
        display: inline-block; margin: 10px 0 2px; padding: 0 10px;
        border: 1px solid #d0d0d0; border-radius: 999px; background: #ececec;
        color: #777; font-family: monospace; font-size: 12px; line-height: 18px;
        cursor: pointer; letter-spacing: 1px;
      }
      #${toggleId}:checked ~ .__pigeon_quote_label__ { background: #ddd; }
    `;
    doc.head.appendChild(style);

    const checkbox = doc.createElement("input");
    checkbox.type = "checkbox";
    checkbox.id = toggleId;
    const label = doc.createElement("label");
    label.setAttribute("for", toggleId);
    label.className = "__pigeon_quote_label__";
    label.textContent = "\u00b7\u00b7\u00b7";
    quote.parentNode?.insertBefore(checkbox, quote);
    quote.parentNode?.insertBefore(label, quote);
  }

  // No script runs inside the sandboxed iframe to call resize() when the
  // CSS-only quote toggle above changes the document's height, so watch it
  // from the parent instead — ResizeObserver runs here, not in the frame.
  let resizeObserver: ResizeObserver | undefined;

  function onload() {
    let doc: Document | undefined;
    try {
      doc = frame?.contentWindow?.document;
    } catch {
      /* cross-origin — leave as is */
    }
    // Kill the UA's default 8px body margin so mail renders edge-to-edge;
    // the email's own spacing is untouched. Same for font: this only sets
    // the inherited default — any element (inline style or CSS) that
    // already declares its own font-family keeps it, since a direct
    // declaration always wins over an inherited one regardless of
    // specificity. Matches --font-body's fallback stack, minus the remote
    // Manrope webfont (not loaded inside this document).
    if (doc?.body) {
      doc.body.style.margin = "0";
      doc.body.style.fontFamily = "ui-sans-serif, system-ui, sans-serif";
    }
    collapseQuote();
    resize();

    resizeObserver?.disconnect();
    if (doc?.documentElement) {
      resizeObserver = new ResizeObserver(() => resize());
      resizeObserver.observe(doc.documentElement);
    }
  }
</script>

<iframe
  bind:this={frame}
  srcdoc={html}
  {onload}
  sandbox="allow-same-origin allow-popups allow-popups-to-escape-sandbox"
  title="email content"
></iframe>

<style>
  iframe {
    width: 100%;
    border: none;
    display: block;
  }
</style>
