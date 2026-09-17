<script lang="ts">
  import HtmlEmailFrame from "./HtmlEmailFrame.svelte";

  // The one message-body renderer — used by both the quick-view preview and
  // the full thread view so the two always show identical content.
  let { html, body }: { html: boolean; body: string } = $props();

  // Split a plaintext body into main content and a trailing quoted block:
  // a trailing run of '> ' lines (blank lines allowed inside), optionally
  // preceded by an 'On <...> wrote:' intro line. Returns null when there is
  // no trailing quote or no non-quoted content before it — never hide
  // non-quoted content.
  function splitQuoted(text: string): { main: string; quoted: string } | null {
    const lines = text.split("\n");
    let i = lines.length;
    let hasQuote = false;
    while (i > 0) {
      const l = lines[i - 1];
      if (/^\s*>/.test(l)) {
        hasQuote = true;
        i--;
      } else if (l.trim() === "") {
        i--;
      } else {
        break;
      }
    }
    if (!hasQuote || i === lines.length) return null;
    if (i > 0 && /^On\s.+wrote:\s*$/.test(lines[i - 1])) i--;
    const main = lines.slice(0, i).join("\n").replace(/\s+$/, "");
    if (!main.trim()) return null;
    return { main, quoted: lines.slice(i).join("\n").trim() };
  }

  const split = $derived(html ? null : splitQuoted(body));
  let quoteOpen = $state(false);
</script>

{#if html}
  <HtmlEmailFrame html={body} />
{:else if split}
  <div class="body">{split.main}</div>
  <button
    class="quote-pill"
    type="button"
    class:open={quoteOpen}
    aria-label={quoteOpen ? "Hide quoted text" : "Show quoted text"}
    onclick={() => (quoteOpen = !quoteOpen)}>···</button
  >
  {#if quoteOpen}
    <div class="body quoted">{split.quoted}</div>
  {/if}
{:else}
  <div class="body">{body}</div>
{/if}

<style>
  .body {
    font-family: var(--font-body);
    font-size: 15px;
    line-height: 1.6;
    color: var(--text-secondary);
    white-space: pre-wrap;
  }
  .body.quoted {
    color: var(--text-tertiary);
    margin-top: 8px;
  }
  .quote-pill {
    display: inline-block;
    margin-top: 10px;
    padding: 0 10px;
    border: 1px solid var(--border-subtle);
    border-radius: 999px;
    background: var(--surface-sunken, #ececec);
    color: var(--text-tertiary);
    font-family: var(--font-mono);
    font-size: 12px;
    line-height: 18px;
    letter-spacing: 1px;
    cursor: pointer;
  }
  .quote-pill.open {
    background: var(--border-subtle);
  }
</style>
