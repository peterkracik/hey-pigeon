// Makes URLs that a mail only wrote as text clickable — in plaintext bodies
// and in HTML text nodes that aren't already inside an <a>. Clicks then take
// the same path as any other mail link: the external-links plugin (lib.rs)
// cancels the navigation and hands the URL to the OS browser.

const URL_RE = /\b(?:https?:\/\/|www\.)[^\s<>"'`]+/gi;

export type Segment = { text: string; href?: string };

// Sentence punctuation right after a URL ("see https://x.com.") belongs to
// the sentence; a trailing ")" only belongs to the URL when it closes one
// that the URL itself opened (Wikipedia-style links).
function trimUrl(raw: string): string {
  let url = raw;
  for (;;) {
    const last = url.at(-1);
    if (last && ".,;:!?*_~]}".includes(last)) url = url.slice(0, -1);
    else if (last === ")" && url.split("(").length <= url.split(")").length - 1) url = url.slice(0, -1);
    else return url;
  }
}

export function splitLinks(text: string): Segment[] {
  const out: Segment[] = [];
  let pos = 0;
  for (const m of text.matchAll(URL_RE)) {
    const url = trimUrl(m[0]);
    if (url.length < 5 || url.toLowerCase() === "www.") continue;
    const start = m.index!;
    if (start > pos) out.push({ text: text.slice(pos, start) });
    out.push({ text: url, href: /^www\./i.test(url) ? `https://${url}` : url });
    pos = start + url.length;
  }
  if (pos < text.length) out.push({ text: text.slice(pos) });
  return out;
}

// Runs from the parent realm on the iframe's document, so it checks
// nodeType/tagName rather than instanceof (see HtmlEmailFrame.svelte).
export function linkifyDocument(doc: Document) {
  if (!doc.body) return;
  const walker = doc.createTreeWalker(doc.body, 4 /* NodeFilter.SHOW_TEXT */);
  const nodes: Text[] = [];
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    if (!n.nodeValue || !/https?:\/\/|www\./i.test(n.nodeValue)) continue;
    const skip = (n.parentElement as Element | null)?.closest("a,script,style,textarea,title");
    if (!skip) nodes.push(n as Text);
  }
  for (const node of nodes) {
    const segments = splitLinks(node.nodeValue!);
    if (!segments.some((s) => s.href)) continue;
    const frag = doc.createDocumentFragment();
    for (const s of segments) {
      if (!s.href) {
        frag.appendChild(doc.createTextNode(s.text));
        continue;
      }
      const a = doc.createElement("a");
      a.href = s.href;
      a.textContent = s.text;
      frag.appendChild(a);
    }
    node.parentNode?.replaceChild(frag, node);
  }
}
