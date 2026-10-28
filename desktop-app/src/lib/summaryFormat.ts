// Parser for the tiny markdown subset the AI summary prompts in
// `src-tauri/src/ai.rs` ask for: "- " bullets and **bold**. Nothing else is
// interpreted, and the output is structured data (not HTML), so the model's
// text is never injected as markup — SummaryText.svelte renders it with
// ordinary text interpolation.

export interface SummarySegment {
  text: string;
  bold: boolean;
}

export interface SummaryLine {
  /** True when the line started with a bullet marker ("- ", "* ", "• "). */
  bullet: boolean;
  segments: SummarySegment[];
}

const BULLET_RE = /^\s*(?:[-*•]|\d+[.)])\s+/;

/** Split one line on **bold** markers. An unmatched "**" is kept as text. */
export function parseInline(text: string): SummarySegment[] {
  const out: SummarySegment[] = [];
  let rest = text;
  while (rest.length) {
    const open = rest.indexOf("**");
    if (open < 0) break;
    const close = rest.indexOf("**", open + 2);
    if (close < 0) break;
    if (open > 0) out.push({ text: rest.slice(0, open), bold: false });
    const inner = rest.slice(open + 2, close);
    if (inner) out.push({ text: inner, bold: true });
    rest = rest.slice(close + 2);
  }
  if (rest) out.push({ text: rest, bold: false });
  return out;
}

/** Parse a whole summary into lines; blank lines are dropped. */
export function parseSummary(text: string): SummaryLine[] {
  return text
    .split(/\r?\n/)
    .map((raw) => raw.trim())
    .filter((line) => line.length > 0)
    .map((line) => {
      const bullet = BULLET_RE.test(line);
      const body = bullet ? line.replace(BULLET_RE, "") : line;
      return { bullet, segments: parseInline(body) };
    });
}
