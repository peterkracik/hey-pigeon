<script lang="ts">
  // Renders (mock) HTML mail. sandbox without allow-scripts blocks JS but
  // allow-same-origin keeps the height measurable from the parent.
  // ponytail: no sanitization yet — mock data only; ammonia in the Rust core
  // must sanitize before real mail ever reaches this frame (DESIGN.md Security).
  let { html }: { html: string } = $props();

  let frame: HTMLIFrameElement | undefined = $state();

  function resize() {
    if (frame?.contentWindow) {
      try {
        frame.style.height = frame.contentWindow.document.documentElement.scrollHeight + "px";
      } catch {
        /* cross-origin — leave default height */
      }
    }
  }

  // True when nothing with visible text follows `el` before the end of `body`.
  function isTrailing(el: Element, body: Element): boolean {
    let node: Element | null = el;
    while (node && node !== body) {
      let sib = node.nextSibling;
      while (sib) {
        if (sib.textContent?.trim()) return false;
        sib = sib.nextSibling;
      }
      node = node.parentElement;
    }
    return node === body;
  }

  // Outermost trailing quote container: div.gmail_quote or a trailing <blockquote>.
  function findTrailingQuote(body: HTMLElement): HTMLElement | null {
    const candidates: HTMLElement[] = [];
    const gq = body.querySelector("div.gmail_quote");
    if (gq instanceof HTMLElement) candidates.push(gq);
    const bqs = body.querySelectorAll("blockquote");
    const lastBq = bqs[bqs.length - 1];
    if (lastBq instanceof HTMLElement) candidates.push(lastBq);
    for (const el of candidates) {
      if (isTrailing(el, body)) return el;
    }
    return null;
  }

  // Scripts inside srcdoc are blocked by the sandbox, so quote-collapsing is
  // done from the parent reaching into the same-origin iframe document.
  function collapseQuote() {
    const doc = frame?.contentWindow?.document;
    const body = doc?.body;
    if (!doc || !body) return;
    const quote = findTrailingQuote(body);
    if (!quote) return;
    // Never hide everything: require visible non-quoted content before it.
    const quoteText = quote.textContent?.trim() ?? "";
    const bodyText = body.textContent?.trim() ?? "";
    if (!quoteText || bodyText.length <= quoteText.length) return;

    quote.style.display = "none";
    const pill = doc.createElement("button");
    pill.type = "button";
    pill.textContent = "\u00b7\u00b7\u00b7";
    pill.setAttribute("aria-label", "Show quoted text");
    pill.style.cssText =
      "display:inline-block;margin:10px 0 2px;padding:0 10px;" +
      "border:1px solid #d0d0d0;border-radius:999px;background:#ececec;" +
      "color:#777;font-family:monospace;font-size:12px;line-height:18px;" +
      "cursor:pointer;letter-spacing:1px;";
    pill.addEventListener("click", () => {
      const hidden = quote.style.display === "none";
      quote.style.display = hidden ? "" : "none";
      pill.style.background = hidden ? "#ddd" : "#ececec";
      resize();
    });
    quote.parentNode?.insertBefore(pill, quote);
  }

  function onload() {
    collapseQuote();
    resize();
  }
</script>

<iframe
  bind:this={frame}
  srcdoc={html}
  {onload}
  sandbox="allow-same-origin"
  title="email content"
></iframe>

<style>
  iframe {
    width: 100%;
    border: none;
    display: block;
  }
</style>
